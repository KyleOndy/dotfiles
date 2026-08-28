# Personal home-manager configuration for trex.
# The desktop profile is imported via mkDarwinSystem; this file provides
# macOS-specific overrides, mirroring nix/hosts/work-mac/home.nix.
{
  lib,
  pkgs,
  config,
  osConfig,
  ...
}:
let
  # SMB shares tiger exports (services.samba in nix/hosts/tiger/configuration.nix).
  # Addressed by DNS name, not tiger.local: trex is on 10.24.89.0/24 and tiger
  # on 10.25.89.0/24, and mDNS is link-local, so .local never resolves here.
  smbServer = "tiger.dmz.1ella.com";
  smbAccount = "kyle";
  smbShares = [
    "tiger-data"
    "tiger-photos"
  ];

  # Not /Volumes. Unmounting deletes a mountpoint there, and /Volumes is
  # root-owned, so an agent running as kyle cannot recreate one and would skip
  # the share for good after the first unmount. Under $HOME the directory
  # survives the unmount and the agent needs no privilege at all.
  smbMountRoot = "${config.home.homeDirectory}/mounts";

  # Mounts what is missing when tiger answers, and force-unmounts what is left
  # behind when it does not. The agent runs here rather than in
  # configuration.nix because nix-darwin's launchd.agents get bootstrapped into
  # the system domain and run as root, which mounts the volumes for the wrong
  # user.
  #
  # NetFS (`osascript -e 'mount volume ...'`, what Finder's Cmd+K uses) would be
  # the tidier route, since it picks the mount point and the keychain holds the
  # credential. It does not work unattended. An item written by `security
  # add-internet-password` is not in the keychain's `apple:` partition, so
  # NetAuthAgent refuses to read it without asking, and the mount turns into a
  # login-time password dialog:
  #
  #   $ osascript -e 'mount volume "smb://kyle@tiger.dmz.1ella.com/tiger-data"'
  #   0:56: execution error: User canceled. (-128)
  #
  # Repairing the partition list means handing `security
  # set-internet-password-partition-list -k` the macOS login password, which is
  # a worse thing to automate than what it fixes. mount_smbfs skips the keychain
  # entirely.
  #
  # Cost of that: the password crosses argv, visible in `ps` for the length of
  # one mount. Only kyle and root can act on it, and both can read the secret
  # file directly anyway.
  smbMount = pkgs.writeShellApplication {
    name = "smb-tiger-mount";
    text = ''
      readonly SERVER=${lib.escapeShellArg smbServer}
      readonly ACCOUNT=${lib.escapeShellArg smbAccount}
      readonly SECRET=${osConfig.sops.secrets.smb_kyle_password.path}
      readonly ROOT=${lib.escapeShellArg smbMountRoot}
      readonly TIMEOUT=${pkgs.coreutils}/bin/timeout

      # Reads the kernel's mount table; statting the mountpoint instead would
      # block once the server is gone.
      mounted() {
        /sbin/mount | grep -q " on $1 "
      }

      # nc -z alone would hang in getaddrinfo, not connect(2): away from home
      # this name resolves only through the UDM (wireguard.nix).
      if ! "$TIMEOUT" 5 /usr/bin/nc -z "$SERVER" 445 >/dev/null 2>&1; then
        for share in ${lib.concatMapStringsSep " " lib.escapeShellArg smbShares}; do
          mountpoint="$ROOT/$share"

          if ! mounted "$mountpoint"; then
            continue
          fi

          # launchd will not start a second copy of a job while the first is
          # alive, so an unbounded umount -f on a wedged vnode would retire
          # this agent for good.
          if "$TIMEOUT" 30 /sbin/umount -f "$mountpoint"; then
            echo "smb-tiger: $SERVER unreachable, unmounted $share"
          else
            echo "smb-tiger: $SERVER unreachable, could not unmount $share"
          fi
        done
        exit 0
      fi

      pw="$(cat "$SECRET")"

      # The password goes into a URL, so anything needing percent-encoding
      # would corrupt the mount into a confusing auth failure. Say so instead.
      if ! printf '%s' "$pw" | grep -qE '^[A-Za-z0-9]+$'; then
        echo "smb-tiger: password needs percent-encoding for the mount URL, not attempting"
        exit 1
      fi

      for share in ${lib.concatMapStringsSep " " lib.escapeShellArg smbShares}; do
        mountpoint="$ROOT/$share"

        if mounted "$mountpoint"; then
          continue
        fi

        mkdir -p "$mountpoint"

        # soft fails file system calls after seconds instead of blocking.
        # nobrowse keeps the volume out of Finder, which is what raises the
        # "Server connections interrupted" panel when the server goes away.
        if /sbin/mount_smbfs -o soft,nobrowse,automounted "//$ACCOUNT:$pw@$SERVER/$share" "$mountpoint" 2>/dev/null; then
          echo "smb-tiger: mounted $share"
        else
          echo "smb-tiger: could not mount $share"
        fi
      done
    '';
  };

  # Processes that, if running, should cause the local model server
  # (launchd.agents.mlx-openai-server below) to be stopped -- e.g. DaVinci
  # Resolve, which competes for the same GPU/unified memory. Checked on every
  # poll; the server is not auto-restarted when the watched process quits --
  # the next search-mail or `mlx start` invocation starts it on
  # demand. Add another entry to watch more apps. Names must match `pgrep -x`
  # exactly (the process's own binary name, not necessarily its .app bundle
  # name) -- verify with `pgrep -x <name>` while the app is running before
  # adding it here.
  mlxAutoStopWatchedProcesses = [ "Resolve" ]; # DaVinci Resolve
  mlxAutoStopPollIntervalSec = 30;

  # Static multi-model config for mlx-openai-server -- see the file itself
  # for the model list and rationale. No nix interpolation needed inside it
  # (model paths are HF repo ids, not local paths), so it's just read as-is.
  mlxModelsConfig = pkgs.writeText "mlx-openai-server-models.yaml" (
    builtins.readFile ./mlx-models.yaml
  );

  mlxAutoStopWatcher = pkgs.writeShellApplication {
    name = "mlx-auto-stop-watcher";
    text = ''
      readonly LABEL="org.ondy.mlx-openai-server"

      state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"
      if [ "$state" != "running" ]; then
        exit 0
      fi

      # shellcheck disable=SC2043  # mlxAutoStopWatchedProcesses has one entry today; the loop is written to support more
      for name in ${lib.concatMapStringsSep " " lib.escapeShellArg mlxAutoStopWatchedProcesses}; do
        if pgrep -x "$name" >/dev/null 2>&1; then
          echo "mlx-auto-stop: $name is running, stopping $LABEL"
          launchctl kill SIGTERM "gui/$(id -u)/$LABEL"
          exit 0
        fi
      done
    '';
  };
in
{
  imports = [ ];

  # Kensington trackball remapping, the darwin-side mechanism.
  #
  # The module remaps trackball buttons only. OS-wide keys stay mac-native
  # apart from caps lock below, which also keeps physical Ctrl free for
  # winnow's Ctrl+h/j/k/l/0/r bindings (see AA_MacDontSwapCtrlAndMeta in
  # winnow's app.py) without needing a per-app Karabiner exclusion.
  hmFoundry.desktop.input.karabiner.enable = true;

  # Caps lock is push to talk for a domestique ride: held, it creates
  # ~/.pi/domestique/listening and domestique-listen opens the microphone.
  # The rule carries no application condition, so caps lock stops toggling
  # case everywhere and not only during a ride. That is the trade the module
  # documents, and the key has to be one pi's TUI never reads.
  #
  # It stays bound alongside the pad because the pad is a thing that can be
  # left in a bag, and a ride without one still needs a way to talk.
  hmFoundry.desktop.input.karabiner.pushToTalk.enable = true;
  hmFoundry.desktop.input.karabiner.pushToTalk.pad.enable = true;

  # Add Homebrew to PATH for all managed shells (including Claude Code).
  # Also add uv's tool install dir (~/.local/bin, e.g. mlx-lm's mlx_lm.*
  # executables) since `uv tool update-shell` can't write the home-manager
  # managed .zshenv symlink.
  home.sessionPath = [
    "/opt/homebrew/bin"
    "$HOME/.local/bin"
  ];

  hmFoundry.dev = {
    claude-code.enable = true;
    kubernetes.enable = true; # kubectl, kubectx, k9s, helm, kustomize, kind
    nixTools.enable = true; # nixfmt, nixpkgs-review, nix-index
    sysadmin.enable = true; # htop, lsof, nmap, mosh, dnsutils

    # Ride mode for pi, enabled by default on every darwin host. Only the
    # working directory is host-specific: the default ~/work/rides is a
    # work-mac shape, and trex has no ~/work.
    domestique.rideDir = "${config.home.homeDirectory}/pi-ride";

    # Colima background service. Defaults (4 CPU / 8GB / 100GB) are
    # conservative starting points - tune once trex's actual RAM is known.
    docker.service.enable = true;

    # pi's mcloud key is not managed here. `/login` writes it to
    # ~/.pi/agent/auth.json, which no nix module owns, and the sandbox can
    # read it because the wrapper re-allows ~/.pi. Injecting it via
    # sandbox.envFromCommands from sops (trex_mcloud_api_key, which
    # mcloud-pins already reads) keeps it out of the sandbox instead, see the
    # deny-read block in nix/pkgs/pi-wrapper/wrapper.sh.
    #
    # work-mac gets the same provider from the private work-config input,
    # with real costs, context windows and reasoning maps. trex builds
    # against the no-op stub, so the block below is the whole provider here.
    #
    # trex's local mlx models are absent. search-mail
    # (nix/pkgs/search-mail/search-mail.sh) drives them directly, which is the
    # only workload that needs mail to stay off the network.
    pi-coding-agent = {
      # Loopback egress for local dev servers and httptest; see
      # nix/pkgs/pi-wrapper/wrapper.sh.
      sandbox.allowLocalBinding = true;

      # The mcloud endpoint, and nothing else. An empty list would mean no
      # network at all rather than unrestricted (sandbox-runtime 0.0.67
      # README, Network Isolation).
      sandbox.allowedDomains = [ "api.modular.com" ];

      sandbox.defaultArgs = [
        "--model"
        "mcloud/zai-org/glm-5.3"
        "--thinking"
        "xhigh"
      ];

      # Only `reasoning` is set: pi defaults contextWindow to 128k, maxTokens
      # to 16k and every cost to 0, and `--thinking` above is inert without
      # reasoning. kimi is registered because agents/critic.md pins it, and a
      # model id that resolves to nothing fails silently at runtime.
      modelsJson.providers.mcloud = {
        baseUrl = "https://api.modular.com/v1";
        api = "openai-completions";
        models = [
          {
            id = "zai-org/glm-5.3";
            reasoning = true;
          }
          {
            id = "moonshotai/kimi-k2.7-code";
            reasoning = true;
          }
        ];
      };
    };
  };

  # mlx-openai-server, uv-installed like mlx-lm (see ask's sessionPath note
  # above) -- Metal wheels don't package cleanly through nixpkgs on darwin.
  # Install once with: uv tool install mlx-openai-server
  #
  # RunAtLoad/KeepAlive both false: on-demand rather than always-resident, to
  # avoid holding a model's RAM footprint when not in use. Start with:
  #   launchctl kickstart -k gui/$(id -u)/org.ondy.mlx-openai-server
  # (nix/pkgs/search-mail does this automatically before it queries.)
  # Flip both to true for an always-on server -- the per-model on_demand
  # settings in mlx-models.yaml still govern which model is actually
  # resident, so this only affects how quickly the process itself answers.
  #
  # Model list, tool-call parsers, and concurrency/context tuning all live
  # in nix/hosts/trex/mlx-models.yaml (multi-model config -- see that file
  # and its README link for the schema); this launchd job just points
  # mlx-openai-server at it.
  launchd.agents.mlx-openai-server = {
    enable = true;
    config = {
      Label = "org.ondy.mlx-openai-server";
      ProgramArguments = [
        "${config.home.homeDirectory}/.local/bin/mlx-openai-server"
        "launch"
        "--config"
        "${mlxModelsConfig}"
      ];
      RunAtLoad = false;
      KeepAlive = false;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mlx-openai-server.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mlx-openai-server.log";
      ProcessType = "Background";
      EnvironmentVariables = {
        PATH = "${config.home.homeDirectory}/.local/bin:/opt/homebrew/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };

  # configd rewrites resolv.conf on joining a network and on wg-home coming
  # up, so a reconnect lands in seconds rather than waiting out StartInterval.
  # Named by its real path because /etc/resolv.conf is a symlink and launchd
  # watches the node it is handed.
  launchd.agents.smb-tiger-mount = {
    enable = true;
    config = {
      Label = "org.ondy.smb-tiger-mount";
      ProgramArguments = [ (lib.getExe smbMount) ];
      RunAtLoad = true;
      StartInterval = 60;
      WatchPaths = [ "/var/run/resolv.conf" ];
      ProcessType = "Background";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/smb-tiger.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/smb-tiger.log";
    };
  };

  # Polls every mlxAutoStopPollIntervalSec for mlxAutoStopWatchedProcesses
  # (see the `let` block above) and stops mlx-openai-server if one is found
  # running, so it doesn't hold GPU/unified memory against apps that need it
  # (e.g. DaVinci Resolve). `mlx status` and `mlx start` (nix/pkgs/mlx) bring
  # it back manually; search-mail brings it back on demand.
  launchd.agents.mlx-auto-stop = {
    enable = true;
    config = {
      Label = "org.ondy.mlx-auto-stop";
      ProgramArguments = [ (lib.getExe mlxAutoStopWatcher) ];
      StartInterval = mlxAutoStopPollIntervalSec;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mlx-auto-stop.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mlx-auto-stop.log";
      ProcessType = "Background";
    };
  };
}

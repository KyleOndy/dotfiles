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

  # Mounts anything not already mounted, reading the password straight from
  # sops. The agent runs here rather than in configuration.nix because
  # nix-darwin's launchd.agents get bootstrapped into the system domain and run
  # as root, which mounts the volumes for the wrong user.
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

      pw="$(cat "$SECRET")"

      # The password goes into a URL, so anything needing percent-encoding
      # would corrupt the mount into a confusing auth failure. Say so instead.
      if ! printf '%s' "$pw" | grep -qE '^[A-Za-z0-9]+$'; then
        echo "smb-tiger: password needs percent-encoding for the mount URL, not attempting"
        exit 1
      fi

      for share in ${lib.concatMapStringsSep " " lib.escapeShellArg smbShares}; do
        mountpoint="/Volumes/$share"

        if /sbin/mount | grep -q " on $mountpoint "; then
          continue
        fi

        # Created by the activation script in configuration.nix, since /Volumes
        # is root-owned. Missing means that has not run yet.
        if [ ! -d "$mountpoint" ]; then
          echo "smb-tiger: $mountpoint does not exist, skipping"
          continue
        fi

        if /sbin/mount_smbfs "//$ACCOUNT:$pw@$SERVER/$share" "$mountpoint" 2>/dev/null; then
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
  # the next search-mail/pi-overnight/mlx-start invocation starts it on
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

  # Disable Linux-only features on macOS
  hmFoundry.desktop = {
    apps.discord.enable = lib.mkForce false;
    apps.slack.enable = lib.mkForce false;
    browsers.firefox.enable = lib.mkForce true;
    gaming.steam.enable = lib.mkForce false;
    term.foot.enable = lib.mkForce false;
    term.alacritty.enable = true;
    term.wezterm.enable = lib.mkForce false;
    wm.i3.enable = lib.mkForce false;
    media = {
      makemkv.enable = lib.mkForce false;
      documents.enable = lib.mkForce false;
    };
  };

  # Kensington trackball remapping - same physical hardware/need as the
  # NixOS hmFoundry.desktop.input.trackball module, just the darwin-side
  # mechanism.
  #
  # The module remaps trackball buttons only. OS-wide keys stay mac-native,
  # which also keeps physical Ctrl free for winnow's Ctrl+h/j/k/l/0/r bindings
  # (see AA_MacDontSwapCtrlAndMeta in winnow's app.py) without needing a
  # per-app Karabiner exclusion.
  hmFoundry.desktop.input.karabiner.enable = true;

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

    # Colima background service. Defaults (4 CPU / 8GB / 100GB) are
    # conservative starting points - tune once trex's actual RAM is known.
    docker.service.enable = true;

    # Local models for the pi coding agent, mirroring `ask`'s mlx backend
    # (see nix/pkgs/ask/ask.sh) but served OpenAI-compatible so pi can talk
    # to them as a regular provider. mlx-openai-server (not bare
    # mlx_lm.server) because pi lives on tool calls and mlx_lm.server's
    # OpenAI tool-calling is immature; mlx-openai-server ships first-class
    # tool-call parsers.
    #
    # Four models are registered (see nix/hosts/trex/mlx-models.yaml for
    # the server-side config and current empirical notes): qwen3-14b is the
    # long-standing dense baseline, kept over the earlier
    # Qwen3-Coder-30B-A3B because that MoE's 3B active params frequently
    # dropped the leading <tool_call> tag over long agentic loops (see
    # github.com/QwenLM/Qwen3-Coder/issues/475). qwen3.5-9b and qwen3.5-4b
    # are the newer generation, added to A/B against that baseline.
    # qwen3.6-27b (added 2026-07-24) is a further candidate, since qwen3-14b
    # has since failed every notmuch call search-mail has thrown at it. All
    # four load on demand server-side, so registering more than one here
    # doesn't cost resident RAM until actually selected with `pi --model
    # local/<id>`.
    #
    # Model selection is per-invocation -- not pinned via
    # sandbox.defaultArgs, so cloud models stay the default.
    pi-coding-agent = {
      sandbox.allowLocalBinding = true; # only lever to reach 127.0.0.1 egress from the sandbox; see nix/pkgs/pi-wrapper/wrapper.sh

      modelsJson.providers.local = {
        baseUrl = "http://127.0.0.1:8000/v1";
        api = "openai-completions";
        apiKey = "local-no-key"; # mlx-openai-server does not check this
        compat.supportsDeveloperRole = false;
        models = [
          {
            id = "qwen3-14b";
            name = "Qwen3 14B (local, mlx)";
            reasoning = true;
            input = [ "text" ];
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            contextWindow = 24576; # matches context_length in mlx-models.yaml
            maxTokens = 8192;
          }
          {
            id = "qwen3.5-9b";
            name = "Qwen3.5 9B (local, mlx)";
            reasoning = true;
            input = [ "text" ];
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            contextWindow = 24576; # matches context_length in mlx-models.yaml
            maxTokens = 8192;
          }
          {
            id = "qwen3.5-4b";
            name = "Qwen3.5 4B (local, mlx)";
            reasoning = true;
            input = [ "text" ];
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            contextWindow = 24576; # matches context_length in mlx-models.yaml
            maxTokens = 8192;
          }
          {
            id = "qwen3.6-27b";
            name = "Qwen3.6 27B (local, mlx)";
            reasoning = true;
            input = [ "text" ];
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            contextWindow = 24576; # matches context_length in mlx-models.yaml
            maxTokens = 8192;
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
  # (nix/pkgs/pi-overnight does this automatically before an overnight run.)
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

  # Polls every mlxAutoStopPollIntervalSec for mlxAutoStopWatchedProcesses
  # (see the `let` block above) and stops mlx-openai-server if one is found
  # running, so it doesn't hold GPU/unified memory against apps that need it
  # (e.g. DaVinci Resolve). mlx-status/mlx-start (nix/pkgs/mlx-status,
  # nix/pkgs/mlx-start) bring it back manually; search-mail/pi-overnight
  # bring it back on demand.
  # tiger's SMB shares, mounted at login so they sit under Locations in the
  # Finder sidebar (and on the Desktop) without a Cmd+K every session. Reruns
  # every five minutes, which also covers reconnects after a network drop,
  # sleep, or a manual eject.
  launchd.agents.smb-tiger-mount = {
    enable = true;
    config = {
      Label = "org.ondy.smb-tiger-mount";
      ProgramArguments = [ (lib.getExe smbMount) ];
      RunAtLoad = true;
      StartInterval = 300;
      ProcessType = "Background";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/smb-tiger.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/smb-tiger.log";
    };
  };

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

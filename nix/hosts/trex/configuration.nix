# Personal darwin system configuration for trex.
# Shared darwin plumbing lives in nix/modules/darwin_modules/.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [ ./wireguard.nix ];

  networking.hostName = "trex";

  # trex runs Determinate Nix, whose own daemon owns /etc/nix/nix.conf and
  # conflicts with nix-darwin's native Nix management:
  #   error: Determinate detected, aborting activation
  # Adopt Determinate's own nix-darwin module (flake input `determinate`)
  # rather than a bare `nix.enable = false;`, so we also get its
  # Determinate-compatible local Linux builder below -- nix-darwin's own
  # nix.linux-builder doesn't work once nix-darwin stops managing Nix.
  # https://docs.determinate.systems/guides/nix-darwin/
  determinateNix = {
    enable = true; # also forces nix.enable = false for us

    # Local NixOS VM (QEMU with hvf acceleration, so native aarch64 speed)
    # that builds Linux derivations. Determinate's replacement for
    # nix-darwin's own nix.linux-builder, which asserts `requires nix.enable`
    # once Determinate owns Nix (nix-darwin/nix-darwin#1505).
    nixosVmBasedLinuxBuilder = {
      enable = true;

      # Upstream defaults are 1 vCPU, 3 GiB RAM and a 20 GiB disk, which
      # leaves 9 of trex's 10 cores idle during a Linux build. trex has 32
      # GiB; leave macOS the rest.
      #
      # The qcow2 is attached without discard, so it only ever grows toward
      # diskSize and never shrinks. 40 GiB is the cap on real disk this can
      # cost. The GC thresholds are raised off their 1/3 GiB defaults to
      # match: reclaim below 8 GiB free, stop at 20 GiB, which keeps a
      # closure build from wedging and holds the high-water mark down.
      config = {
        virtualisation.cores = 8;
        virtualisation.darwin-builder = {
          memorySize = 12 * 1024;
          diskSize = 40 * 1024;
          min-free = 8 * 1024 * 1024 * 1024;
          max-free = 20 * 1024 * 1024 * 1024;
        };
      };

      # maxJobs defaults to virtualisation.cores, and 8 derivations each
      # taking all 8 cores thrashes 12 GiB. Four at a time, all cores each.
      maxJobs = 4;

      # Outrank tiger for aarch64-linux. Same zstd derivation, both boxes
      # idle: 21s here, 284s on tiger, which has to emulate aarch64 through
      # binfmt qemu. speedFactor only orders machines that can build a given
      # system, so this decides aarch64 and leaves x86_64 alone.
      speedFactor = 10;
    };

    # tiger is the only x86_64-linux builder, and at 23s for that same zstd
    # it is not the slow one: emulation is, costing it 12.3x. It keeps
    # aarch64-linux only as a fallback for when the local VM is down, at a
    # speedFactor the VM always beats. The short ConnectTimeout in
    # root-ssh-config.nix keeps that failover fast instead of hanging.
    buildMachines = [
      {
        hostName = "tiger.dmz.1ella.com";
        sshUser = "svc.deploy";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 8;
        speedFactor = 1;
        supportedFeatures = [
          "benchmark"
          "big-parallel"
        ];
      }
    ];
  };

  # nix-darwin's own nix.linux-builder and nix.optimise.automatic (both
  # turned on for all darwin hosts in nix/modules/darwin_modules/base.nix)
  # are separate from determinateNix.nixosVmBasedLinuxBuilder above and
  # still assert `requires nix.enable` on their own. Store optimisation is
  # Determinate's job now.
  nix.linux-builder.enable = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;

  # Photo import front door, a role dino filled before it was sold. The working
  # set is deliberately sparse: tiger holds 321G of _provisional against 340G
  # free here, which is why backup-photos scopes its --delete per shoot rather
  # than per tree. Import is by SD card reader; the X-T5 over USB-C presents as
  # PTP rather than mass storage so it never mounts as a volume, and
  # com.apple.ptpcamerad claims it before gphoto2 can (helios/README.md).
  home-manager.users.kyle.home.packages = with pkgs; [
    helios
    backup-photos
    photos-recall
    photos-promote
    winnow
    ask # local LLM one-off questions and chat, see nix/pkgs/ask
    pi-overnight # unattended pi runs against the local model, see nix/pkgs/pi-overnight
    search-mail # local-only notmuch search via pi, see nix/pkgs/search-mail
    mlx # start, stop, or check the local model server, see nix/pkgs/mlx
  ];

  # System version (managed by nix-darwin) - snapshot from when trex was
  # created, per-host, never bumped in lockstep with other hosts.
  system.stateVersion = 6;

  # Dock (macOS "taskbar"): pin to the bottom and pin a minimal app set.
  # autohide/tilesize/show-recents etc. come from the shared defaults in
  # nix/modules/darwin_modules/base.nix; only host-specific bits live here.
  system.defaults.dock = {
    orientation = "bottom";
    persistent-apps = lib.mkDefault [
      "/System/Library/CoreServices/Finder.app"
      "/Users/kyle/Applications/Home Manager Apps/Alacritty.app"
      "/Users/kyle/Applications/Home Manager Apps/Firefox.app"
      "/System/Applications/Messages.app"
    ];
  };

  # Disable macOS screenshot shortcuts so Shottr (fired by the trackball's
  # remapped buttons, see hmFoundry.desktop.input.karabiner in home.nix) can
  # intercept them.
  system.defaults.CustomUserPreferences."com.apple.symbolichotkeys".AppleSymbolicHotKeys = {
    "28".enabled = false; # Cmd+Shift+3 (full screen to file)
    "29".enabled = false; # Ctrl+Cmd+Shift+3 (full screen to clipboard)
    "30".enabled = false; # Cmd+Shift+4 (selection to file)
    "31".enabled = false; # Ctrl+Cmd+Shift+4 (selection to clipboard)
    "184".enabled = false; # Cmd+Shift+5 (screenshot options panel)
    "164".enabled = false; # Ctrl+Cmd+Space (Emoji & Symbols / Character Viewer)
  };

  # Finder sidebar favourites, see nix/modules/darwin_modules/finder-sidebar.nix
  # tiger's shares mount -o nobrowse (see home.nix), so they never appear under
  # Locations. Their parent is pinned rather than the mountpoints themselves: a
  # Favorite stores a bookmark carrying volume identity, not a path, and
  # resolving one recorded in the opposite mount state segfaults mysides, which
  # would abort this whole list. ~/mounts is never itself a mountpoint.
  systemFoundry.finderSidebar.folders = [
    "${config.users.users.kyle.home}/screenshots"
    "${config.users.users.kyle.home}/photos"
    "${config.users.users.kyle.home}/mounts"
  ];

  # Homebrew integration for GUI applications and tools not in nixpkgs.
  homebrew = {
    casks = lib.mkDefault [
      "alt-tab" # app switcher; macOS only draws its own on a held Cmd+Tab
      "karabiner-elements" # applies the Kensington trackball remapping, see home.nix
      "shottr" # screenshot tool the trackball buttons trigger
    ];
    taps = [ ];
    brews = [ ];
  };

  # Report metrics/logs to tiger, darwin-native equivalent of the NixOS
  # systemFoundry.monitoringStack (nix/modules/darwin_modules/monitoring-agent.nix).
  systemFoundry.monitoringAgent = {
    enable = true;
    hostLabel = "trex";
    remoteWriteUrl = "https://metrics.tiger.infra.ondy.org/api/v1/write";
    lokiUrl = "https://loki.tiger.infra.ondy.org/loki/api/v1/push";
    basicAuth = {
      username = "monitoring";
      passwordFile = config.sops.secrets.monitoring_password.path;
    };
  };

  sops.secrets = {
    email_kyle_ondy_org = {
      owner = "kyle";
      mode = "0400";
    };
    monitoring_password = {
      # vmagent and promtail run as root here (no DynamicUser on darwin),
      # but keep the same permissive mode used on the other NixOS hosts
      # for consistency.
      mode = "0444";
    };
    # Same secret tiger seeds smbd with; read here by smb-tiger-mount, which
    # runs as kyle.
    smb_kyle_password = {
      owner = "kyle";
      mode = "0400";
    };
    # pi's only model provider here. Read by the pi wrapper's envFromCommands
    # resolver, which runs as kyle outside the sandbox (see home.nix).
    trex_openrouter_api_key = {
      owner = "kyle";
      mode = "0400";
    };
  };

  # Password script for automated mbsync service. Only kyle@ondy.org is
  # wired up for automated sync (the other two accounts in
  # nix/modules/hm_modules/terminal/email.nix have mbsync.enable = false).
  sops.templates."mbsync-password-script" = {
    owner = "kyle";
    mode = "0500";
    content = ''
      #!/usr/bin/env bash
      set -euo pipefail
      case "$1" in
        "kyle@ondy.org")
          cat ${config.sops.secrets.email_kyle_ondy_org.path}
          ;;
        *)
          echo "Unknown email account: $1" >&2
          exit 1
          ;;
      esac
    '';
  };

  # Automated mbsync config for the launchd agent (uses sops-encrypted
  # password instead of pass/GPG).
  sops.templates."mbsyncrc-automated" = {
    owner = "kyle";
    mode = "0600";
    content = ''
      # Generated mbsync config for automated launchd agent
      # Uses sops-encrypted passwords instead of pass/GPG

      IMAPAccount kyle_at_ondy_org
      CertificateFile /etc/ssl/certs/ca-certificates.crt
      Host london.mxroute.com
      PassCmd "bash ${config.sops.templates."mbsync-password-script".path} kyle@ondy.org"
      TLSType IMAPS
      User kyle@ondy.org

      IMAPStore kyle_at_ondy_org-remote
      Account kyle_at_ondy_org

      MaildirStore kyle_at_ondy_org-local
      Inbox ${config.users.users.kyle.home}/mail/ondy.org/Inbox
      Path ${config.users.users.kyle.home}/mail/ondy.org/
      SubFolders Verbatim

      Channel kyle_at_ondy_org
      Create Near
      Expunge None
      Far :kyle_at_ondy_org-remote:
      Near :kyle_at_ondy_org-local:
      Patterns INBOX Archive "Deleted Messages" Drafts Junk Sent
      Remove None
      SyncState *
    '';
  };

  # Route the interactive mbsync PassCmd (manual `mbsync --all`, notmuch
  # preNew hook) through the same sops-backed password script used by the
  # launchd agent below, instead of the unconfigured `pass`.
  home-manager.users.kyle.hmFoundry.terminal.email.passwordCommand =
    addr: "${config.sops.templates."mbsync-password-script".path} ${addr}";

  # launchd equivalent of the NixOS systemd.user.timers.mbsync + notmuch-new
  # (there's no systemd on darwin for home-manager's systemd.user.* to run).
  home-manager.users.kyle.launchd.agents.mbsync = {
    enable = true;
    config = {
      Label = "org.ondy.mbsync";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "${pkgs.isync}/bin/mbsync -c ${
          config.sops.templates."mbsyncrc-automated".path
        } --all && ${pkgs.notmuch}/bin/notmuch new --no-hooks && ${pkgs.notmuch}/bin/notmuch tag +inbox +unread -new -- tag:new"
      ];
      StartInterval = 900; # 15 minutes, matching the equivalent systemd OnCalendar = "*:0/15"
      RunAtLoad = true;
      StandardOutPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
      StandardErrorPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
    };
  };
}

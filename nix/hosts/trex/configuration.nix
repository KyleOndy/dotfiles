# Personal darwin system configuration for trex.
# Shared darwin plumbing lives in nix/modules/darwin_modules/.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Baked into the tools that call mcloud, rather than set as a session
  # variable, which a shell older than the deploy (or any pane of an older
  # tmux server) never sees.
  mcloudKeyCommand = "/bin/cat ${config.sops.secrets.mcloud_api_key.path}";
in
{
  imports = [ ./wireguard.nix ];

  networking.hostName = "trex";

  # lan.1ella.com and dmz.1ella.com live only in the UDM's split-horizon
  # view; the public 1ella.com zone carries no such records. iCloud Private
  # Relay hands mDNSResponder's queries to mask.icloud.com over DoH, and
  # that resolver answers NXDOMAIN out of the public zone, so getaddrinfo
  # cannot reach tiger or pika by name while dig, going straight to the UDM
  # over UDP, still resolves them. resolver(5) reads the file name as the
  # domain it scopes, so this file pins the zone to the server that holds
  # its records. Off the LAN without wg-home these names time out rather
  # than failing fast.
  environment.etc."resolver/1ella.com".text = ''
    nameserver 10.24.89.1
  '';

  # trex runs Determinate Nix, whose own daemon owns /etc/nix/nix.conf and
  # conflicts with nix-darwin's native Nix management:
  #   error: Determinate detected, aborting activation
  # Adopt Determinate's own nix-darwin module (flake input `determinate`)
  # rather than a bare `nix.enable = false;`.
  # https://docs.determinate.systems/guides/nix-darwin/
  determinateNix = {
    enable = true; # also forces nix.enable = false for us

    # base.nix's nix.settings are never written here, so the numtide cache
    # it adds for the llm-agents packages has to be restated. The daemon
    # reads these only at start: `make deploy-trex` restarts it when they
    # change, and a bare `darwin-rebuild switch` leaves the old ones running.
    #
    # A plain `substituters` replaces Nix's built-in cache.nixos.org, so
    # both lists carry it too.
    customSettings = {
      substituters = [
        "https://cache.numtide.com"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
      builders-use-substitutes = true;
      # Determinate's module defaults this to false, which leaves a build
      # unconfined as _nixbld with the whole network. Fixed-output builds keep
      # the network either way; docs/darwin-nix-sandbox.md has what this
      # closes.
      sandbox = true;
    };

    distributedBuilds = true;

    buildMachines = [
      # nix-rosetta-builder's own entry is in nix.buildMachines, which
      # nix-darwin writes only while it manages Nix. Its ssh_config.d entry
      # supplies the user, key and host key. aarch64-linux only: the VM
      # could take x86_64-linux under Rosetta, but tiger builds that
      # natively, without booting the VM.
      {
        hostName = "rosetta-builder";
        protocol = "ssh-ng";
        systems = [ "aarch64-linux" ];
        # 8 derivations each taking all 8 cores thrashes 12 GiB.
        maxJobs = 4;
        # Outrank tiger, which emulates aarch64 at 12.3x the cost.
        speedFactor = 10;
        supportedFeatures = [
          "benchmark"
          "big-parallel"
          "kvm"
          "nixos-test"
        ];
      }
      # tiger is the only x86_64-linux builder, and at 23s for that same
      # zstd it is not the slow one: emulation is, costing it 12.3x. It
      # keeps aarch64-linux only as a fallback for when the local VM is
      # down, at a speedFactor the VM always beats. The short ConnectTimeout
      # in root-ssh-config.nix keeps that failover fast instead of hanging.
      {
        hostName = "tiger.dmz.1ella.com";
        sshUser = "svc.nixbuild";
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

  # Of trex's 32 GiB, held only while the builder VM is up.
  nix-rosetta-builder.memory = "12GiB";

  # nix-darwin's nix.gc and nix.optimise (both turned on for every darwin
  # host in nix/modules/darwin_modules/base.nix) assert `requires
  # nix.enable`.
  nix.gc.automatic = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;

  # determinate-nixd collects unreferenced paths by its own capacity rubric,
  # but it never deletes a generation, so every old system generation stays
  # a GC root, and it never optimises the store. These are nix-darwin's
  # nix-gc and nix-optimise daemons, run with Determinate's own nix.
  launchd.daemons = {
    nix-gc = {
      command = "/nix/var/nix/profiles/default/bin/nix-collect-garbage --delete-older-than 35d";
      serviceConfig = {
        RunAtLoad = false;
        StartCalendarInterval = [
          {
            Weekday = 7;
            Hour = 3;
            Minute = 15;
          }
        ];
      };
    };
    nix-optimise = {
      command = "/nix/var/nix/profiles/default/bin/nix-store --optimise";
      serviceConfig = {
        RunAtLoad = false;
        StartCalendarInterval = [
          {
            Weekday = 7;
            Hour = 4;
            Minute = 15;
          }
        ];
      };
    };
  };

  # Photo import front door, a role dino filled before it was sold. The working
  # set is deliberately sparse: tiger holds 321G of _provisional against 340G
  # free here, which is why backup-photos scopes its --delete per shoot rather
  # than per tree. Import is by SD card reader; the X-T5 over USB-C presents as
  # PTP rather than mass storage so it never mounts as a volume, and
  # com.apple.ptpcamerad claims it before gphoto2 can (helios/README.md).
  home-manager.users.kyle.home.packages = with pkgs; [
    helios
    backup-photos
    # Mirrors ~/resolve and the Resolve project library to tiger's
    # storage/projects, the one backed-up dataset that never goes offsite.
    # See nix/pkgs/backup-resolve-projects.
    backup-resolve-projects
    photos-recall
    photos-promote
    winnow
    ask # local LLM one-off questions and chat, see nix/pkgs/ask
    search-mail # local-only notmuch search via alamode, see nix/pkgs/search-mail
    mail-stragglers # who still mails ondy.me or the old gmail, see nix/pkgs/mail-stragglers
    mlx # start, stop, or check the local model server, see nix/pkgs/mlx
    (leak-guard.override { keyCommand = mcloudKeyCommand; }) # refuses commits and pushes naming a private model id
    (mcloud-pins.override { keyCommand = mcloudKeyCommand; }) # checks every pinned mcloud id answers, see nix/pkgs/mcloud-pins
    mpv
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
      "/Applications/Firefox.app"
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
      "firefox" # Mozilla's signed build, see hmFoundry.desktop.browsers.firefox
      "google-chrome" # for Claude in Chrome; updates itself, nixpkgs' read-only copy can't
      "karabiner-elements" # applies the Kensington trackball remapping, see home.nix
      "shottr" # screenshot tool the trackball buttons trigger
    ];
    taps = [ ];
    brews = [ ];
  };

  # Report metrics to tiger, darwin-native equivalent of the NixOS
  # systemFoundry.monitoringStack (nix/modules/darwin_modules/monitoring-agent.nix).
  systemFoundry.monitoringAgent = {
    enable = true;
    hostLabel = "trex";
    remoteWriteUrl = "https://metrics.tiger.infra.ondy.org/api/v1/write";
    basicAuth = {
      username = "monitoring";
      passwordFile = config.sops.secrets.monitoring_password.path;
    };
  };

  sops.secrets = {
    # The three email_* secrets are also read by tiger's mail-backup.
    email_kyle_ondy_org = {
      owner = "kyle";
      mode = "0400";
      sopsFile = ../../secrets/shared-tiger-trex.yaml;
    };
    email_kyle_ondy_me = {
      owner = "kyle";
      mode = "0400";
      sopsFile = ../../secrets/shared-tiger-trex.yaml;
    };
    email_kyleondy_gmail_com = {
      owner = "kyle";
      mode = "0400";
      sopsFile = ../../secrets/shared-tiger-trex.yaml;
    };
    monitoring_password = {
      # The only reader is vmagent, a root launchd daemon here.
      mode = "0400";
      sopsFile = ../../secrets/shared-cogsworth-pika-trex.yaml;
    };
    # Same secret tiger seeds smbd with; read here by smb-tiger-mount, which
    # runs as kyle.
    smb_kyle_password = {
      owner = "kyle";
      mode = "0400";
      sopsFile = ../../secrets/shared-tiger-trex.yaml;
    };
    trex_backup_git_ssh_key = {
      owner = "kyle";
      mode = "0400";
    };
    # The catalog and seats (alamode's modelsJsonFile and seatsFile),
    # secrets rather than store paths because the model ids in them are
    # private. mcloud_api_key is the console.modular.com token alamode,
    # mcloud-pins and leak-guard read through mcloudKeyCommand.
    alamode_models_json = {
      owner = "kyle";
      mode = "0400";
    };
    alamode_seats = {
      owner = "kyle";
      mode = "0400";
    };
    # Shared with tiger's alamode-advisor.
    mcloud_api_key = {
      owner = "kyle";
      mode = "0400";
      sopsFile = ../../secrets/shared-tiger-trex.yaml;
    };
    # z.ai Coding Plan key, resolved as ZAI_API_KEY for alamode_models_json's
    # zai provider. Goes with that provider when the plan lapses.
    zai_api_key = {
      owner = "kyle";
      mode = "0400";
    };
  };

  # Password script for mbsync, one case per account in
  # nix/modules/hm_modules/terminal/email.nix.
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
        "kyle@ondy.me")
          cat ${config.sops.secrets.email_kyle_ondy_me.path}
          ;;
        "kyleondy@gmail.com")
          cat ${config.sops.secrets.email_kyleondy_gmail_com.path}
          ;;
        *)
          echo "Unknown email account: $1" >&2
          exit 1
          ;;
      esac
    '';
  };

  # Route mbsync's PassCmd (the launchd agent below, manual `mbsync --all`,
  # the notmuch preNew hook) through the sops-backed password script instead
  # of the unconfigured `pass`.
  home-manager.users.kyle.hmFoundry.terminal.email.passwordCommand =
    addr: "${config.sops.templates."mbsync-password-script".path} ${addr}";

  # launchd equivalent of the NixOS systemd.user.timers.mbsync + notmuch-new
  # (there's no systemd on darwin for home-manager's systemd.user.* to run).
  home-manager.users.kyle.launchd.agents.mbsync = {
    enable = true;
    config = {
      Label = "org.ondy.mbsync";
      ProgramArguments = [
        (lib.getExe (
          pkgs.writeShellApplication {
            name = "mbsync-sync";
            runtimeInputs = [
              pkgs.isync
              pkgs.notmuch
            ];
            text = ''
              readonly PROM=${config.systemFoundry.monitoringAgent.textfileDirectory}/mbsync.prom

              # The pre-new hook runs mbsync, post-new tags (terminal/email.nix).
              notmuch new

              {
                echo '# HELP mbsync_last_success_timestamp_seconds Unix time mbsync and notmuch new last both completed'
                echo '# TYPE mbsync_last_success_timestamp_seconds gauge'
                echo "mbsync_last_success_timestamp_seconds $(date +%s)"
              } >"$PROM.tmp"
              mv -f "$PROM.tmp" "$PROM"
            '';
          }
        ))
      ];
      StartInterval = 900; # 15 minutes, matching the equivalent systemd OnCalendar = "*:0/15"
      RunAtLoad = true;
      StandardOutPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
      StandardErrorPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
    };
  };

  # The laptop's shell history reaches storage/backups only by pushing; nothing
  # on tiger can reach a roaming laptop to pull it. Midday because the machine
  # has to be awake and able to route to tiger, and a missed calendar interval
  # runs once on the next wake. Transport is the ssh key held by the session
  # ssh-agent, so a run before the first interactive ssh of a boot will fail
  # and the next one will not.
  home-manager.users.kyle.launchd.agents.histdb-backup = {
    enable = true;
    config = {
      Label = "org.ondy.histdb-backup";
      ProgramArguments = [
        "${pkgs.histdb-backup}/bin/histdb-backup"
        "tiger:/mnt/backups/kyle/histdb"
      ];
      StartCalendarInterval = [
        {
          Hour = 13;
          Minute = 0;
        }
      ];
      EnvironmentVariables.TEXTFILE_DIR = config.systemFoundry.monitoringAgent.textfileDirectory;
      StandardOutPath = "${config.users.users.kyle.home}/Library/Logs/histdb-backup.log";
      StandardErrorPath = "${config.users.users.kyle.home}/Library/Logs/histdb-backup.log";
    };
  };

  # Most repos under ~/src have no remote, so this is their only second copy.
  # Everything the connection needs is spelled out here rather than taken
  # from ~/.ssh/config. The key is write-only into one directory on tiger
  # (tiger/configuration.nix), and IdentitiesOnly keeps ssh from offering the
  # agent's unrestricted key first, which tiger would accept and run without
  # the forced command. The destination path is relative to that directory,
  # since rrsync rejects "./" as unsafe. Four runs a day
  # because tiger keeps 4 hourly snapshots of storage/backups; the 22:00 run
  # lands before pika's 00:00 syncoid pull, so a day's commits reach pika
  # that night and the archive bucket the next morning.
  # Pinned rather than trusted on first use, since an unattended push has no
  # one to answer the prompt. Same key pika pins (pika/configuration.nix).
  programs.ssh.knownHosts.tiger = {
    hostNames = [ "[tiger.dmz.1ella.com]:2332" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjqSTUpNBfT0hwBYbPUjxgNhmYLDlEmv+juyxAzFiqt";
  };

  home-manager.users.kyle.launchd.agents.backup-git-repos = {
    enable = true;
    config = {
      Label = "org.ondy.backup-git-repos";
      ProgramArguments = [
        "${pkgs.backup-git-repos}/bin/backup-git-repos"
        "kyle@tiger.dmz.1ella.com:."
      ];
      StartCalendarInterval =
        map
          (Hour: {
            inherit Hour;
            Minute = 0;
          })
          [
            10
            14
            18
            22
          ];
      EnvironmentVariables = {
        TEXTFILE_DIR = config.systemFoundry.monitoringAgent.textfileDirectory;
        RSYNC_RSH = "ssh -F none -p 2332 -i ${config.sops.secrets.trex_backup_git_ssh_key.path} -o IdentitiesOnly=yes";
      };
      StandardOutPath = "${config.users.users.kyle.home}/Library/Logs/backup-git-repos.log";
      StandardErrorPath = "${config.users.users.kyle.home}/Library/Logs/backup-git-repos.log";
    };
  };
}

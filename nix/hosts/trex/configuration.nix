# Personal darwin system configuration for trex.
# Shared darwin plumbing lives in nix/modules/darwin_modules/.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [ ];

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

    # Local NixOS VM (via Apple's Virtualization.framework) that builds
    # Linux derivations when tiger is unreachable. Determinate's
    # replacement for nix-darwin's own nix.linux-builder, which asserts
    # `requires nix.enable` once Determinate owns Nix
    # (nix-darwin/nix-darwin#1505).
    nixosVmBasedLinuxBuilder.enable = true;

    # Prefer tiger (dedicated, faster) over the local VM; Nix falls back
    # to whichever builder is reachable and idle. The short ConnectTimeout
    # in root-ssh-config.nix keeps that failover fast instead of hanging.
    buildMachines = [
      {
        hostName = "tiger.dmz.1ella.com";
        sshUser = "svc.deploy";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 8;
        speedFactor = 10;
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

  # Photo working set (~/photos/_provisional, ~/photos/_projects). winnow
  # (culling) runs natively on macOS; helios (import) is still Linux-only
  # and a separate follow-up -- dino stays the import front door until then.
  # backup-photos/photos-recall/photos-promote cover the storage side:
  # mirror the working set out (to tiger, an external SSD, or opportunistically
  # to S3 while traveling), recall a shoot from tiger's archive to work on it,
  # and promote finished assets back. See the photo management plan for the
  # full model.
  home-manager.users.kyle.home.packages = with pkgs; [
    backup-photos
    photos-recall
    photos-promote
    winnow
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

  # Homebrew integration for GUI applications and tools not in nixpkgs.
  # Starting minimal; add casks/taps/brews here as needed.
  homebrew = {
    casks = lib.mkDefault [ ];
    taps = [ ];
    brews = [ ];
  };

  # Report metrics/logs to tiger, darwin-native equivalent of dino's
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
      # but keep the same permissive mode dino uses for consistency.
      mode = "0444";
    };
  };

  # Password script for automated mbsync service. Only kyle@ondy.org is
  # wired up for automated sync (matching dino - the other two accounts in
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

  # launchd equivalent of dino's systemd.user.timers.mbsync + notmuch-new
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
      StartInterval = 900; # 15 minutes, matching dino's OnCalendar = "*:0/15"
      RunAtLoad = true;
      StandardOutPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
      StandardErrorPath = "${config.users.users.kyle.home}/Library/Logs/mbsync.log";
    };
  };
}

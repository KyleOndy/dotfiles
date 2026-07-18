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

  # System version (managed by nix-darwin) - snapshot from when trex was
  # created, per-host, never bumped in lockstep with other hosts.
  system.stateVersion = 6;

  # Homebrew integration for GUI applications and tools not in nixpkgs.
  # Starting minimal; add casks/taps/brews here as needed.
  homebrew = {
    casks = lib.mkDefault [ ];
    taps = [ ];
    brews = [ ];
  };

  # Offload Linux package builds to tiger, same as dino. Also runs
  # nix.linux-builder.enable (nix/modules/darwin_modules/base.nix) as a
  # local fallback.
  systemFoundry.nixBuilders = {
    enable = true;
    machines = [
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

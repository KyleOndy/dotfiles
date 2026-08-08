# pika - the second copy.
#
# An ODROID-H2 on the LAN that pulls storage/photos and storage/backups off
# tiger and holds them longer than tiger does. Tier 2 of docs/backup-strategy.md.
#
# The direction of every arrow here is deliberate. pika opens every
# connection: syncoid pulls from tiger, vmagent and promtail push to tiger,
# the S3 sync goes straight out. tiger holds no credential for pika and
# cannot initiate anything toward it, because tiger is in the DMZ and pika is
# on the LAN. That boundary is enforced by the router, not by anything in
# this file, which is what makes it worth more than an ssh forced-command.
#
# Two flags would undo all of it. Never `zfs recv -F`, never
# `syncoid --force-delete`. Both make the receiving side destroy datasets to
# match the source, which turns a compromised tiger answering a request pika
# made into a wipe of the second copy. The NixOS syncoid module defaults to
# neither, and nothing below adds them.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  # `terraform -chdir=tf output archive_bucket_name`. Not looked up from
  # state: pika carries no terraform checkout.
  archiveBucket = "ondy-archive-resolved-pug";

  pushUnit = dataset: prefix: {
    description = "Push ${dataset} to the offsite archive bucket";
    # A cold push of tank/photos is 508G against the 2MB/s cap, so this runs
    # for days. Activation must not stop a sync in flight.
    restartIfChanged = false;
    environment = {
      ARCHIVE_BUCKET = archiveBucket;
      AWS_SHARED_CREDENTIALS_FILE = config.sops.secrets.archive_push_aws_credentials.path;
      AWS_CONFIG_FILE = "/etc/aws/s3-archive-push.conf";
      AWS_PROFILE = "archive-push";
    };
    serviceConfig = {
      # exec, not oneshot: a oneshot's start job stays pending for the whole
      # run, and switch-to-configuration blocks on any start job it issues. A
      # stale /run/nixos/start-list, left behind by an interrupted switch, is
      # enough to make it issue one.
      Type = "exec";
      # root because the received tree carries tiger's ownership and this has
      # to read all of it.
      User = "root";
      ExecStart = "${pkgs.s3-archive-push}/bin/s3-archive-push ${dataset} ${prefix}";
    };
  };

  pushTimer = at: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* ${at}:00";
      Persistent = true;
    };
  };

  # With prune, the only thing in the fleet that deletes from the bucket, and
  # it can only write delete markers: svc.archive-prune holds no
  # DeleteObjectVersion.
  reconcileUnit = prune: dataset: prefix: {
    description =
      if prune then
        "Reconcile and prune ${prefix}/ in the offsite archive bucket"
      else
        "Report ${prefix}/ against the offsite archive bucket";
    # Runs for hours against the same uplink. Activation must not stop a
    # reconcile in flight.
    restartIfChanged = false;
    environment = {
      ARCHIVE_BUCKET = archiveBucket;
      AWS_SHARED_CREDENTIALS_FILE = config.sops.secrets.archive_prune_aws_credentials.path;
      AWS_PROFILE = "archive-prune";
    };
    serviceConfig = {
      # exec for the same reason as pushUnit.
      Type = "exec";
      User = "root";
      ExecStart = "${pkgs.s3-archive-reconcile}/bin/s3-archive-reconcile ${lib.optionalString prune "--prune "}${dataset} ${prefix}";
    };
  };

  pruneTimer = day: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "${day} *-*-* 05:00:00";
      Persistent = true;
    };
  };

  tigerSyncoid = "svc.syncoid@tiger.dmz.1ella.com";
in
{
  imports = [ ./hardware-configuration.nix ];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems.zfs = true;

    # No zfs_arc_max. The Pi plan this replaces capped ARC because it had 4GB
    # of RAM. With 32GB the 50% default lands at 16GB and nothing else on the
    # box wants memory, so the metadata for a ~1.18TB pool fits outright,
    # which is what keeps scrubs and syncoid deltas quick.
    zfs.extraPools = [ "tank" ];
  };

  networking = {
    hostName = "pika";
    # Required for ZFS. Not optional, and easy to miss: cogsworth has none
    # because it has no pools.
    hostId = "ae260477";
    useDHCP = lib.mkDefault true;
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings.LC_ALL = "en_US.UTF-8";
  };

  nix.settings = {
    # deployment_target.nix hands every NixOS node
    # trusted-substituters = [ "ssh://svc.deploy@tiger.dmz.1ella.com" ]. It is
    # weaker than it looks (Nix only permits trusted users to opt in via
    # --substituters; it is not consulted by default), but pika is the host
    # that insures against tiger, so it takes nothing from tiger at all.
    trusted-substituters = lib.mkForce [ ];

    # The shared list also carries nixos-raspberrypi.cachix.org, which can
    # never serve an x86_64-linux path. Dropping it saves a lookup against
    # every store path this host builds, and it builds its own.
    substituters = lib.mkForce [ "https://cache.nixos.org" ];
  };

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    # Snapshots arrive from tiger by replication. pika creates none of its
    # own, which is also why syncoid runs --no-sync-snap and never needs the
    # `snapshot` verb delegated on tiger.
    autoSnapshot.enable = false;
  };

  # Retention on pika must be >= retention on tiger, always. sanoid here does
  # not snapshot, it only prunes, and if it ever prunes faster than tiger
  # does then tiger dropping an old snapshot cascades into the backup and the
  # second copy quietly becomes a mirror of the first.
  #
  #   tiger storage/backups: hourly 4,  daily 31, monthly 24, yearly 10
  #   tiger storage/photos:            daily  8, monthly 12
  services.sanoid = {
    enable = true;
    extraArgs = [ "--verbose" ];
    datasets = {
      "tank/backups" = {
        autosnap = false;
        autoprune = true;
        hourly = 4;
        daily = 60;
        monthly = 36;
        yearly = 15;
      };
      "tank/photos" = {
        autosnap = false;
        autoprune = true;
        hourly = 0;
        daily = 30;
        monthly = 24;
        yearly = 10;
      };
    };
  };

  # Pull, never push. tiger's delegation is send,hold,release and nothing
  # more, so this cannot create, receive into, or destroy anything on tiger
  # even if pika is the compromised end.
  services.syncoid = {
    enable = true;
    interval = "daily";
    sshKey = config.sops.secrets.pika_syncoid_ssh_key.path;
    commonArgs = [
      "--no-sync-snap" # sanoid on tiger owns snapshot creation
      "--sshport"
      "2332" # tiger's sshd is not on 22 (tiger/configuration.nix:129)
    ];
    # Trimmed from the module default, which also grants change-key,
    # compression and mountpoint. Nothing here sends raw encrypted or raw
    # compressed streams, so those are unused authority.
    # A property named in recvOptions must be delegated by name, or zfs recv
    # logs a permission error per stream, skips it, and still exits 0.
    localTargetAllow = [
      "create"
      "mount"
      "readonly"
      "receive"
      "rollback"
    ];
    commands = {
      "storage/photos" = {
        source = "${tigerSyncoid}:storage/photos";
        target = "tank/photos";
        # Received datasets are readonly. Set on receive rather than by hand
        # afterwards so it is true from the first stream, not from whenever
        # someone remembered.
        recvOptions = "o readonly=on";
      };
      "storage/backups" = {
        source = "${tigerSyncoid}:storage/backups";
        target = "tank/backups";
        recvOptions = "o readonly=on";
      };
    };
  };

  # Held under the measured 24.6 Mbps uplink: saturating it fills the modem's
  # buffer and takes interactive latency with it. A config file rather than
  # the unit environment because awscli has no env var for max_bandwidth.
  environment.etc."aws/s3-archive-push.conf".text = ''
    [profile archive-push]
    s3 =
      max_bandwidth = 2MB/s
  '';

  # Fixed offsets rather than After= ordering on syncoid: a stuck pull delays
  # the push instead of cancelling it. Two hours apart so the walks do not
  # contend for the uplink.
  systemd.services.s3-archive-push-photos = pushUnit "tank/photos" "photos";
  systemd.services.s3-archive-push-backups = pushUnit "tank/backups" "backups";
  systemd.timers.s3-archive-push-photos = pushTimer "04:00";
  systemd.timers.s3-archive-push-backups = pushTimer "06:00";

  systemd.services.s3-archive-prune-photos = reconcileUnit true "tank/photos" "photos";
  systemd.services.s3-archive-prune-backups = reconcileUnit true "tank/backups" "backups";
  systemd.timers.s3-archive-prune-photos = pruneTimer "Sun";
  systemd.timers.s3-archive-prune-backups = pruneTimer "Mon";

  # No timer. Started by hand off the S3ArchiveObjectsMissing runbook.
  systemd.services.s3-archive-reconcile-photos = reconcileUnit false "tank/photos" "photos";
  systemd.services.s3-archive-reconcile-backups = reconcileUnit false "tank/backups" "backups";

  # syncoid runs as a system user with no home, so ssh has nowhere to write a
  # known_hosts and every pull dies on "Host key verification failed". This
  # writes /etc/ssh/ssh_known_hosts instead, which also pins tiger's identity
  # rather than trusting whatever answers on first use. The bracket form is
  # how ssh records a non-default port.
  programs.ssh.knownHosts = {
    tiger = {
      hostNames = [ "[tiger.dmz.1ella.com]:2332" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjqSTUpNBfT0hwBYbPUjxgNhmYLDlEmv+juyxAzFiqt";
    };
  };

  sops.secrets = {
    # vmagent runs DynamicUser and promtail is a static user; both need to
    # read this, so it is group-scoped rather than world-readable.
    monitoring_password = {
      mode = "0440";
      group = "monitoring-secrets";
    };

    # awscli2 credentials INI files, one profile each, for the two IAM users
    # in tf/archive-backup.tf.
    archive_push_aws_credentials = {
      owner = "root";
      mode = "0400";
    };
    archive_prune_aws_credentials = {
      owner = "root";
      mode = "0400";
    };

    pika_syncoid_ssh_key = {
      owner = "syncoid";
      mode = "0400";
    };

    pika_histdb_ssh_key = {
      owner = "kyle";
      mode = "0400";
    };
  };

  # The second and last thing pika initiates to tiger. Everything the
  # connection needs is spelled out here rather than coming from a user ssh
  # config, so the appliance profile keeps its empty ~/.ssh. tiger's host key
  # is pinned in programs.ssh.knownHosts above, and the credential is
  # write-only into one directory (tiger/configuration.nix).
  systemd.services.histdb-backup = {
    description = "Push the shell history database to tiger";
    environment.RSYNC_RSH = "ssh -p 2332 -i ${config.sops.secrets.pika_histdb_ssh_key.path} -o IdentitiesOnly=yes";
    serviceConfig = {
      Type = "oneshot";
      User = "kyle";
      # Path is relative to the directory rrsync confines the key to.
      ExecStart = "${pkgs.histdb-backup}/bin/histdb-backup tiger.dmz.1ella.com:/";
    };
  };

  systemd.timers.histdb-backup = {
    description = "Daily shell history push";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  users.groups.monitoring-secrets = { };
  users.users.promtail.extraGroups = [ "monitoring-secrets" ];
  systemd.services.vmagent.serviceConfig.SupplementaryGroups = [ "monitoring-secrets" ];

  # Agent mode. Everything pushes outward, which is what works across the DMZ
  # boundary and what makes absence-based alerting possible when pika itself
  # is the thing that died.
  systemFoundry.monitoringStack = {
    enable = true;
    nodeExporter.enable = true;

    # AHCI passes SMART through, so the smartctl textfile collector in
    # deployment_target.nix covers the shucked drives with no new machinery.
    # That is most of why they go on the SATA ports rather than back in their
    # USB enclosures.
    zfsExporter.enable = true;

    vmagent = {
      enable = true;
      remoteWriteUrl = "https://metrics.tiger.infra.ondy.org/api/v1/write";
      basicAuth = {
        username = "monitoring";
        passwordFile = config.sops.secrets.monitoring_password.path;
      };
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels.host = "pika";
            }
          ];
        }
        {
          job_name = "zfs";
          static_configs = [
            {
              targets = [ "127.0.0.1:9134" ];
              labels.host = "pika";
            }
          ];
        }
      ];
    };

    promtail = {
      enable = true;
      lokiUrl = "https://loki.tiger.infra.ondy.org/loki/api/v1/push";
      basicAuth = {
        username = "monitoring";
        passwordFile = config.sops.secrets.monitoring_password.path;
      };
      extraLabels.host = "pika";
    };
  };

  # Provisioning, done by hand once, recorded here because nothing in Nix
  # creates it. Same house style as tiger/configuration.nix:200.
  #
  # 1. Get a NixOS installer onto the board. It arrived running Debian, so
  #    nixos-anywhere kexecs one into RAM over the network and no media is
  #    involved. It has no sudo support, so root needs a key of its own first:
  #      ssh -t kyle@<ip> 'sudo install -d -m700 /root/.ssh &&
  #        sudo cp ~/.ssh/authorized_keys /root/.ssh/'
  #      nix run github:nix-community/nixos-anywhere -- \
  #        --flake .#pika --phases kexec root@<ip>
  #
  #    `make iso-pika` builds a headless installer ISO for the case where
  #    there is no running Linux to kexec from. That path wants a monitor
  #    once, because the UEFI prefers whatever is already on the NVMe: F7 at
  #    post picks the stick, DEL opens setup.
  #
  # 2. Partition the NVMe. Labels, because hardware-configuration.nix
  #    mounts by label:
  #      sgdisk -Z /dev/nvme0n1
  #      sgdisk -n1:0:+512M -t1:ef00 -c1:boot /dev/nvme0n1
  #      sgdisk -n2:0:0     -t2:8300 -c2:root /dev/nvme0n1
  #      mkfs.vfat -n NIXBOOT /dev/nvme0n1p1
  #      mkfs.ext4 -L NIXROOT /dev/nvme0n1p2
  #      mount /dev/disk/by-label/NIXROOT /mnt
  #      mkdir -p /mnt/boot && mount /dev/disk/by-label/NIXBOOT /mnt/boot
  #
  # 3. From trex, with the host key generated and its age key already
  #    enrolled in .sops.yaml. --build-on remote so the closure is built by
  #    the four cores in front of you and never passes through tiger:
  #      nix run github:nix-community/nixos-anywhere -- \
  #        --flake .#pika --phases install,reboot --build-on remote \
  #        --extra-files ./extra root@<ip>
  #
  # 4. The mirror, only once both drives are confirmed. by-id, never by-path,
  #    because /dev/sdX moves:
  #      zpool create -o ashift=12 -m /tank tank \
  #        mirror /dev/disk/by-id/ata-WDC_<serial-a> \
  #               /dev/disk/by-id/ata-WDC_<serial-b>
  #      zfs set compression=lz4 atime=off xattr=sa dedup=off tank
  #      zfs set acltype=posixacl tank
  #
  #    lz4 rather than zstd: JPEG, RAF and MOV do not compress, so zstd buys
  #    a ratio that is never going to show up. acltype=posixacl matches what
  #    storage/photos got by hand on tiger.
  #
  # 5. Then add the sops secrets and deploy.

  system.stateVersion = "25.11";
}

let
  disk-id = id: "/dev/disk/by-id/${id}";
  # NVMe SSD for OS
  nvme = disk-id "nvme-WDC_CL_SN720_SDAQNTW-512G-2000_21060X802510";
  # 4x 3.6TB HDDs for RAIDZ1 storage
  hdd1 = disk-id "wwn-0x5000cca0bcd45f4d"; # sda
  hdd2 = disk-id "wwn-0x5000cca0bcd468f8"; # sdb
  hdd3 = disk-id "wwn-0x5000cca0bcd463d8"; # sdc
  hdd4 = disk-id "wwn-0x5000cca0bcd46880"; # sdd
in
{
  disko.devices = {
    disk = {
      # NVMe SSD for OS
      nvme = {
        device = nvme;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              name = "boot";
              size = "1M";
              type = "EF02"; # BIOS boot
            };
            esp = {
              name = "ESP";
              size = "1G";
              type = "EF00"; # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              name = "root";
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # HDD 1 for ZFS RAIDZ1
      hdd1 = {
        device = hdd1;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "storage";
              };
            };
          };
        };
      };

      # HDD 2 for ZFS RAIDZ1
      hdd2 = {
        device = hdd2;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "storage";
              };
            };
          };
        };
      };

      # HDD 3 for ZFS RAIDZ1
      hdd3 = {
        device = hdd3;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "storage";
              };
            };
          };
        };
      };

      # HDD 4 for ZFS RAIDZ1
      hdd4 = {
        device = hdd4;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "storage";
              };
            };
          };
        };
      };
    };

    # ZFS RAIDZ1 pool with 4 HDDs (~10.8TB usable)
    zpool = {
      storage = {
        type = "zpool";
        mode = "raidz1";
        rootFsOptions = {
          compression = "lz4";
          acltype = "posixacl";
          xattr = "sa";
          relatime = "on";
          normalization = "formD";
          dnodesize = "auto";
        };
        options = {
          ashift = "12";
        };

        datasets = {
          # Media storage - optimized for large files (movies/TV)
          media = {
            type = "zfs_fs";
            options = {
              recordsize = "1M"; # Optimal for large video files
              mountpoint = "/mnt/storage/media";
            };
          };

          # Backup storage - optimized for ZFS send/receive
          backups = {
            type = "zfs_fs";
            options = {
              mountpoint = "/mnt/storage/backups";
              atime = "off"; # Don't track access times for backups
            };
          };

          # Downloads parent dataset
          downloads = {
            type = "zfs_fs";
            options = {
              mountpoint = "/mnt/storage/downloads";
            };
          };

          # Incomplete downloads - disable sync for speed
          "downloads/incomplete" = {
            type = "zfs_fs";
            options = {
              mountpoint = "/mnt/storage/downloads/incomplete";
              sync = "disabled"; # Faster writes for active downloads
            };
          };

          # Complete downloads - normal sync
          "downloads/complete" = {
            type = "zfs_fs";
            options = {
              mountpoint = "/mnt/storage/downloads/complete";
            };
          };

          # Service data - smaller recordsize for databases/configs
          services = {
            type = "zfs_fs";
            options = {
              recordsize = "16K"; # Better for small files
              mountpoint = "/mnt/storage/services";
            };
          };
        };
      };
    };
  };
}

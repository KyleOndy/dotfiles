let
  disk-id = id: "/dev/disk/by-id/${id}";
  d1 = disk-id "wwn-0x5000cca25ecf8f46"; # sda
  d2 = disk-id "wwn-0x5000cca25ecf9052"; # sdb
in
{
  disko.devices = {
    disk = {
      disk1 = {
        device = d1;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              name = "boot0";
              size = "1M";
              type = "EF02";
            };
            esp = {
              name = "ESP0";
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            mdadm = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "raid1";
              };
            };
          };
        };
      };
      disk2 = {
        device = d2;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              name = "boot1";
              size = "1M";
              type = "EF02";
            };
            esp = {
              name = "ESP1";
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";
              };
            };
            mdadm = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "raid1";
              };
            };
          };
        };
      };
    };
    mdadm = {
      raid1 = {
        type = "mdadm";
        level = 1;
        content = {
          type = "gpt";
          partitions = {
            primary = {
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
    };
  };
}

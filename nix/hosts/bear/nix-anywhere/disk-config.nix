let
  nvme0 = "/dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF723300SS450RGN";
  nvme1 = "/dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF7220009B450RGN";
in
{
  disko.devices = {
    disk = {
      nvme0 = {
        device = nvme0;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            esp = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };
      nvme1 = {
        device = nvme1;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            esp = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };
    };
    mdadm = {
      root = {
        type = "mdadm";
        level = 1;
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };
    };
  };
}

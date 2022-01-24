# This is a catchall for configuration items that are common across all
# machines and at this time do not make sense to break out into their own file.
{ ... }:

{
  boot.kernelModules = [ "kvm-amd" "kvm-intel" ];
  virtualisation.libvirtd.enable = true;

  # https://blog.christophersmart.com/2016/08/31/configuring-qemu-bridge-helper-after-access-denied-by-acl-file-error/
  environment.etc = {
    "qemu/bridge.conf" = {
      text = ''
        allow all
      '';

      # The UNIX file mode bits
      #mode = "0440";
    };
  };
}

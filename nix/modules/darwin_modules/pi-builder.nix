{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.systemFoundry.piBuilder;
in
{
  options.systemFoundry.piBuilder.enable = lib.mkEnableOption "the privileged network helper for isolated Pi builds";

  # nix-darwin activation runs as root. Disabling must also remove the SUID copy.
  config.system.activationScripts.postActivation.text = ''
    ${lib.getExe pkgs.pi-builder.softnetInstaller} ${
      lib.escapeShellArgs [
        (if cfg.enable then "install" else "remove")
        (if cfg.enable then "${pkgs.pi-builder.softnet}/bin/softnet" else "-")
        "/Library/PrivilegedHelperTools"
      ]
    }
  '';
}

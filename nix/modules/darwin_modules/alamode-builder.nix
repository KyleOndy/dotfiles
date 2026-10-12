{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.systemFoundry.alamodeBuilder;
in
{
  options.systemFoundry.alamodeBuilder.enable = lib.mkEnableOption "the privileged network helper for isolated alamode builds";

  # nix-darwin activation runs as root. Disabling must also remove the SUID copy.
  config.system.activationScripts.postActivation.text = ''
    ${lib.getExe pkgs.alamode-builder.softnetInstaller} ${
      lib.escapeShellArgs [
        (if cfg.enable then "install" else "remove")
        (if cfg.enable then "${pkgs.alamode-builder.softnet}/bin/softnet" else "-")
        "/Library/PrivilegedHelperTools"
      ]
    }
  '';
}

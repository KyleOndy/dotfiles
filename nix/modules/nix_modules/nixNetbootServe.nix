{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.nixNetbootServe;
in
{
  options.systemFoundry.nixNetbootServe = {
    enable = mkEnableOption ''
      Dynamically generate netboot images for arbitrary NixOS system closures,
      profiles, or configurations with 10s iteration times.

      https://github.com/DeterminateSystems/nix-netboot-serve
    '';
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports";
    };
    gcRootDir = mkOption { type = types.str; };
    configurationDir = mkOption { type = types.str; };
    profileDir = mkOption { type = types.str; };
    cpioCacheDir = mkOption { type = types.str; };
    listenHost = mkOption { type = types.str; };
    listenPort = mkOption { type = types.int; };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mfIf cfg.openFirewall [ cfg.listenPort ];

    systemd.services.nix-netboot-serve = {
      enable = true;
      description = "run nixNetbootServe";
      serviceConfig = {
        ExecStartPre = ''
          ${pkgs.coreutils}/bin/mkdir -p \
            ${cfg.gcRootDir} \
            ${cfg.configurationDir} \
            ${cfg.profileDir} \
            ${cfg.cpioCacheDir}
        '';

        ExecStart = ''
          ${pkgs.nix-netboot-serve}/bin/nix-netboot-serve \
            --gc-root-dir ${cfg.gcRootDir} \
            --config-dir ${cfg.configurationDir} \
            --profile-dir ${cfg.profileDir} \
            --cpio-cache-dir ${cfg.cpioCacheDir} \
            --listen ${cfg.listenHost}:${toString cfg.listenPort}
        '';
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}

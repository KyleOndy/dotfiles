{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.binary_cache;
in
{
  options.systemFoundry.binary_cache = {
    enable = mkEnableOption ''
      serve a binary cache
    '';
    domainName = mkOption {
      type = types.str;
      description = "Domain to server gitea under";
    };
  };

  config = mkIf cfg.enable {

    services = {
      nix-serve = {
        enable = true;
        secretKeyFile = "/var/nix-cache-priv.pem";
      };
    };
    systemFoundry.nginxReverseProxy.sites."${cfg.domainName}" =
      mkIf (config.systemFoundry.nginxReverseProxy.enable)
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString config.services.nix-serve.port}";
        };

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:${toString config.services.nix-serve.port}";
        };
  };
}

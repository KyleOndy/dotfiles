{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.llm;
in
{
  options.systemFoundry.llm = {
    enable = mkEnableOption ''
      https://github.com/oobabooga/text-generation-webui
    '';
    domainName = mkOption {
      type = types.str;
      description = "Domain to webui under";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open firewall ports";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mfIf cfg.openFirewall [ 7860 7861 ];

    systemFoundry.nginxReverseProxy."${cfg.domainName}" = {
      enable = true;
      proxyPass = "http://127.0.0.1:7860";
    };

    #systemd.services.llm = {
    #  enable = true;
    #  description = "run llm";
    #  wantedBy = [ "multi-user.target" ];
    #  path = [ pkgs.nix ];
    #  script = ''
    #    pushd /home/kyle/src/text-generation-webui
    #    nix-shell --command "python ./server.py --listen"
    #  '';
    #};
  };
}

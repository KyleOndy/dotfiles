{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.systemFoundry.services.nzbget;
  pkg = pkgs.nzbget;
  stateDir = "/var/lib/nzbget";
  configOpts = concatStringsSep " " (mapAttrsToList (name: value: "-o ${name}=${escapeShellArg (toStr value)}") cfg.settings);
  toStr = v:
    if v == true then "yes"
    else if v == false then "no"
    else if isInt v then toString v
    else v;
in
{
  options = {
    systemFoundry.services.nzbget = {
      enable = mkEnableOption "NZBGet";

      user = mkOption {
        type = types.str;
        default = "nzbget";
        description = "User account under which NZBGet runs";
      };

      group = mkOption {
        type = types.str;
        default = "nzbget";
        description = "Group under which NZBGet runs";
      };

      configFile = mkOption {
        type = types.path;
        default = "${stateDir}/nzbget.conf";
        description = "Path to config file. Useful for reading secrets from disk";
      };

      settings = mkOption {
        type = with types; attrsOf (oneOf [ bool int str ]);
        default = { };
        description = ''
          NZBGet configuration, passed via command line using switch -o. Refer to
          <link xlink:href="https://github.com/nzbget/nzbget/blob/master/nzbget.conf"/>
          for details on supported values. These values override the `configFile` option.
        '';
        example = {
          MainDir = "/data";
        };
      };
    };
  };

  # implementation

  config = mkIf cfg.enable {
    systemFoundry.services.nzbget.settings = {
      # allows nzbget to run as a "simple" service
      OutputMode = "loggable";
      # use journald for logging
      WriteLog = "none";
      ErrorTarget = "screen";
      WarningTarget = "screen";
      InfoTarget = "screen";
      DetailTarget = "screen";
      # required paths
      ConfigTemplate = "${pkg}/share/nzbget/nzbget.conf";
      WebDir = "${pkg}/share/nzbget/webui";
      # nixos handles package updates
      UpdateCheck = "none";
    };

    systemd.services.nzbget = {
      description = "NZBGet Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        unrar
        p7zip
      ];

      preStart = ''
        if [ ! -f ${cfg.configFile} ]; then
          ${pkgs.coreutils}/bin/install -m 0700 ${pkg}/share/nzbget/nzbget.conf ${cfg.configFile}
        fi
      '';

      serviceConfig = {
        StateDirectory = "nzbget";
        StateDirectoryMode = "0750";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0002";
        Restart = "on-failure";
        ExecStart = "${pkg}/bin/nzbget --server --configfile ${cfg.configFile} ${configOpts}";
        ExecStop = "${pkg}/bin/nzbget --quit";
      };
    };

    users.users = mkIf (cfg.user == "nzbget") {
      nzbget = {
        home = stateDir;
        group = cfg.group;
        uid = config.ids.uids.nzbget;
      };
    };

    users.groups = mkIf (cfg.group == "nzbget") {
      nzbget = {
        gid = config.ids.gids.nzbget;
      };
    };
  };
}

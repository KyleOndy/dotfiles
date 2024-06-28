{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.deployment_target;
in
{
  options.systemFoundry.deployment_target = {
    enable = mkEnableOption ''
      Basic configuration which allows the node to be comply with assumptions I
      made about the target node.

      This is also a kind of catch all when I want to unilaterally deploy
      something out to all managed nodes. I try to keep this as minimal as I
      can, just enough to get connectivity to deploy the rest of the
      configuration. Due to this, some of the configuration in here will de
      duplicated by other modules.

      This only gets applied to NixOS nodes.
    '';
  };

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      git # working this repos locally
      molly-guard # prevent footguns from runing my day
      neovim # file editing
      rsync # syncing files
    ];

    users = {
      defaultUserShell = pkgs.bash;
      mutableUsers = false;
      users."svc.deploy" = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPassword =
          "$6$XTNiJhQm1$D3M90syVNZdTazCOZIAF8TLK/hD4oSi3Xdst62dCkWR44ia3rujnPx.yWT6BaU4tvu1im5nR20WcjWnhPMTIV/";
        # todo: make a key for just deploys
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDKPwXdnorhTtQOZ0iE3YJHtb8YYfhjnaav8ArQQuIOQR4tAxPyxMucKHuTsCH3soFFBTY1wg0KVt4x+6op4bfhr0Q40bqQprwy/5LFmui1FZhFhAxrbx4abK0Kh6NaKjvYmV1Lh9+gSKTK9edxWixX90ZI6YHhVEf5JSeUbVcKYKMD4gp5CR5EC2l8/bd/4nQ3n74Od4faa4DfE4qaleEQ4IcAONR0WGxtX1aP2Q4V+UfbS2gvBA0c/V0eIIXnscMcqBbzrYPMxQ7a8umpA65ByHgdFBnCeyvhKjxl2E1HoZcPzruBXs/NqmvnhG6iuFDPtG2G+Lj6xjEYffJcI2VnkYAyczD63P6zlsBIPbyvq7aS8jGR0CsNbfJExjXLmB3M4k2ANBidfai26zAN/Pn73MOA9ieShy1FUZCYf3nM5+EO+0Al6v48eJXNrcUNqKRUHEdyRi+Sd3Nj5shZ61lgCdSZk78XUjXpWcmhbFGaR+9aXn3kUV5rDjqpLzp4alU= kyle@dino"
        ];
      };
    };
    services = {
      openssh = {
        enable = true;
        settings.PermitRootLogin = "no";
      };
      # TODO: do I still need RuntimeDirectorySize?
      logind.extraConfig = ''
        RuntimeDirectorySize=8G
      '';
    };

    nixpkgs.config.allowUnfree = true;
    nix = {
      package = pkgs.nixVersions.latest;
      settings = {
        trusted-users = [ "root" "@wheel" ]; # todo: security issue?
        trusted-substituters = [ "ssh://svc.deploy@tiger.dmz.1ella.com" ];
        auto-optimise-store = true;
      };
      nixPath = [ "nixpkgs=${pkgs.path}" ];
      extraOptions = ''
        experimental-features = nix-command flakes
      '';
    };
    security.sudo.wheelNeedsPassword = false;

    # this file path _feels_ suspect, but works
    sops.defaultSopsFile = ./../../secrets/secrets.yaml;

    networking.firewall.allowedTCPPorts = [
      # TODO: I don't think we need these ports open
      # 80 # http
      # 443 # http
    ];
    networking.firewall.enable = false; # TODO: why is this not true?
    #services.nginx = {
    #  enable = true;
    #  # todo: return a more bare page
    #  virtualHosts."default".default = true;
    #  # todo: can I pass in the full domain name here?
    #  # todo: add basic auth
    #};
    # todo: add in old stuff
    #systemFoundry.nginxReverseProxy = {
    #  enable = true;
    #  domainName = "${config.networking.hostName}.*";
    #  proxyPass = "http://127.0.0.1:9002/metrics";
    #};

    #######################################################################
    # TODO: refactor out below configuration into more generic modules
    #######################################################################
    programs = {
      # TODO: why?
      systemtap.enable = true;
    };
    security = {
      acme = {
        # TODO: acme being here feels very wrong
        # so I do not need to set it in every module
        acceptTerms = true;
        defaults = {
          email = "kyle@ondy.org";
          dnsProvider = "namecheap";
          credentialsFile = config.sops.secrets.namecheap.path;
        };
      };
    };
    # todo: fix: need to create an acme user and group do get the deploy
    #            working in alpha
    users.users.acme = {
      isSystemUser = true;
      group = "acme";
    };
    # /fix
    users.groups.acme = { };
  };
}

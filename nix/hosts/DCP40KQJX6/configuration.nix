{ config, pkgs, ... }:

{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    vim
    (nerdfonts.override {
      fonts = [
        "Hack" # TODO: is this not handeled by other font configuration?
      ];
    })
  ];

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix = {
    package = pkgs.nixVersions.latest;
    nixPath = [ "nixpkgs=${pkgs.path}" ]; # todo: this is actaully bad, right?
    extraOptions = ''
      builders-use-substitutes = true
      experimental-features = nix-command flakes
      build-users-group = nixbld # todo: this was in nix.conf by default
    '';
    settings = {
      trusted-users = [ "kyle.ondy" ];
    };
  };
  nixpkgs = {
    config = {
      allowUnfree = true;
    };
  };

  # Create /etc/bashrc that loads the nix-darwin environment.
  programs.zsh.enable = true; # default shell on catalina

  launchd.user.agents = {
    docker-desktop-kubeconfig = {
      command = "bash -c '${pkgs.ripgrep}/bin/rg --quiet --fixed-strings docker-desktop $HOME/.kube/config && mv $HOME/.kube/config $HOME/.kube/configs/docker-desktop'";
      serviceConfig = {
        StartInterval = 60;
        ProcessType = "Background";
        WatchPaths = [ "/Users/kyle.ondy/.kube/config" ]; # TODO: hardcoded user
      };
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system = {
    defaults = {
      dock = {
        autohide = true;
        orientation = "bottom";
      };
    };
    stateVersion = 4;
  };
}

# this shell.nix lets you limp along and run ./make ... if you happen to bork yor regular enviroenmt

{}:
let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs { };
  hm = import sources.home-manager { };
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    #nix
    hm.home-manager

    # for flashing keyboard firmwares
    #teensy-loader-cli
  ];
  # if the system wide enviroemtn has been borked, or is being configured for
  # the first time, `nix-shell --pure` should be able to get you back up and
  # running. A little safety net.
  shellHook = ''
    # NIX_PATH is set sysetm-wide in `env.nix`. Since that doesn't take effect
    # until we run `home-manager switch`, we would have to run that twice to
    # actaully have the right version of packages. Setting it here explicitly
    # fixs that.
    export NIX_PATH=nixpkgs=${pkgs.path}
    ${(import ./default.nix).pre-commit-check.shellHook}
  '';
}

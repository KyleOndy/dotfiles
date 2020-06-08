# this shell.nix lets you limp along and run ./make ... if you happen to bork yor regular enviroenmt

{}:
let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};
  hm = import sources.home-manager {};
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    # for pure shell
    nix
    hm.home-manager

    # for nixpkgs-fmt
    nixpkgs-fmt
    cargo

    # pre-commit
    # https://pre-commit.com/
    pre-commit
    detect-secrets
    shfmt
    ruby
  ];
  # if the system wide enviroemtn has been borked, or is being configured for
  # the first time, `nix-shell --pure` should be able to get you back up and
  # running. A little safety net.
  shellHook = ''
    export NIX_PATH=nixpkgs=${pkgs.path}
  '';
}

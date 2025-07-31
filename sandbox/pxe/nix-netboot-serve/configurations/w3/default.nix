(import <nixpkgs/nixos> {
  configuration =
    { pkgs, ... }:
    {
      imports = [ ../commom.nix ];
      networking.hostName = "w3";
    };
}).system

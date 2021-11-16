{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
  ];

  shellHook = ''
    ${(import ./default.nix).pre-commit-check.shellHook}
  '';
}

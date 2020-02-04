{ pkgs, ... }:
# todo: what is the best way to handle python?

with pkgs;
let
  python-packages = python-packages: with python-packages; [ virtualenv ];
  system-python-with-packages = python3.withPackages python-packages;

in
{
  home.packages = [ system-python-with-packages ];

}

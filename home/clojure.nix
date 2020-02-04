{ pkgs, ... }:

{
  home.packages = [
    pkgs.clj-kondo # linter
    pkgs.clojure
    pkgs.joker # linter
    pkgs.leiningen # build tooling
  ];
}

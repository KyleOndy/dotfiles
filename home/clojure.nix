{ pkgs, ... }:

{
  home.packages = with pkgs; [
    clj-kondo # linter
    clojure
    joker # linter
    leiningen # build tooling
  ];
}

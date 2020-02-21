{ pkgs, ... }:

{
  home.packages = [
    pkgs.clj-kondo # linter
    pkgs.clojure
    pkgs.joker # linter
    pkgs.leiningen # build tooling

    # try using IntelliJ  and cursive
    pkgs.jetbrains.idea-community
  ];
}

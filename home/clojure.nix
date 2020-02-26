{ pkgs, ... }:

{
  home.packages = with pkgs; [
    clj-kondo # linter
    clojure
    joker # linter
    leiningen # build tooling

    # try using IntelliJ  and cursive
    jetbrains.idea-community
  ];
}

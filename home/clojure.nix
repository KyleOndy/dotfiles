{ pkgs, ... }:

{
  home.packages = [ pkgs.clojure pkgs.leiningen ];
}


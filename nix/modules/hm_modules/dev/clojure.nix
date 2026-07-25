{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.clojure;

in
{
  options.hmFoundry.dev.clojure = {
    enable = mkEnableOption "clojure stuff";

    enableKaocha = mkEnableOption "kaocha modern test runner";

  };

  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        # https://github.com/babashka/babashka
        babashka

        # https://github.com/clj-kondo/clj-kondo
        clj-kondo # linter

        # https://clojure.org/
        clojure # core language

        # https://github.com/candid82/joker
        joker # small Clojure interpreter, linter and formatter

        # https://github.com/technomancy/leiningen
        leiningen # build tooling

        # https://github.com/clojure-lsp/clojure-lsp
        clojure-lsp

        # https://github.com/babashka/neil#nix
        neil # A CLI to add common aliases and features to deps.edn-based projects.

        zprint

        # Additional formatters for configurable formatting support
        cljstyle # Opinionated Clojure code formatter
        cljfmt # Alternative Clojure code formatter

        # Modern Clojure development tools
        jet # JSON/EDN processing - perfect for Babashka scripting
        portal # Data visualization for REPL workflows

      ]
      ++ optionals cfg.enableKaocha [
        # Modern test runner (optional)
        kaocha # Full featured next gen Clojure test runner
      ];

    programs = {
      java = {
        enable = true;
      };

      # Enable bash completion for clojure CLI
      bash.enableCompletion = true;
    };

    # Global deps.edn. It is a literal file rather than something generated
    # from nix: it is Clojure data, read only by Clojure, and rendering it
    # through a hand-rolled serializer is how the alias keys got mangled.
    home.file.".clojure/deps.edn".source = ./clojure-deps.edn;
  };
}

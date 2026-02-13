{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.clojure;

  # Helper to format EDN data
  formatEdn =
    data:
    let
      formatValue =
        value:
        if builtins.isString value then
          ''"${value}"''
        else if builtins.isBool value then
          (if value then "true" else "false")
        else if builtins.isInt value then
          toString value
        else if builtins.isList value then
          "[${lib.concatMapStringsSep " " formatValue value}]"
        else if builtins.isAttrs value then
          if value ? "mvn/version" then
            "{:mvn/version ${formatValue value."mvn/version"}}"
          else if value ? "git/url" then
            "{:git/url ${formatValue value."git/url"} :git/sha ${formatValue value."git/sha"}}"
          else if value ? "git/tag" then
            "{:git/tag ${formatValue value."git/tag"} :git/sha ${formatValue value."git/sha"}}"
          else
            "{${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: ":${k} ${formatValue v}") value)}}"
        else
          "nil";

      formatAlias =
        name: spec:
        let
          parts = lib.mapAttrsToList (
            k: v:
            if k == "extra-deps" || k == "deps" then
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} {${
                lib.concatStringsSep " " (lib.mapAttrsToList (dep: ver: "${formatValue dep} ${formatValue ver}") v)
              }}"
            else if k == "main-opts" || k == "jvm-opts" then
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} ${formatValue v}"
            else if k == "exec-fn" then
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} ${v}"
            else if k == "exec-args" then
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} ${formatValue v}"
            else if k == "replace-deps" then
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} ${formatValue v}"
            else
              ":${lib.replaceStrings [ "-" ] [ "_" ] k} ${formatValue v}"
          ) spec;
        in
        ":${name} {${lib.concatStringsSep "\n           " parts}}";
    in
    ''
      {:aliases
       {${lib.concatStringsSep "\n      " (lib.mapAttrsToList formatAlias data)}}}
    '';
in
{
  options.hmFoundry.dev.clojure = {
    enable = mkEnableOption "clojure stuff";

    clojureFormatting = {
      enable = mkEnableOption "configurable Clojure code formatting";
      formatter = mkOption {
        type = types.enum [
          "cljstyle"
          "zprint"
          "cljfmt"
        ];
        default = "cljstyle";
        description = "Which Clojure formatter to use";
      };
    };

    enableKaocha = mkEnableOption "kaocha modern test runner";

    globalDepsEdn = {
      enable = mkEnableOption "manage global ~/.clojure/deps.edn file";

      aliases = mkOption {
        type = types.attrsOf types.attrs;
        default = {
          nrepl = {
            extra-deps = {
              "nrepl/nrepl" = {
                "mvn/version" = "1.3.0";
              };
            };
          };
          "repl/rebel" = {
            extra-deps = {
              "com.bhauman/rebel-readline" = {
                "mvn/version" = "0.1.4";
              };
            };
            main-opts = [
              "-m"
              "rebel-readline.main"
            ];
          };
          "repl/reveal" = {
            extra-deps = {
              "vlaaad/reveal" = {
                "mvn/version" = "1.3.282";
              };
            };
            main-opts = [
              "-m"
              "vlaaad.reveal"
              "repl"
            ];
          };
          new = {
            extra-deps = {
              "io.github.seancorfield/deps-new" = {
                "git/tag" = "v0.7.0";
                "git/sha" = "27bfffd";
              };
            };
            exec-fn = "org.corfield.new/create";
            exec-args = {
              template = "app";
            };
          };
          outdated = {
            deps = {
              "com.github.liquidz/antq" = {
                "mvn/version" = "2.8.1185";
              };
            };
            replace-deps = true;
            main-opts = [
              "-m"
              "antq.core"
            ];
          };
          find-deps = {
            extra-deps = {
              "find-deps/find-deps" = {
                "git/url" = "https://github.com/hagmonk/find-deps";
                "git/sha" = "9bf23a52cb0a8190c9c2c7ad1d796da802f8ce7a";
              };
            };
            main-opts = [
              "-m"
              "find-deps.core"
            ];
          };
        };
        description = "Global Clojure aliases to include in ~/.clojure/deps.edn";
      };
    };
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
      neovim = {
        plugins = with pkgs.vimPlugins; [
          # https://github.com/Olical/aniseed
          { plugin = aniseed; }

          # https://github.com/clojure-vim/vim-jack-in
          { plugin = vim-jack-in; }

          # cmp completion for conjure
          { plugin = cmp-conjure; }

          # https://github.com/radenling/vim-dispatch-neovim
          # this is needed for vim-jackin
          { plugin = vim-dispatch; }
          { plugin = vim-dispatch-neovim; }

          # https://github.com/tpope/vim-sexp-mappings-for-regular-people
          # tpope to the rescue again
          {
            plugin = vim-sexp-mappings-for-regular-people;
            config = "";
          }

          # https://github.com/PaterJason/nvim-treesitter-sexp
          #{ plugin = nvim-treesitter-sexp; } # TODO: fix. build started to fail
        ];
      };
    };

    # Environment variables for smart-lint.sh integration
    home.sessionVariables = mkIf cfg.clojureFormatting.enable {
      CLAUDE_CLOJURE_FORMATTING = "true";
      CLAUDE_CLOJURE_FORMATTER = cfg.clojureFormatting.formatter;
    };

    # Manage global deps.edn file
    home.file.".clojure/deps.edn" = mkIf cfg.globalDepsEdn.enable {
      text = formatEdn cfg.globalDepsEdn.aliases;
    };
  };
}

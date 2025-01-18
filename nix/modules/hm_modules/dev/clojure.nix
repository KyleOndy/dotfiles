{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.clojure;
in
{
  options.hmFoundry.dev.clojure = {
    enable = mkEnableOption "clojure stuff";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # https://github.com/babashka/babashka
      babashka

      # https://github.com/clj-kondo/clj-kondo
      clj-kondo # linter

      # https://clojure.org/
      clojure # core language

      # https://github.com/candid82/joker
      joker #  small Clojure interpreter, linter and formatter

      # https://github.com/technomancy/leiningen
      leiningen # build tooling

      # https://github.com/clojure-lsp/clojure-lsp
      clojure-lsp

      # https://github.com/babashka/neil#nix
      neil # A CLI to add common aliases and features to deps.edn-based projects.

      zprint

    ];

    programs = {
      java = {
        enable = true;
      };
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
            config = ''
            '';
          }

          # https://github.com/eraserhd/parinfer-rust
          # A Rust port of parinfer
          #{
          #  plugin = parinfer-rust;
          #  # TODO: add a toggle for parinfer
          #  #type = "lua";
          #  #config = ''
          #  #  require("which-key").add({
          #  #    { "<leader>tp", "<cmd>g:parinfer_enabled \
          #  #    ? \":ParinferOff<cr>\" \
          #  #    : \":ParinferOn<cr>\"" }
          #  #  })
          #  #'';
          #}

          # https://github.com/PaterJason/nvim-treesitter-sexp
          #{ plugin = nvim-treesitter-sexp; } # TODO: fix
        ];
      };
    };
  };
}

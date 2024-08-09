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

    ];

    programs = {
      java = {
        enable = true;
      };
      neovim = {
        plugins = with pkgs.vimPlugins; [
          # https://github.com/Olical/aniseed
          { plugin = aniseed; }

          # https://github.com/Olical/conjure
          # "conversational software development"
          {
            plugin = conjure;
            type = "vim";
            config = ''
              let g:conjure#mapping#doc_word = "K"

              -- Width of HUD as percentage of the editor width between 0.0 and 1.0. Default: `0.42`
              let g:conjure#log#hud#width = 1,

              -- Display HUD (REPL log). Default: `true`
              let g:conjure#log#hud#enabled = false,

              -- HUD corner position (over-ridden by HUD cursor detection). Default: `"NE"`
              -- Example: Set to `"SE"` and HUD width to `1.0` for full width HUD at bottom of screen
              let g:conjure#log#hud#anchor = "SE",

              -- Open log at bottom or far right of editor, using full width or height. Default: `false`
              let g:conjure#log#botright = true,

              -- Lines from top of file to check for `ns` form, to sett evaluation context Default: `24`
              -- `b:conjure#context` to override a specific buffer that isn't finding the context
              let g:conjure#extract#context_header_lines = 100,

              -- comment pattern for eval to comment command
              let g:conjure#eval#comment_prefix = ";; ",

              -- Hightlight evaluated forms
              let g:conjure#highlight#enabled = true,

              -- Start "auto-repl" process when nREPL connection not found, e.g. babashka. ;; Default: `true`
              let g:conjure#client#clojure#nrepl#connection#auto_repl#enabled = false,

              -- Hide auto-repl buffer when triggered. Default: `false`
              let g:conjure#client#clojure#nrepl#connection#auto_repl#hidden = true,

              -- Command to start the auto-repl. Default: `"bb nrepl-server localhost:8794"`
              let g:conjure#client#clojure#nrepl#connection#auto_repl#cmd = nil,

              -- Ensure namespace required after REPL connection. Default: `true`
              let g:conjure#client#clojure#nrepl#eval#auto_require = false,

              -- suppress `; (out)` prefix in log evaluation results
              let g:conjure#client#clojure#nrepl#eval#raw_out = true,

              -- test runner "clojure" (clojure.test) "clojurescript" (cljs.test) "kaocha"
              let g:conjure#client#clojure#nrepl#test#runner = "clojure",
            '';
          }

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
          {
            plugin = parinfer-rust;
            # TODO: add a toggle for parinfer
            #type = "lua";
            #config = ''
            #  require("which-key").add({
            #    { "<leader>tp", "<cmd>g:parinfer_enabled \
            #    ? \":ParinferOff<cr>\" \
            #    : \":ParinferOn<cr>\"" }
            #  })
            #'';
          }

          # https://github.com/PaterJason/nvim-treesitter-sexp
          { plugin = nvim-treesitter-sexp; }
        ];
      };
    };
  };
}

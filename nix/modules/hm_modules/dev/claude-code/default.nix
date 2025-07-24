# Claude Code Home Manager Module
# Provides intelligent Claude Code configuration management for multi-language development

{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.hmFoundry.dev.claude-code;
in
{
  options.hmFoundry.dev.claude-code = {
    enable = mkEnableOption "Claude Code configuration and intelligent hooks";

    enableHooks = mkOption {
      type = types.bool;
      default = true;
      description = "Enable intelligent post-tool-use and notification hooks";
    };
    enableCommands = mkOption {
      type = types.bool;
      default = true;
      description = "Enable slash commands";
    };

    enableNotifications = mkOption {
      type = types.bool;
      default = false;
      description = "Enable desktop notifications for Claude Code operations";
    };

    clojureFormatting = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Clojure code formatting in hooks";
      };

      formatter = mkOption {
        type = types.enum [ "cljstyle" "zprint" "cljfmt" ];
        default = "cljstyle";
        description = "Clojure formatter to use";
      };
    };

    projectMemory = mkOption {
      type = types.path;
      default = ./CLAUDE.md;
      description = "Path to the CLAUDE.md file containing development guidelines";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Claude Code and required tools are installed
    home.packages = with pkgs; [
      master.claude-code

      # Core tools used by smart-lint.sh and smart-test.sh
      gitAndTools.gitFull # for detecting modified files (matches git.nix module)

      # Python ecosystem
      ruff # python linting and formatting (use regular version to avoid conflicts)

      # Go ecosystem
      go # includes gofmt, go vet, go test

      # Clojure ecosystem
      clj-kondo # clojure linting
      babashka # fast clojure scripting

      # Nix ecosystem
      nixfmt-rfc-style # nix formatting

      # Shell ecosystem
      shellcheck # shell script linting
      shfmt # shell script formatting

      # Haskell ecosystem (if haskell module is enabled)

      # JavaScript/TypeScript ecosystem
      nodePackages.prettier # js/ts formatting

      # General development tools
      gnumake # for Makefile-based testing

    ] ++ optionals cfg.enableNotifications [
      libnotify # for notify-send desktop notifications
    ] ++ optionals cfg.clojureFormatting.enable (
      if cfg.clojureFormatting.formatter == "cljstyle" then [ cljstyle ]
      else if cfg.clojureFormatting.formatter == "zprint" then [ zprint ]
      else [ clojure-lsp ] # includes cljfmt
    );

    # Create .claude directory and configuration files
    home.file = (mkIf cfg.enableHooks {
      ".claude/hooks/smart-lint.sh" = {
        source = ./hooks/smart-lint.sh;
        executable = true;
      };
      ".claude/hooks/smart-test.sh" = {
        source = ./hooks/smart-test.sh;
        executable = true;
      };
      ".claude/hooks/ntfy-notifier.sh" = {
        source = ./hooks/ntfy-notifier.sh;
        executable = true;
      };
      ".claude/settings.json".source = ./settings.json;
      ".claude/CLAUDE.md".source = cfg.projectMemory;
    }) // (mkIf cfg.enableCommands {
      # we do not just symlink the entire commands dir, if we did we lose the
      # ability to drop arbitrary commands as we are testing them into that
      # dir.
      ".claude/commands/development/".source = ./commands/development;
      ".claude/commands/documentation/".source = ./commands/documentation;
      ".claude/commands/testing/".source = ./commands/testing;
    }) // {
      # Create necessary directory structure
      ".claude/.keep".text = "";
      ".claude/projects/.keep".text = "";
      ".claude/todos/.keep".text = "";
      ".claude/commands/.keep".text = "";
    };

    # Set environment variables for hook configuration
    home.sessionVariables = mkIf cfg.enableHooks {
      CLAUDE_CLOJURE_FORMATTING = if cfg.clojureFormatting.enable then "true" else "false";
      CLAUDE_CLOJURE_FORMATTER = cfg.clojureFormatting.formatter;
    };
  };
}

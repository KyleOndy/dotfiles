# Claude Code Home Manager Module
# Provides intelligent Claude Code configuration management for multi-language development

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.claude-code;
in
{
  options.hmFoundry.dev.claude-code = {
    enable = mkEnableOption "Claude Code configuration";

    enableHooks = mkOption {
      type = types.bool;
      default = true;
      description = "Enable notification hooks";
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

    projectMemory = mkOption {
      type = types.path;
      default = ./CLAUDE.md;
      description = "Path to the CLAUDE.md file containing development guidelines";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Claude Code and required tools are installed
    home.packages =
      with pkgs;
      [
        claude-code
        gitAndTools.gitFull # for git operations (matches git.nix module)
      ]
      ++ optionals cfg.enableNotifications [
        libnotify # for notify-send desktop notifications
      ];

    # Create .claude directory and configuration files
    home.file =
      # Hook files (conditional)
      (optionalAttrs cfg.enableHooks {
        ".claude/hooks/ntfy-notifier.sh" = {
          source = ./hooks/ntfy-notifier.sh;
          executable = true;
        };
        ".claude/hooks/enhanced-ntfy-notifier.sh" = {
          source = ./hooks/enhanced-ntfy-notifier.sh;
          executable = true;
        };
        ".claude/hooks/notification-bell.sh" = {
          source = ./hooks/notification-bell.sh;
          executable = true;
        };
        ".claude/assets/notification.wav" = {
          source = ./assets/notification.wav;
          executable = true;
        };
        ".claude/statusline.sh" = {
          source = ./statusline.sh;
          executable = true;
        };
        ".claude/settings.json".source = ./settings.json;
        ".claude/CLAUDE.md".source = cfg.projectMemory;
      })
      # Command files (conditional)
      // (optionalAttrs cfg.enableCommands {
        # we do not just symlink the entire commands dir, if we did we lose the
        # ability to drop arbitrary commands as we are testing them into that
        # dir.

        # Bare commands (root level)
        ".claude/commands/task.md".source = ./commands/task.md;

        # Category commands (subdirectories)
        ".claude/commands/code/".source = ./commands/code;
        ".claude/commands/docs/".source = ./commands/docs;
        ".claude/commands/git/".source = ./commands/git;
        ".claude/commands/project/".source = ./commands/project;
        ".claude/commands/task/".source = ./commands/task;
        ".claude/commands/test/".source = ./commands/test;
      })
      # Directory structure (always created)
      // {
        # Create necessary directory structure
        ".claude/.keep".text = "";
        ".claude/projects/.keep".text = "";
        ".claude/todos/.keep".text = "";
        ".claude/commands/.keep".text = "";
        ".claude/task-plans/.keep".text = "";
      };
  };
}

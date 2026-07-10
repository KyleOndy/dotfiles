# Claude Code Home Manager Module
# Provides intelligent Claude Code configuration management for multi-language development

{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.claude-code;

  # Package hook and statusline scripts with writeShellApplication so their
  # runtime dependencies (jq, ffplay, tmux, GNU date) come from the module's
  # closure instead of whatever happens to be on the ambient PATH. This also
  # runs shellcheck against every script at build time.
  mkScript =
    name: src: deps:
    getExe (
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = deps;
        # writeShellApplication provides its own shebang and set -euo pipefail
        text = removePrefix "#!/usr/bin/env bash\n" (builtins.readFile src);
      }
    );

  statusline = mkScript "claude-statusline" ./statusline.sh [
    pkgs.jq
    pkgs.git
    pkgs.coreutils # GNU date; BSD date on darwin lacks -d
  ];
  tmuxIndicator = mkScript "tmux-indicator" ./hooks/tmux-indicator.sh [
    pkgs.jq
    pkgs.tmux
  ];
  tmuxClaudeIcons = mkScript "tmux-claude-icons" ./hooks/tmux-claude-icons.sh [ pkgs.tmux ];
  notificationBell = mkScript "notification-bell" ./hooks/notification-bell.sh [
    pkgs.ffmpeg # ffplay
  ];
  # libnotify is intentionally not a runtime input: the script no-ops without
  # notify-send, and installing libnotify is what enableNotifications does.
  ntfyNotifier = mkScript "enhanced-ntfy-notifier" ./hooks/enhanced-ntfy-notifier.sh [
    pkgs.jq
    pkgs.git
  ];
in
{
  options.hmFoundry.dev.claude-code = {
    enable = mkEnableOption "Claude Code configuration";

    enableHooks = mkOption {
      type = types.bool;
      default = true;
      description = "Enable notification and tmux-indicator hooks";
    };
    enableCommands = mkOption {
      type = types.bool;
      default = true;
      description = "Enable slash commands";
    };

    enableSkills = mkOption {
      type = types.bool;
      default = true;
      description = "Enable skills";
    };

    skills = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Skill name (becomes ~/.claude/skills/<name>/ or ~/.claude/skills/<name>.md)";
            };
            source = mkOption {
              type = types.path;
              description = "Path to the skill directory or file";
            };
            isFile = mkOption {
              type = types.bool;
              default = false;
              description = "If true, source is a single .md file installed as ~/.claude/skills/<name>/SKILL.md";
            };
          };
        }
      );
      default = [ ];
      description = "Claude Code skills to install";
    };

    enableNotifications = mkOption {
      type = types.bool;
      default = false;
      description = "Install libnotify so the notifier hook can send desktop notifications (Linux only; the hook no-ops without notify-send)";
    };

    userMemory = mkOption {
      type = types.path;
      default = ./CLAUDE.md;
      description = "File installed as user-level memory at ~/.claude/CLAUDE.md";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Claude Code and required tools are installed
    home.packages =
      with pkgs;
      [
        claude-code
        gitFull # for git operations (matches git.nix module)
      ]
      ++ optionals cfg.enableNotifications [
        libnotify # for notify-send desktop notifications
      ];

    # settings.json is copied as a real writable file instead of the usual
    # nix-store symlink: Claude Code persists permission grants and /config
    # edits via atomic rename, which fails through a read-only store symlink
    # (anthropics/claude-code#15786), and the bubblewrap sandbox refuses to
    # start on one (#52525). The repo copy stays the source of truth; runtime
    # edits survive only until the next home-manager switch.
    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run install -D -m 0644 ${./settings.json} "$HOME/.claude/settings.json"
    '';

    home.file =
      # Core config: user memory, rules, and the statusline that settings.json
      # registers. Hooks are the only optional layer on top of these.
      {
        ".claude/CLAUDE.md".source = cfg.userMemory;
        ".claude/rules/clojure.md".source = ./rules/clojure.md;
        ".claude/statusline.sh".source = statusline;
      }
      # Hook scripts (conditional)
      // (optionalAttrs cfg.enableHooks {
        ".claude/hooks/enhanced-ntfy-notifier.sh".source = ntfyNotifier;
        ".claude/hooks/notification-bell.sh".source = notificationBell;
        ".claude/hooks/tmux-indicator.sh".source = tmuxIndicator;
        ".claude/hooks/tmux-claude-icons.sh".source = tmuxClaudeIcons;
        ".claude/assets/notification.wav".source = ./assets/notification.wav;
      })
      # Command files (conditional)
      // (optionalAttrs cfg.enableCommands {
        # recursive = true creates real directories with per-file symlinks, so
        # experimental commands can be dropped alongside the managed ones while
        # testing. All mkDefault so work-config can override freely.
        ".claude/commands/task.md" = lib.mkDefault { source = ./commands/task.md; };
        ".claude/commands/git" = lib.mkDefault {
          source = ./commands/git;
          recursive = true;
        };
        ".claude/commands/task" = lib.mkDefault {
          source = ./commands/task;
          recursive = true;
        };
      })
      # Skill files (conditional)
      // (optionalAttrs cfg.enableSkills (
        {
          ".claude/skills/commit-guidelines/SKILL.md".source = ./skills/commit-guidelines.md;
          ".claude/skills/flake-update-review/SKILL.md".source = ./skills/flake-update-review.md;
          ".claude/skills/grill-me/SKILL.md".source = ./skills/grill-me.md;
          ".claude/skills/personal-prose/SKILL.md".source = ./skills/personal-prose.md;
        }
        // listToAttrs (
          map (
            skill:
            if skill.isFile then
              nameValuePair ".claude/skills/${skill.name}/SKILL.md" { source = skill.source; }
            else
              nameValuePair ".claude/skills/${skill.name}/" { source = skill.source; }
          ) cfg.skills
        )
      ));
  };
}

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.shell.starship;
in
{
  options.hmFoundry.shell.starship = {
    enable = mkEnableOption "starship prompt";
  };

  config = mkIf cfg.enable {
    # Ensure our binary is in PATH
    home.packages = [ pkgs.git-worktree-prompt ];

    programs.starship = {
      enable = true;
      # Disable automatic Zsh integration - we'll init manually in zvm_after_init()
      # to ensure starship loads AFTER zsh-vi-mode finishes initialization
      enableZshIntegration = false;

      settings = {
        # Explicit two-line format preserving spaceship layout
        # Note: $username and $hostname are typically hidden on local machines
        # (they only show when SSH'd or when user != default)
        format = lib.concatStrings [
          "$username"
          "$hostname"
          "$time"
          "$directory"
          "\${custom.git-worktree}"
          "$git_state" # REBASING, MERGING, etc (starship built-in)
          "$nix_shell"
          "$aws"
          "$kubernetes"
          "$cmd_duration"
          "$line_break" # NEW LINE (explicit two-line prompt)
          "$jobs"
          "$battery"
          "$status"
          "$character"
        ];

        # Time module - matching spaceship format
        time = {
          disabled = false;
          format = "[$time]($style) ";
          time_format = "%H:%M";
        };

        # Directory with "in" prefix
        directory = {
          format = "in [$path]($style) ";
          truncation_length = 3;
          truncate_to_repo = true;
        };

        # Our custom git worktree module
        custom.git-worktree = {
          command = "git-worktree-prompt";
          when = true;
          # Parentheses make format conditional - won't render if $output is empty
          format = "(on [$output]($style) )";
          style = "bold purple";
          description = "Git worktree-aware branch display";
        };

        # Git state - use starship's built-in (REBASING, MERGING, etc.)
        # This is enabled by default, just configuring format
        git_state = {
          format = "([\\($state( $progress_current/$progress_total)\\)]($style) )";
          style = "bold yellow";
        };

        # Disable git modules our custom replaces
        git_branch.disabled = true;
        git_status.disabled = true;
        git_commit.disabled = true;

        # Lambda character on second line
        character = {
          success_symbol = "[λ](bold green)";
          error_symbol = "[λ](bold red)";
          vimcmd_symbol = "[λ](bold cyan)";
          vimcmd_visual_symbol = "[λ](bold yellow)";
        };

        # Show command duration for slow commands
        cmd_duration = {
          min_time = 500;
          format = "took [$duration]($style) ";
        };

        # Additional useful modules enabled by default
        # Users can customize or disable via their config
      };
    };
  };
}

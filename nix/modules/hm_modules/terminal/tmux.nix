{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.tmux;
in
{
  options.hmFoundry.terminal.tmux = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      clock24 = true; # use 24 hour clock
      escapeTime = 0;
      terminal = "screen-256color";
      sensibleOnTop = false; # do not inject other configuration
      baseIndex = 1; # start window numbering at 1
      extraConfig = ''
        # start pane numbering at 1 (matches window base index)
        set -g pane-base-index 1

        # keep window numbers sequential when closing windows
        set -g renumber-windows on

        # do not allow tmux to rename windows
        set -g allow-rename off

        # set scrollback history to 10000 (10k)
        set -g history-limit 10000

        # reload tmux.conf using PREFIX r
        # todo: get this path from some source of truth
        bind r source-file ~/.config/tmux/tmux.conf \; display "Reloaded!"

        # Enable mouse mode (tmux 2.1 and above)
        set -g mouse on

        set-option -g focus-events on

        # ----------------------
        # Status Bar
        # -----------------------
        set-option -g status on                # turn the status bar on
        set -g status-interval 5               # set update frequencey (default 15 seconds)
        set -g status-justify centre           # center window list for clarity

        # visual notification of activity in other windows
        setw -g monitor-activity on
        set -g visual-activity on

        # better tmux/vim navigation with smart pane switching with awareness
        # of Vim splits.
        # See: https://github.com/christoomey/vim-tmux-navigator
        is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
            | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
        bind-key -n 'M-h' if-shell "$is_vim" 'send-keys M-h'  'select-pane -L'
        bind-key -n 'M-j' if-shell "$is_vim" 'send-keys M-j'  'select-pane -D'
        bind-key -n 'M-k' if-shell "$is_vim" 'send-keys M-k'  'select-pane -U'
        bind-key -n 'M-l' if-shell "$is_vim" 'send-keys M-l'  'select-pane -R'
        tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'
        if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
            "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\'  'select-pane -l'"
        if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
            "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\\\'  'select-pane -l'"

        bind-key -T copy-mode-vi 'M-h' select-pane -L
        bind-key -T copy-mode-vi 'M-j' select-pane -D
        bind-key -T copy-mode-vi 'M-k' select-pane -U
        bind-key -T copy-mode-vi 'M-l' select-pane -R
        bind-key -T copy-mode-vi 'M-\' select-pane -l

        # ----------------------
        # Window Navigation
        # ----------------------
        # prefix + 0-9 for window switching is built-in
        # prefix + n/p for next/previous is built-in
        bind-key Tab last-window

        # ----------------------
        # Window/Pane Reorganization
        # ----------------------
        # move windows left/right (no default for this)
        bind-key < swap-window -t -1 \; select-window -t -1
        bind-key > swap-window -t +1 \; select-window -t +1

        # resize panes with prefix + arrow (repeatable)
        bind-key -r Left resize-pane -L 5
        bind-key -r Down resize-pane -D 5
        bind-key -r Up resize-pane -U 5
        bind-key -r Right resize-pane -R 5

        # open a new split or window in the current directory
        bind '"' split-window -c "#{pane_current_path}"
        bind % split-window -h -c "#{pane_current_path}"
        bind c new-window -c "#{pane_current_path}"

        run ${pkgs.tmux-gruvbox}/gruvbox-tpm.tmux
        set -g @tmux-gruvbox 'dark256'

        # Make active pane border more visible
        set-option -g pane-active-border-style "fg=colour214,bg=default"
        set-option -g pane-border-style "fg=colour237,bg=default"
        set-option -g pane-border-indicators both
        set-option -g pane-border-lines heavy

        # Dim inactive panes to highlight the active one
        set -g window-style 'bg=colour236'
        set -g window-active-style 'bg=colour235'

        # Copy-mode selection/cursor style (orange to match theme)
        set-option -g mode-style "bg=colour214,fg=colour235,bold"

        ## Theme settings mixed with colors (unfortunately, but there is no cleaner way)
        set-option -g status-justify "left"
        set-option -g status-left-style none
        set-option -g status-left-length "80"
        set-option -g status-right-style none
        set-option -g status-right-length "120"
        set-window-option -g window-status-separator ""

        # ----------------------
        # status bar
        # -----------------------

        # (name of session) (window index):(pane index)
        set-option -g status-left "#[fg=colour248, bg=colour241] #S #I:#P #[fg=colour241, bg=colour237, nobold, noitalics, nounderscore]"

        # left most solid arrow
        set-option -g status-right  "#[fg=colour239, bg=colour237, nobold, nounderscore, noitalics]"
        ${optionalString pkgs.stdenv.isLinux ''
          # battery power draw (Linux only)
          set-option -ga status-right "#[fg=colour246,bg=colour239] #(${pkgs.battery-draw}/bin/battery-draw) "
        ''}
        # system load.
        #   This has been tested on debian, OSX, and darwin, and seems to work
        #   across all systems
        #   - the uptime command on darwin has an extra field with a ':'
        #     character, so reverse the string under the assumption that the
        #     load is the last part of the output.
        #   - the xargs is to strip a leading whitespace
        set-option -ga status-right "[ #(uptime | rev | cut -d':' -f1 | rev | xargs | sed -e 's/,//g') ]"
        # local time
        set-option -ga status-right "#[fg=colour246,bg=colour239] %a %Y-%m-%d  %H:%M%Z/#(TZ="UTC" date +'%%H:%%M%%Z') (#(date +'%z'))"
        set-option -ga status-right " #[fg=colour248, bg=colour239, nobold, noitalics, nounderscore]"
        # host name
        set-option -ga status-right "#[fg=colour237, bg=colour248] #h "



        set-window-option -g window-status-current-format "#[fg=colour237, bg=colour214, nobold, noitalics, nounderscore]#[fg=colour239, bg=colour214] #I #[fg=colour239, bg=colour214, bold] #W #[fg=colour214, bg=colour237, nobold, noitalics, nounderscore]"
        set-window-option -g window-status-format "#[fg=colour237,bg=colour239,noitalics]#[fg=colour223,bg=colour239] #I #[fg=colour223, bg=colour239] #W #[fg=colour239, bg=colour237, noitalics]"

        # ----------------------
        # tmux-fzf
        # -----------------------

        # make it way easier to get to this functionality
        TMUX_FZF_LAUNCH_KEY="j"
      '';
      keyMode = "vi";
      shortcut = "space"; # <ctrl> + <space> for leader
      plugins = with pkgs; [
        { plugin = tmuxPlugins.fzf-tmux-url; }
        { plugin = tmuxPlugins.tmux-fzf; }
      ];
    };
  };
}

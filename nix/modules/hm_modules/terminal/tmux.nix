{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.terminal.tmux;
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
      extraConfig = ''
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

        # open a new split or window in the current directory
        bind '"' split-window -c "#{pane_current_path}"
        bind % split-window -h -c "#{pane_current_path}"
        bind c new-window -c "#{pane_current_path}"

        # ----------------------
        # gruvbox colors
        # -----------------------
        # There is a gruvbox tmux plugin [1] but it mingles the formatting and
        # content of the status bars. I intend to try and fix this, but am
        # putting things inline for now.
        #
        # [1] https://github.com/egel/tmux-gruvbox
        #

        ## COLORSCHEME: gruvbox dark
        set-option -g status "on"

        # default statusbar color
        set-option -g status-style bg=colour237,fg=colour223 # bg=bg1, fg=fg1

        # default window title colors
        set-window-option -g window-status-style bg=colour214,fg=colour237 # bg=yellow, fg=bg1

        # default window with an activity alert
        set-window-option -g window-status-activity-style bg=colour237,fg=colour248 # bg=bg1, fg=fg3

        # active window title colors
        set-window-option -g window-status-current-style bg=red,fg=colour237 # fg=bg1

        # active window background. Make it _just a bit_ lighter
        set-window-option -g window-active-style bg=colour237

        # pane border
        set-option -g pane-active-border-style fg=colour250 #fg2
        set-option -g pane-border-style fg=colour237 #bg1

        # message infos
        set-option -g message-style bg=colour239,fg=colour223 # bg=bg2, fg=fg1

        # writing commands inactive
        set-option -g message-command-style bg=colour239,fg=colour223 # bg=fg3, fg=bg1

        # pane number display
        set-option -g display-panes-active-colour colour250 #fg2
        set-option -g display-panes-colour colour237 #bg1

        # clock
        set-window-option -g clock-mode-colour colour109 #blue

        # bell
        set-window-option -g window-status-bell-style bg=colour167,fg=colour235 # bg=red, fg=bg

        ## Theme settings mixed with colors (unfortunately, but there is no cleaner way)
        set-option -g status-justify "left"
        set-option -g status-left-style none
        set-option -g status-left-length "80"
        set-option -g status-right-style none
        set-option -g status-right-length "80"
        set-window-option -g window-status-separator ""

        # ----------------------
        # status bar
        # -----------------------

        # (name of session) (window index):(pane index)
        set-option -g status-left "#[fg=colour248, bg=colour241] #S #I:#P #[fg=colour241, bg=colour237, nobold, noitalics, nounderscore]"

        # left most solid arrow
        set-option -g status-right  "#[fg=colour239, bg=colour237, nobold, nounderscore, noitalics]"
        # volume
        set-option -ga status-right "#[fg=colour246,bg=colour239] v:#(amixer sget Master | awk -F"[][]" '/Left:/ { print $2 }')  "

        # system load.
        #   This has been tested on debian, OSX, and darwin, and seems to work
        #   across all systems
        #   - the uptime command on darwin has an extra field with a ':'
        #     character, so reverse the string under the assumption that the
        #     load is the last part of the output.
        #   - the xargs is to strip a leading whitespace
        set-option -ga status-right "[ #(uptime | rev | cut -d':' -f1 | rev | xargs | sed -e 's/,//g') ]"
        # local time
        set-option -ga status-right "#[fg=colour246,bg=colour239] %a %Y-%m-%d  %H:%M%Z/#(TZ="UTC" date +'%%H:%%M%%Z')"
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

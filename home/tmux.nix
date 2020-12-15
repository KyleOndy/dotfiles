{ pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    clock24 = true; # use 24 hour clock
    escapeTime = 0;
    terminal = "tmux-256color";
    sensibleOnTop = false; # do not inject other configuration
    extraConfig = ''
      # do not allow tmux to rename windows
      set -g allow-rename off

      # set scrollback history to 10000 (10k)
      set -g history-limit 10000

      # reload ~/.tmux.conf using PREFIX r
      bind r source-file ~/.tmux.conf \; display "Reloaded!"

      # Enable mouse mode (tmux 2.1 and above)
      set -g mouse on

      # ----------------------
      # Status Bar
      # -----------------------
      set-option -g status on                # turn the status bar on
      set -g status-interval 5               # set update frequencey (default 15 seconds)
      set -g status-justify centre           # center window list for clarity

      # visual notification of activity in other windows
      setw -g monitor-activity on
      set -g visual-activity on

      # better tmux/vim navigation
      bind -n M-h run "(tmux display-message -p '#{pane_current_command}' | grep -iq vim && tmux send-keys M-h) || tmux select-pane -L"
      bind -n M-j run "(tmux display-message -p '#{pane_current_command}' | grep -iq vim && tmux send-keys M-j) || tmux select-pane -D"
      bind -n M-k run "(tmux display-message -p '#{pane_current_command}' | grep -iq vim && tmux send-keys M-k) || tmux select-pane -U"
      bind -n M-l run "(tmux display-message -p '#{pane_current_command}' | grep -iq vim && tmux send-keys M-l) || tmux select-pane -R"

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
      # system load
      set-option -ga status-right "[ #(cat /proc/loadavg | awk '{ print $1, $2, $3}') ]"
      # local time
      set-option -ga status-right "#[fg=colour246,bg=colour239] %Y-%m-%d  %H:%M"
      set-option -ga status-right " #[fg=colour248, bg=colour239, nobold, noitalics, nounderscore]"
      # host name
      set-option -ga status-right "#[fg=colour237, bg=colour248] #h "



      set-window-option -g window-status-current-format "#[fg=colour237, bg=colour214, nobold, noitalics, nounderscore]#[fg=colour239, bg=colour214] #I #[fg=colour239, bg=colour214, bold] #W #[fg=colour214, bg=colour237, nobold, noitalics, nounderscore]"
      set-window-option -g window-status-format "#[fg=colour237,bg=colour239,noitalics]#[fg=colour223,bg=colour239] #I #[fg=colour223, bg=colour239] #W #[fg=colour239, bg=colour237, noitalics]"
    '';
    keyMode = "vi";
    shortcut = "space"; # <ctrl> + <space> for leader
    plugins = with pkgs; [
      { plugin = tmuxPlugins.fzf-tmux-url; }
    ];
  };
}

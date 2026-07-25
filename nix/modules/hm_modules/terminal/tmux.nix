{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.tmux;
  # Powerline glyph characters (U+E0B0 solid arrow, U+E0B1 thin separator)
  arrow = builtins.fromJSON ''"\ue0b0"'';
  sep = builtins.fromJSON ''"\ue0b1"'';
  # Aggregate per-pane Claude icons via external script. Only wired in when
  # the claude-code module actually installs the script; otherwise every
  # status refresh would spawn a shell that fails on a missing path.
  claudeCfg = config.hmFoundry.dev.claude-code;
  claudeIconSuffix = optionalString (
    claudeCfg.enable && claudeCfg.enableHooks
  ) "#(~/.claude/hooks/tmux-claude-icons.sh '#{window_id}')";
  mkTabFmt =
    { bg, fg }:
    "#[fg=colour237]#[bg=${bg}]#[noitalics]${arrow}#[fg=${fg}]#[bg=${bg}] #I ${sep}#[fg=${fg}]#[bg=${bg}] #W${claudeIconSuffix} #[fg=${bg}]#[bg=colour237]#[noitalics]${arrow}";
  mkCurrentTabFmt =
    { bg, fg }:
    "#[fg=colour237]#[bg=${bg}]#[nobold]#[noitalics]#[nounderscore]${arrow}#[fg=${fg}]#[bg=${bg}] #I ${sep}#[fg=${fg}]#[bg=${bg}]#[bold] #W${claudeIconSuffix} #[fg=${bg}]#[bg=colour237]#[nobold]#[noitalics]#[nounderscore]${arrow}";
  windowFmt = mkTabFmt {
    bg = "colour239";
    fg = "colour223";
  };
  currentWindowFmt = mkCurrentTabFmt {
    bg = "colour214";
    fg = "colour239";
  };
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

        # allow programs to emit terminal-specific escape sequences through tmux
        set -g allow-passthrough on

        # forward CSI-u modified-key sequences (Shift+Enter etc.) to inner TUIs
        # alacritty 0.14+ supports the kitty keyboard protocol and emits CSI-u
        # pi (and most modern TUIs) parse csi-u, not the tmux-default xterm format
        set -g extended-keys on
        set -g extended-keys-format csi-u
        set -as terminal-features 'alacritty*:extkeys'

        # Advertise truecolor so 24-bit color (e.g. the Claude Code statusline)
        # passes through tmux unmodified and renders identically on every
        # machine, rather than being downsampled to each terminal's 256-color
        # approximation.
        set -as terminal-features 'alacritty*:RGB'
        set -as terminal-features 'foot*:RGB'

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

        # left most solid arrow, then the single pad space before the metrics.
        #   The pad lives here rather than on the battery segment because any
        #   metric can collapse to nothing. Owned by the first segment it
        #   would vanish with it and leave the row flush against the arrow.
        set-option -g status-right  "#[fg=colour239, bg=colour237, nobold, nounderscore, noitalics]#[fg=colour246,bg=colour239] "
        # battery charge and power draw.
        #   Each metric below emits its own trailing thin separator, so the
        #   spacing between segments belongs to them and is not set here.
        #   That is what lets one disappear without orphaning a divider.
        #   Colours by charge only while discharging: plugging in at 15% is
        #   the fix, so a warning colour that outlives it only trains you to
        #   ignore it. Collapses on AC above 95% the way system-gpu hides
        #   when idle, rather than spending 12 columns to say "docked".
        set-option -ga status-right "#[fg=colour246,bg=colour239]#(${pkgs.battery-draw}/bin/battery-draw)"
        # hottest cpu/gpu die sensor.
        #   Emits its own #[fg=] so it can go orange past 80C and red past 95C,
        #   then restores colour246 for the segments that follow. Prints
        #   nothing and exits 1 where no sensor is readable (WSL, VMs), which
        #   collapses the segment rather than showing an error.
        set-option -ga status-right "#[fg=colour246,bg=colour239]#(${pkgs.system-temp}/bin/system-temp)"
        # memory headroom, plus swap in use once it is past incidental.
        #   Headroom rather than a used percentage: both kernels keep RAM full
        #   of reclaimable cache on purpose, so "percent used" idles high on a
        #   healthy machine. Same collapse-on-failure contract as system-temp.
        set-option -ga status-right "#[fg=colour246,bg=colour239]#(${pkgs.system-mem}/bin/system-mem)"
        # gpu utilization, hidden while the gpu is idle.
        #   Answers whether the model server is working or wedged. Prints
        #   nothing below 5%, so the segment is only here when it has
        #   something to say.
        set-option -ga status-right "#[fg=colour246,bg=colour239]#(${pkgs.system-gpu}/bin/system-gpu)"
        # one minute load average.
        #   Was uptime piped through rev/cut/rev/xargs/sed, six processes on
        #   every refresh, to paper over uptime's output differing on darwin.
        #   getloadavg(3) is on both, so that is one process and no parsing.
        #   Shows the 1 minute figure only; the 5 and 15 minute values cost ten
        #   columns on a bar that is nearly full. Colours by load per core, so
        #   the same number reads correctly on trex and on a two core VM.
        set-option -ga status-right "#[fg=colour246,bg=colour239]#(${pkgs.system-load}/bin/system-load)"
        # local time.
        #   The UTC half still needs a subshell, as tmux cannot run strftime
        #   against another zone, but the offset does not: tmux expands
        #   status-right through strftime itself, so a bare %z drops one
        #   process from every five second refresh.
        set-option -ga status-right "#[fg=colour246,bg=colour239] %a %Y-%m-%d  %H:%M%Z/#(TZ="UTC" date +'%%H:%%M%%Z') (%z)"
        set-option -ga status-right " #[fg=colour248, bg=colour239, nobold, noitalics, nounderscore]"
        # host name
        set-option -ga status-right "#[fg=colour237, bg=colour248] #h "



        set-window-option -g window-status-current-format "${currentWindowFmt}"
        set-window-option -g window-status-format "${windowFmt}"

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

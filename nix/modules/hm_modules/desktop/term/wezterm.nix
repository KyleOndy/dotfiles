{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.term.wezterm;
in
{
  options.hmFoundry.desktop.term.wezterm = {
    enable = mkEnableOption "wezterm";
    descrption = "
    WezTerm is a powerful cross-platform terminal emulator and multiplexer written by @wez and implemented in Rust

    https://wezfurlong.org/wezterm/index.html
    ";
  };

  config = mkIf cfg.enable {
    programs.wezterm = {
      enable = true;
      extraConfig = ''
        local wezterm = require 'wezterm'
        local config = wezterm.config_builder()
        config.audible_bell = "Disabled"
        config.hide_tab_bar_if_only_one_tab = true
        config.front_end="WebGpu"

        return config
      '';
    };
  };
}

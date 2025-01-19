{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.desktop.term.alacritty;
in
{
  options.hmFoundry.desktop.term.alacritty = {
    enable = mkEnableOption "alacritty";
  };

  config = mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      settings = {
        font = {
          normal = {
            family = "Hack Nerd Font";
            style = "Regular";
          };
          bold = {
            family = "Hack Nerd Font";
            style = "Bold";
          };
          italic = {
            family = "Hack Nerd Font";
            style = "Italic";
          };
          bold_italic = {
            family = "Hack Nerd Font";
            style = "Bold Italic";
          };
          size = 13;
        };
        colors = {
          # Colors (Gruvbox dark)
          # https://github.com/alacritty/alacritty/wiki/Color-schemes
          primary = {
            # hard contrast background - "#1d2021";
            background = "#282828";
            # soft contrast background - "#32302f";
            foreground = "#ebdbb2";
            bright_foreground = "#fbf1c7";
            dim_foreground = "#a89984";
          };
          cursor = {
            text = "CellBackground";
            cursor = "CellForeground";
            vi_mode_cursor = {
              text = "CellBackground";
              cursor = "CellForeground";
              # search =
              #   matches =
              #     foreground =  "#000000";
              #     background =  "#ffffff";
              #   focused_match =
              #    foreground =  CellBackground
              #    background =  CellForeground
              #   bar =
              #     background =  "";
              #     foreground =  "";
              # line_indicator =
              #   foreground =  None
              #   background =  None
            };
            selection = {
              text = "CellBackground";
              background = "CellForeground";
            };
            bright = {
              black = "#928374";
              red = "#fb4934";
              green = "#b8bb26";
              yellow = "#fabd2f";
              blue = "#83a598";
              magenta = "#d3869b";
              cyan = "#8ec07c";
              white = "#ebdbb2";
            };
            normal = {
              black = "#282828";
              red = "#cc241d";
              green = "#98971a";
              yellow = "#d79921";
              blue = "#458588";
              magenta = "#b16286";
              cyan = "#689d6a";
              white = "#a89984";
            };
            dim = {
              black = "#32302f";
              red = "#9d0006";
              green = "#79740e";
              yellow = "#b57614";
              blue = "#076678";
              magenta = "#8f3f71";
              cyan = "#427b58";
              white = "#928374";
              # indexed_colors =  []
            };
          };
        };
      };
    };
  };
}

{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.term.alacritty;
in
{
  options.hmFoundry.desktop.term.alacritty = {
    enable = mkEnableOption "alacritty";
  };

  config = mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      settings = {
        window = {
          option_as_alt = "OnlyLeft"; # Left Option = Meta, right Option = normal (matches iTerm2)
          decorations = "Buttonless"; # Remove window buttons but keep draggable title bar
        };
        font = {
          # berkeley-mono-nerd-font (nix/pkgs/berkeley-mono-nerd-font) patches
          # in the glyphs nvim-web-devicons and friends render; plain
          # Berkeley Mono has none of them, so file/git icons fall back to
          # tofu boxes. The patcher files the obliques under a legacy family
          # suffixed "Obl" in nameID 1/2, which is what otfinfo prints, but
          # CoreText matches on the preferred names (nameID 16/17), where all
          # four faces share one family and the slanted styles are "Oblique"
          # and "Bold Oblique".
          normal = {
            family = "Berkeley Mono Nerd Font Mono";
            style = "Regular";
          };
          bold = {
            family = "Berkeley Mono Nerd Font Mono";
            style = "Bold";
          };
          italic = {
            family = "Berkeley Mono Nerd Font Mono";
            style = "Oblique";
          };
          bold_italic = {
            family = "Berkeley Mono Nerd Font Mono";
            style = "Bold Oblique";
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
          };
          vi_mode_cursor = {
            text = "CellBackground";
            cursor = "CellForeground";
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
          };
        };
      };
    };
  };
}

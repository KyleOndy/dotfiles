{ pkgs, ... }:

{
  # System-wide emoji font for all users
  fonts.packages = with pkgs; [
    noto-fonts-color-emoji
  ];

  # Configure fontconfig fallback
  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      emoji = [ "Noto Color Emoji" ];
    };
  };
}

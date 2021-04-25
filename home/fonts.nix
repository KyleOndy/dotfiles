{ pkgs, ... }:

{
  home.packages = with pkgs; [
    #  hack-font
    (nerdfonts.override {
      fonts = [ "Hack" ];
    })
  ];
}

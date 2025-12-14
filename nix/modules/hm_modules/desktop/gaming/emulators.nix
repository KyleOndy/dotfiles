{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.gaming.emulators;
in
{
  options.hmFoundry.desktop.gaming.emulators = {
    enable = mkEnableOption "RetroArch emulator suite for retro gaming";
  };

  config = mkIf cfg.enable {
    home.packages = [
      (pkgs.retroarch.withCores (
        cores: with cores; [
          fceumm # NES
          snes9x # SNES
          genesis-plus-gx # Genesis/Mega Drive
          mgba # GBA/GBC
          mupen64plus # N64
          beetle-psx-hw # PS1 (hardware-accelerated)
          pcsx2 # PS2
          dolphin # GameCube/Wii
          mame # Arcade
          fbneo # Neo Geo/CPS1/CPS2
        ]
      ))
    ];

    # Create ROM directory structure
    home.file = {
      "Games/roms/nes/.keep".text = "";
      "Games/roms/snes/.keep".text = "";
      "Games/roms/genesis/.keep".text = "";
      "Games/roms/gba/.keep".text = "";
      "Games/roms/gbc/.keep".text = "";
      "Games/roms/n64/.keep".text = "";
      "Games/roms/psx/.keep".text = "";
      "Games/roms/ps2/.keep".text = "";
      "Games/roms/gamecube/.keep".text = "";
      "Games/roms/wii/.keep".text = "";
      "Games/roms/arcade/.keep".text = "";
    };
  };
}

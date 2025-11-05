{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.audioVideoDevices;
in
{
  options.systemFoundry.audioVideoDevices = {
    enable = mkEnableOption "professional audio and video device support (MOTU, Elgato, etc.)";
  };

  config = mkIf cfg.enable {
    # Ensure video group exists and user has access
    users.groups.video = { };

    # Add v4l2loopback kernel module for virtual camera support (optional but useful for Zoom)
    boot.extraModulePackages = with config.boot.kernelPackages; [ v4l2loopback ];
    boot.kernelModules = [ "v4l2loopback" ];

    # Configure v4l2loopback for better Zoom compatibility
    boot.extraModprobeConfig = ''
      # Create virtual camera devices with better names
      options v4l2loopback devices=1 video_nr=10 card_label="Virtual Camera" exclusive_caps=1
    '';

    # udev rules for professional audio/video devices
    services.udev.extraRules = ''
      # MOTU M4 USB Audio Interface
      # MOTU vendor ID: 07fd
      # Allow all users to access MOTU audio devices
      SUBSYSTEM=="usb", ATTRS{idVendor}=="07fd", MODE="0666", GROUP="audio"
      SUBSYSTEM=="sound", KERNEL=="controlC*", ATTRS{idVendor}=="07fd", MODE="0666", GROUP="audio"

      # Elgato Capture Cards
      # Elgato vendor ID: 0fd9
      # Allow all users to access Elgato video capture devices
      SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="video"
      SUBSYSTEM=="video4linux", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="video"

      # Generic USB audio class devices (fallback for other professional audio interfaces)
      SUBSYSTEM=="sound", KERNEL=="controlC*", MODE="0666", GROUP="audio"

      # Video capture devices (v4l2)
      SUBSYSTEM=="video4linux", MODE="0666", GROUP="video"
    '';

    # Install useful utilities for audio/video device management
    environment.systemPackages = with pkgs; [
      # Video utilities
      v4l-utils # Video4Linux utilities (v4l2-ctl for testing cameras)

      # Audio utilities
      alsa-utils # ALSA utilities (arecord, aplay for testing audio)
      pulseaudio # For pactl commands (works with PipeWire via compatibility layer)
    ];
  };
}

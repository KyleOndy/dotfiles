# wifi network configurations. Just include all configurations on all machines
# with wifi for now.
#
# todo: make psk's actually secret. pull from pass?
{ config, pkgs, ... }:

{
  # Enables wireless support via wpa_supplicant.
  networking.wireless = {
    enable = true;
    networks = {
      "The Ondy's" = {
        pskRaw =
          "a2db56e5a0efe7c2e8eaca97d4bc4d872234dda49862554e02ce74696d8306e3";
      };
      # note: how to connect to unproteced wifi, works with captive portal
      #"GuestNet" = { };
    };
  };
}

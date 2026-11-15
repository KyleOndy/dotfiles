# UxPlay makes the kiosk an AirPlay receiver: screen mirroring from an
# iPhone or Mac, and AirPlay audio through the amp. Upstream closes the
# video window on "Stop Mirroring", but under this Sway the waylandsink
# window stays up on the last frame, so cogsworth-kiosk-guard ends it:
# https://github.com/FDH2/UxPlay/blob/v1.73.6/README.md?plain=1#L1434-L1439
{ lib, pkgs, ... }:
let
  # -p n takes TCP and UDP n, n+1 and n+2. Without -p the ports are random
  # and the firewall drops them:
  # https://github.com/FDH2/UxPlay/blob/v1.73.6/README.md?plain=1#L1275-L1283
  port = 7000;
  ports = [
    {
      from = port;
      to = port + 2;
    }
  ];

  # Seconds any window but Chromium may cover the kiosk before UxPlay is
  # restarted, and how much longer before the kiosk is.
  coverLimit = 30 * 60;
  coverEscalate = 2 * 60;
in
{
  # Clients find receivers only over mDNS. openFirewall (default on) opens
  # UDP 5353.
  services.avahi = {
    enable = true;
    allowInterfaces = [ "wlan0" ];
    publish = {
      enable = true;
      userServices = true;
    };
  };

  networking.firewall = {
    allowedTCPPortRanges = ports;
    allowedUDPPortRanges = ports;
  };

  systemd.services.cogsworth-airplay = {
    description = "AirPlay receiver (UxPlay) on the kiosk display";
    wantedBy = [ "multi-user.target" ];
    after = [
      "cogsworth-kiosk.service"
      "avahi-daemon.service"
    ];
    partOf = [ "cogsworth-kiosk.service" ];

    # Draws into the kiosk's Sway session, so it shares its user and
    # runtime directory. Sway skips wayland-0 and takes wayland-1.
    environment = {
      XDG_RUNTIME_DIR = "/run/cogsworth-kiosk";
      WAYLAND_DISPLAY = "wayland-1";
      HOME = "/run/cogsworth-kiosk";
    };

    serviceConfig = {
      User = "cogsworth";
      Group = "cogsworth";
      # stdbuf: into a pipe UxPlay's stdout is block-buffered, so its
      # connection log reached the journal only when it exited.
      #
      # -s: the client sizes the stream by height, so the default 1080 sent
      # a portrait phone at about 498x1080 for this 1080x1920 panel:
      # https://github.com/FDH2/UxPlay/blob/v1.73.6/README.md?plain=1#L1249-L1257
      #
      # -nofreeze: closes the window 15s after a client drops off the
      # network rather than leaving its last frame up:
      # https://github.com/FDH2/UxPlay/blob/v1.73.6/README.md?plain=1#L1423-L1432
      #
      # No -fs: waylandsink's own fullscreen fails its first frame under
      # this Sway with "Window has no size set". The guard fullscreens it.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.coreutils}/bin/stdbuf -oL -eL"
        (lib.getExe pkgs.uxplay)
        "-n Cogsworth"
        "-nh"
        "-p ${toString port}"
        "-s 1080x1920"
        "-nofreeze"
        "-vs waylandsink"
        "-as alsasink"
      ];
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Window policy for the kiosk's Sway session, run on every window event,
  # every AirPlay client UxPlay logs as closed, and every 5s:
  #
  # - Any window but Chromium is fullscreened. Chromium holds fullscreen,
  #   so a new window maps hidden behind it.
  # - Once only Chromium is left, it is fullscreened again. Sway drops its
  #   fullscreen for the other window, and windowed it shows 87px of
  #   browser toolbar.
  # - A UxPlay window with no client connected restarts UxPlay, which is
  #   what closes it after "Stop Mirroring".
  # - A window that covers Chromium for coverLimit restarts UxPlay, and
  #   coverEscalate later the kiosk. The touchscreen cannot close it and
  #   the kiosk has no other way out.
  systemd.services.cogsworth-kiosk-guard = {
    description = "Keep the kiosk's calendar fullscreen around AirPlay windows";
    wantedBy = [ "multi-user.target" ];
    after = [ "cogsworth-kiosk.service" ];
    partOf = [ "cogsworth-kiosk.service" ];
    path = [
      pkgs.sway-unwrapped
      pkgs.jq
      pkgs.iproute2
    ];
    environment = {
      COVER_LIMIT_S = toString coverLimit;
      COVER_ESCALATE_S = toString coverEscalate;
    };
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      set -euo pipefail

      socks=(/run/cogsworth-kiosk/sway-ipc.*.sock)
      sock=''${socks[0]}
      [ -S "$sock" ]
      covered_since=0

      check() {
        local others other_id chromium_id uxplay clients now age
        read -r others other_id chromium_id uxplay < <(
          swaymsg -s "$sock" -t get_tree -r | jq -r '
            [.. | objects | select(.pid? != null)]
            | map(select(.app_id == "chromium-browser")) as $c
            | map(select(.app_id != "chromium-browser")) as $o
            | [ ($o | length),
                (if any($o[]; .fullscreen_mode == 1) then 0 else ($o[0].id // 0) end),
                (if any($c[]; .fullscreen_mode == 1) then 0 else ($c[0].id // 0) end),
                ($o | map(select(.app_id == "uxplay")) | length) ]
            | @tsv')

        if [ "$others" -eq 0 ]; then
          covered_since=0
          if [ "$chromium_id" -ne 0 ]; then
            swaymsg -s "$sock" "[con_id=$chromium_id] fullscreen enable" >/dev/null
          fi
          return
        fi

        if [ "$uxplay" -ne 0 ]; then
          clients=$(ss -Htn state established '( sport ge :${toString port} and sport le :${toString (port + 2)} )' | wc -l)
          if [ "$clients" -eq 0 ]; then
            echo "UxPlay window up with no AirPlay client, restarting cogsworth-airplay"
            systemctl restart cogsworth-airplay.service
            return
          fi
        fi

        if [ "$other_id" -ne 0 ]; then
          swaymsg -s "$sock" "[con_id=$other_id] fullscreen enable" >/dev/null
        fi

        now=$(date +%s)
        [ "$covered_since" -ne 0 ] || covered_since=$now
        age=$(( now - covered_since ))
        if [ "$age" -ge $(( COVER_LIMIT_S + COVER_ESCALATE_S )) ]; then
          echo "kiosk still covered after ''${age}s, restarting cogsworth-kiosk"
          systemctl --no-block restart cogsworth-kiosk.service
        elif [ "$age" -ge "$COVER_LIMIT_S" ]; then
          echo "kiosk covered for ''${age}s, restarting cogsworth-airplay"
          systemctl restart cogsworth-airplay.service
        fi
      }

      check
      # Woken by Sway's window events and by UxPlay logging a closed client,
      # which is how "Stop Mirroring" arrives, since its window stays up.
      # Once Sway is gone, swaymsg in check fails and set -e exits, so
      # systemd restarts this against the new socket. read returns above
      # 128 on its timeout and 1 at EOF.
      while true; do
        if read -r -t 5 _; then :; elif [ $? -le 128 ]; then exit 1; fi
        check
      done < <(
        swaymsg -s "$sock" -r -m -t subscribe '["window"]' &
        journalctl -f -n 0 -o cat -u cogsworth-airplay.service --grep '^Connection closed'
      )
    '';
  };
}

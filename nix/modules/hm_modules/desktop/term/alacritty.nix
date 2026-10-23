{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.term.alacritty;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # nixpkgs signs Alacritty.app ad hoc, so its designated requirement is its
  # cdhash and a TCC grant lasts until the next rebuild, while a switch run
  # from Alacritty needs Full Disk Access (../browsers/firefox.nix). Signed
  # with this self-signed identity, the requirement names the bundle id and
  # certificate, which rebuilds keep. The key lives only in the login keychain.
  signingIdentity = "hm-apps-codesign";

  codesignInit = pkgs.writeShellApplication {
    name = "hm-apps-codesign-init";
    runtimeInputs = [ pkgs.openssl ];
    text = ''
      # Usage: hm-apps-codesign-init
      # codesign takes the identity untrusted, and only TCC reads the result.
      if [[ $(/usr/bin/security find-identity -p codesigning) == *'"${signingIdentity}"'* ]]; then
        echo "hm-apps-codesign-init: ${signingIdentity} already exists" >&2
        exit 0
      fi
      d=$(mktemp -d)
      trap 'rm -rf "$d"' EXIT
      openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=${signingIdentity}" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" \
        -keyout "$d/key.pem" -out "$d/cert.pem" 2>/dev/null
      # security import rejects OpenSSL 3's default PKCS12 MAC ("MAC
      # verification failed"). The bundle stays in the 0700 temp dir, so its
      # password guards nothing.
      openssl pkcs12 -export -legacy -name ${signingIdentity} -inkey "$d/key.pem" -in "$d/cert.pem" -out "$d/id.p12" -passout pass:x
      keychain="$HOME/Library/Keychains/login.keychain-db"
      /usr/bin/security import "$d/id.p12" -k "$keychain" -P x -T /usr/bin/codesign
      # codesign reaches the key as partition apple:, which import leaves out,
      # so without this every switch shows a keychain prompt. It matches the
      # key by the -name label and asks for the login password on the terminal.
      /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -l ${signingIdentity} "$keychain" >/dev/null
      echo "hm-apps-codesign-init: switch to sign Alacritty.app, then quit Alacritty, re-add it under Full Disk Access and relaunch it" >&2
    '';
  };
in
{
  options.hmFoundry.desktop.term.alacritty = {
    enable = mkEnableOption "alacritty";
  };

  config = mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      settings = {
        # Interactive login zsh, so the tmux server inherits the environment
        # a shell prompt would have, zshrc exports included.
        terminal.shell = mkIf config.hmFoundry.terminal.tmux.enable {
          program = "zsh";
          args = [
            "-lic"
            "exec ${getExe config.programs.tmux.package} new-session -A -s scratch"
          ];
        };
        keyboard.bindings = [
          # Unbinds the default vi mode toggle: one Shift away from the tmux
          # prefix, and tmux copy-mode covers the same ground with full history.
          {
            key = "Space";
            mods = "Control|Shift";
            action = "ReceiveChar";
          }
          # The default is Quit, which closes the window without asking.
          {
            key = "W";
            mods = "Command";
            action = "None";
          }
        ]
        # tmux requests modified keys with modifyOtherKeys, which alacritty does
        # not implement. tmux forwards this CSI-u only to panes that asked for
        # extended keys and sends the rest a plain CR, so it is safe behind tmux.
        ++ optional config.hmFoundry.terminal.tmux.enable {
          key = "Enter";
          mods = "Shift";
          chars = builtins.fromJSON ''"\u001b[13;2u"'';
        };
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
          size = 14;
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

    home.packages = optional isDarwin codesignInit;

    # copyApps rsyncs the store's ad-hoc bundle back over the copy on every
    # switch, so this signs on every switch too.
    home.activation.codesignAlacritty = mkIf (isDarwin && config.targets.darwin.copyApps.enable) (
      lib.hm.dag.entryAfter [ "copyApps" ] ''
        app="$HOME/${config.targets.darwin.copyApps.directory}/Alacritty.app"
        if [[ $(/usr/bin/security find-identity -p codesigning) != *'"${signingIdentity}"'* ]]; then
          warnEcho "Alacritty.app stays ad-hoc signed, so its privacy grants break on every rebuild: run hm-apps-codesign-init once"
        elif ! run /usr/bin/codesign --force --sign ${signingIdentity} "$app"; then
          warnEcho "codesign could not sign Alacritty.app, so it stays ad-hoc signed until the next switch"
        fi
      ''
    );
  };
}

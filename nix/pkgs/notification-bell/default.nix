{ writeShellApplication, ffmpeg }:

writeShellApplication {
  name = "notification-bell";
  runtimeInputs = [
    ffmpeg # ffplay
  ];
  text = builtins.replaceStrings [ "@sound@" ] [ "${./notification.wav}" ] (
    builtins.readFile ./notification-bell.sh
  );
}

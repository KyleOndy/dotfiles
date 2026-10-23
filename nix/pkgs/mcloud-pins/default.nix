{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  gnugrep,
  jq,
  green-png,
  # A command printing the mcloud key from this host's secret store.
  # MCLOUD_API_KEY, or MCLOUD_API_KEY_COMMAND, overrides it for one run.
  keyCommand ? "",
}:

writeShellApplication {
  name = "mcloud-pins";
  runtimeInputs = [
    coreutils
    curl
    gnugrep
    jq
  ];
  text = ''
    GREEN_PNG=${green-png}
    [ -n "''${MCLOUD_API_KEY_COMMAND:-}" ] || MCLOUD_API_KEY_COMMAND=${lib.escapeShellArg keyCommand}
  ''
  + builtins.readFile ./mcloud-pins.sh;
}

{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  gawk,
  gnugrep,
  jq,
  green-png,
  # A command printing the mcloud key from this host's secret store.
  # MCLOUD_API_KEY, or MCLOUD_API_KEY_COMMAND, overrides it for one run.
  keyCommand ? "",
  # The same for the Artificial Analysis key, overridden by AA_API_KEY or
  # AA_API_KEY_COMMAND.
  aaKeyCommand ? "",
}:

writeShellApplication {
  name = "mcloud-rank";
  runtimeInputs = [
    coreutils
    curl
    gawk
    gnugrep
    jq
  ];
  text = ''
    GREEN_PNG=${green-png}
    [ -n "''${MCLOUD_API_KEY_COMMAND:-}" ] || MCLOUD_API_KEY_COMMAND=${lib.escapeShellArg keyCommand}
    [ -n "''${AA_API_KEY_COMMAND:-}" ] || AA_API_KEY_COMMAND=${lib.escapeShellArg aaKeyCommand}
  ''
  + builtins.readFile ./mcloud-rank.sh;
}

{
  writers,
  runCommand,
  llm-agents,
  # A command printing the mcloud key from this host's secret store.
  # MCLOUD_API_KEY, or MCLOUD_API_KEY_COMMAND, overrides it for one run.
  keyCommand ? "",
}:
let
  # Every model id compiled into the pi this flake installs. leak-guard treats
  # these names as public. The bundle is minified JS inside a Mach-O, so this
  # greps the model object literals; the floor catches a pi release that
  # changes their shape.
  piBuiltins = runCommand "pi-builtin-models" { } ''
    LC_ALL=C grep -aoE 'id: "[^"]+", name: "[^"]*", api: "' ${llm-agents.pi}/libexec/pi/pi \
      | sed -E 's/^id: "([^"]+)".*/\1/' | sort -u >"$out"
    n=$(wc -l <"$out")
    if [ "$n" -lt 500 ]; then
      echo "pi-builtin-models: only $n ids found in pi's bundle" >&2
      exit 1
    fi
  '';
in
writers.writePython3Bin "leak-guard"
  {
    flakeIgnore = [
      "E501"
      "W503"
    ];
  }
  (
    builtins.replaceStrings
      [ "@builtins@" ''"@keyCommand@"'' ]
      [ "${piBuiltins}" (builtins.toJSON keyCommand) ]
      (builtins.readFile ./leak-guard.py)
  )

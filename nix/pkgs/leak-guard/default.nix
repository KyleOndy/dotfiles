{
  writers,
  runCommand,
  llm-agents,
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
writers.writePython3Bin "leak-guard" {
  flakeIgnore = [
    "E501"
    "W503"
  ];
} (builtins.replaceStrings [ "@builtins@" ] [ "${piBuiltins}" ] (builtins.readFile ./leak-guard.py))

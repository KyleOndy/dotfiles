# Flake check for forge's lima instance definition (nix/pkgs/forge/vm.nix).
#
# The VM boundary is the only thing standing between a privileged container and
# the host, so the fields that define it are asserted here rather than trusted
# to survive an edit. `limactl validate` covers the schema; the rest covers the
# properties a schema cannot express.
{ pkgs }:

let
  vmConfig = pkgs.forge.vmConfig;
in
pkgs.runCommand "forge-vm-check"
  {
    nativeBuildInputs = [
      pkgs.master.lima
      pkgs.jq
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    export HOME=$TMPDIR/home
    export LIMA_HOME=$TMPDIR/lima
    mkdir -p "$HOME" "$LIMA_HOME"

    fail() { echo "FAIL: $*" >&2; exit 1; }

    limactl validate ${vmConfig} \
      || fail "limactl rejected the generated config"

    # JSON, not YAML, and not by preference: a YAML multi-line string emits as a
    # folded scalar whose newlines are blank lines, and lima's yq-based config
    # merge replaces those with a `#magic___^_^___line` sentinel, collapsing a
    # provision script to one unrunnable line. JSON has no folded scalars.
    jq -e . ${vmConfig} >/dev/null \
      || fail "config is not JSON, so a provision script can be folded and mangled"

    # No host path reaches any container in this VM.
    [ "$(jq -r '.mounts // [] | length' ${vmConfig})" = "0" ] \
      || fail "vm.nix declares mounts: $(jq -c '.mounts' ${vmConfig})"

    jq -e '.portForwards[] | select(.guestSocket == "/var/run/docker.sock")' ${vmConfig} >/dev/null \
      || fail "no docker socket forward, the VM would expose no daemon"

    # The guest is a store path built from nix/pkgs/forge/guest.nix, so docker's
    # version in it is the one nixpkgs locks. A remote location, or a `base`
    # distro template, would put that back in an archive fetched at first boot
    # and let the guest's package manager move it afterwards.
    jq -e '(.images | length) == 1
           and (.images[0].location | startswith("/nix/store/"))
           and (has("base") | not)' ${vmConfig} >/dev/null \
      || fail "guest image is not a single nix store path: $(jq -c '{base, images}' ${vmConfig})"

    # Asserted separately because `limactl validate` accepts a location that does
    # not exist, and so does the store-path test above: the image only has to be
    # a path, and getting its filename wrong would surface at VM creation.
    image=$(jq -r '.images[0].location' ${vmConfig})
    [ -f "$image" ] \
      || fail "guest image location is not a file: $image"

    # lima stops at the first matching rule and appends its own
    # forward-everything fallback after the last, so the tail must deny. It takes
    # a pair: guestIP selects one address family, 127.0.0.1 matching a loopback
    # bind and 0.0.0.0 a wildcard one, and a port bound on the family neither
    # names falls through to the fallback and reaches the host. proto defaults to
    # tcp, and a port field would stop the rule being the catch-all.
    jq -e '.portForwards[-2:]
           | (map(.ignore == true
                  and .proto == "any"
                  and (has("guestPortRange") or has("guestPort")) == false) | all)
             and (map(.guestIP) | sort) == ["0.0.0.0", "127.0.0.1"]' ${vmConfig} >/dev/null \
      || fail "the last two rules are not a deny-all pair: $(jq -c '.portForwards[-2:]' ${vmConfig})"

    # A forwarded range that disagrees with the one forge assigns from would give
    # every cluster past the overlap an unreachable API server, and the window
    # needs the same pairing as the deny: whichever family docker publishes the
    # port on has to match a rule before the deny catches it.
    base=$(grep -oE '^readonly API_PORT_BASE=[0-9]+' ${pkgs.forge}/bin/forge | cut -d= -f2)
    span=$(grep -oE '^readonly API_PORT_SPAN=[0-9]+' ${pkgs.forge}/bin/forge | cut -d= -f2)
    [ -n "$base" ] && [ -n "$span" ] \
      || fail "could not read the API port window out of the forge script"

    want="[$base,$((base + span - 1))]"
    jq -e --argjson want "$want" '
      [.portForwards[] | select(.guestPortRange)] as $w
      | ($w | length) == 2
        and (($w | map(.guestIP) | sort) == ["0.0.0.0", "127.0.0.1"])
        and (($w | map(.guestPortRange) | unique) == [$want])
        and (($w | map(.hostPortRange) | unique) == [$want])' ${vmConfig} >/dev/null \
      || fail "API window is not $want on both families: $(jq -c '[.portForwards[] | select(.guestPortRange)]' ${vmConfig})"

    # Everything above validates one config in the store. This is what ties it to
    # the script: forge creates its VM from the path baked into VM_CONFIG, so
    # without this the check could be passing a config forge never uses.
    grep -qxF "readonly VM_CONFIG=${vmConfig}" ${pkgs.forge}/bin/forge \
      || fail "forge creates its VM from $(grep -m1 '^readonly VM_CONFIG=' ${pkgs.forge}/bin/forge), not ${vmConfig}"

    echo "forge-vm-check: ok (api ports $want on both address families)" > $out
  ''

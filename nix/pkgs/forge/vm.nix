# Lima instance definition for forge's docker host.
#
# forge builds kind clusters, whose nodes run systemd and so need privileged
# containers. Anything reaching the docker socket can start one, and a
# privileged container can nsenter into the VM's init namespace, so nothing
# inside the daemon can be a boundary. The VM is the only wall, so the fields
# defining it are declared here rather than left to a tool's defaults: no
# mounts, and a portForwards list ending in a deny.
#
# Emitted as JSON, which lima reads because YAML 1.2 is a JSON superset. Nix's
# YAML writer renders a multi-line string as a folded scalar whose newlines are
# blank lines, and lima merges configs through vendored yq, which replaces those
# with its `#magic___^_^___line` sentinel and collapses the script to one line.
{
  formats,
  # A qcow2 built from nix/pkgs/forge/guest.nix, so docker's version in the guest
  # is the one nixpkgs locks. vz boots qcow2 directly, no conversion.
  guestImage,
  guestArch,
  # forge assigns one API port per cluster from this base (api_port_for in
  # forge.sh) and refuses a cluster past the span, whose port the deny rule drops.
  apiPortBase ? 6440,
  apiPortSpan ? 16,
  # Sized for the five kind nodes forge.yaml declares, not for the host.
  cpus ? 4,
  memory ? "8GiB",
  disk ? "60GiB",
}:

let
  json = formats.json { };
  apiPortLast = apiPortBase + apiPortSpan - 1;
in
json.generate "lima-forge.json" {
  minimumLimaVersion = "2.0.0";

  images = [
    {
      location = guestImage;
      arch = guestArch;
    }
  ];

  inherit cpus memory disk;
  vmType = "vz";

  # An empty list is no mounts in lima's schema. The nil-versus-empty ambiguity
  # that makes colima read `[]` as "mount $HOME writable" is colima's own.
  mounts = [ ];

  # lima uses its own key in $LIMA_HOME/_config, so this only drops a ~/.ssh read.
  ssh.loadDotSSHPubKeys = false;

  containerd = {
    system = false;
    user = false;
  };

  # lima checks these in order, stops at the first match, and appends its own
  # forward-everything fallback (proto any, ports 1-65535) after the last, so the
  # tail has to deny rather than merely omit. Every rule is paired because
  # `guestIP` selects one address family and there is no value covering both:
  # 127.0.0.1 matches a loopback bind (127.0.0.1, ::1) and 0.0.0.0 a wildcard one
  # (0.0.0.0, ::). Contrary to share/lima/templates/default.yaml:538-540, 0.0.0.0
  # does not match any bound interface (measured on lima 2.2.0). Unpaired, a port
  # bound on the family neither rule names falls through to the fallback and
  # reaches the host, and an API port bound on the family the window omits is
  # denied while kind's kubeconfig still points at it.
  portForwards = [
    {
      guestSocket = "/var/run/docker.sock";
      hostSocket = "{{.Dir}}/sock/docker.sock";
    }
    {
      # hostIP keeps its 127.0.0.1 default throughout, so the host side of the
      # window stays loopback-only whichever family the guest bound.
      guestIP = "127.0.0.1";
      guestPortRange = [
        apiPortBase
        apiPortLast
      ];
      hostPortRange = [
        apiPortBase
        apiPortLast
      ];
    }
    {
      guestIP = "0.0.0.0";
      guestPortRange = [
        apiPortBase
        apiPortLast
      ];
      hostPortRange = [
        apiPortBase
        apiPortLast
      ];
    }
    {
      guestIP = "127.0.0.1";
      proto = "any";
      ignore = true;
    }
    {
      guestIP = "0.0.0.0";
      proto = "any";
      ignore = true;
    }
  ];

  # Resolves inside containers, unlike an /etc/hosts entry in the guest.
  hostResolver.hosts."host.docker.internal" = "host.lima.internal";

  # `limactl start` returns once ssh answers, which is before dockerd is up, and
  # the first forge command would fail instead. lima retries a failing probe
  # rather than giving up, so a broken guest surfaces as a start that never
  # returns. The second check runs as the instance user, which is what makes it
  # a test of guest.nix's docker socket group and not just of dockerd.
  probes = [
    {
      script = ''
        #!/bin/bash
        set -eux -o pipefail
        if ! timeout 120s bash -c "until systemctl is-active --quiet docker.service; do sleep 3; done"; then
          echo >&2 "docker.service never became active"
          exit 1
        fi
        if ! timeout 60s bash -c "until docker info >/dev/null 2>&1; do sleep 3; done"; then
          echo >&2 "docker socket is not reachable as the instance user"
          exit 1
        fi
      '';
      hint = "Run `limactl shell forge -- systemctl status docker.service`";
    }
  ];
}

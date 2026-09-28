# { name = version; } for the packages a host installs, from evaluation
# alone, so a flake update can be diffed without building anything:
#
#   nix eval --impure --json .#nixosConfigurations.tiger \
#     --apply 'import ./nix/lib/package-versions.nix'
#
# Covers system and home-manager packages plus the service packages listed
# below. Services are named explicitly: walking every `services.*` option
# trips `abort` in renamed-option shims, which tryEval cannot catch.
sys:
let
  c = sys.config;
  isDrv = p: builtins.isAttrs p && (p.type or null) == "derivation";
  on = s: (s.enable or false) == true;
  s = c.services or { };
  svc = name: if on (s.${name} or { }) then s.${name}.package else null;

  home = builtins.concatLists (
    map (u: u.home.packages) (builtins.attrValues (c.home-manager.users or { }))
  );
  extra = [
    (svc "grafana")
    (svc "victoriametrics")
    (svc "loki")
    (svc "alloy")
    (svc "caddy")
    (svc "jellyfin")
    (svc "sabnzbd")
    (if on (s.prometheus.alertmanager or { }) then s.prometheus.alertmanager.package else null)
    (c.boot.kernelPackages.kernel or null)
    (c.boot.zfs.package or null)
    # pi is installed through a versionless sandbox wrapper named `pi`.
    (if builtins.any (p: (p.name or "") == "pi") home then sys.pkgs.llm-agents.pi or null else null)
  ];

  entry =
    p:
    let
      parsed = builtins.parseDrvName (p.name or "");
      name = p.pname or parsed.name;
      version = p.version or parsed.version;
    in
    if isDrv p && version != "" then
      [
        {
          inherit name;
          value = version;
        }
      ]
    else
      [ ];
in
builtins.listToAttrs (
  builtins.concatLists (
    map entry ((c.environment.systemPackages or [ ]) ++ home ++ builtins.filter isDrv extra)
  )
)

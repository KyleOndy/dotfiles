# Native Darwin builder

The broker calls `builder.build(config, admitted, command_args=None)` with a
trusted admission record from `workspace.admit_bundle`. `command_args` is an
argument array beginning with `nix` or `make`. It runs in the guest worktree;
`DOTFILES_WORKTREE` points there. No expression runs through the host daemon.

This backend requires provisioning and a live acceptance run on each target
Mac before use.

## Provisioning contract

`alamode-builder.tart` and `alamode-builder.softnet` expose pinned native packages.
Use Tart's executable inside `Applications/tart.app/Contents/MacOS/tart`;
its app bundle carries the provisioning profile required by macOS.

The Darwin module manages the privileged copy:

```nix
systemFoundry.alamodeBuilder.enable = true;
```

Both Darwin hosts enable it. Apply through `make deploy-mac` or
`make deploy-trex`. Root activation copies the pinned package atomically to
`/Library/PrivilegedHelperTools/alamode-builder/softnet`, owned by root:wheel with
mode `4755`. The Nix store copy stays unprivileged. Redeployment repairs the
copy; disabling the option and deploying removes it. Upgrades replace the
same path, and the builder's pinned hash must match the deployed version.

This is an explicit host privilege grant. Softnet changes host DHCP
preferences, creates its vmnet interface, then drops privilege. The runner
refuses an unprovisioned helper instead of invoking Tart's interactive SUID
setup. The module manages only the helper; guest provisioning and live
acceptance remain separate. See the [Darwin module](../../modules/darwin_modules/alamode-builder.nix).

Create a credential-free standalone macOS 26 guest with Tart Guest Agent,
Python 3.12 or later, Git, git-crypt, make, Nix with flakes enabled, and the
tools required by the workload. Set `sandbox = relaxed` in the guest's
`nix.conf`: the boundary probe and the acceptance fixture request a
`__sandboxProfile`, which Nix refuses under `sandbox = true`. The VM is the
boundary, so a derivation that loosens its own sandbox must still fail the
probe. The guest account needs passwordless sudo.
No Apple ID, SSH key, cloud profile, provider token, or host directory share
belongs in this image. Shut it down cleanly: `tart stop` sends SIGINT to the
runner and SIGKILLs the VM at its timeout, and a macOS guest killed mid-shutdown
can lose its last writes, including the profile generation that holds the
tools ([Stop.swift](https://github.com/cirruslabs/tart/blob/05edeac562bae804ea4f88592cfbc98cc6791b5d/Sources/tart/Commands/Stop.swift#L47-L68)).
Boot it once more and confirm `guest_python` and `nix` resolve, shut it down
the same way, then pin all three image file hashes. Image acquisition and
setup are separate human-authorized operations.

The trusted configuration contains:

- `tart`, `tart_sha256`, `softnet`, `softnet_sha256`: absolute executable
  paths and lowercase SHA256 hex digests. Reviewed versions are 2.40.1 and
  0.24.1.
- `tart_home`, `base_vm`, `image_sha256`: trusted Tart storage, a local VM
  name, and hashes keyed by `config.json`, `disk.img`, and `nvram.bin`.
- `guest_python`, `record_root`: the guest's Python executable and existing
  trusted host directory for retained build records.
- `cpu`, `memory_mib`, `timeout_seconds`: 2-16 CPUs, 4096-32768 MiB,
  30-14400 seconds.
- Optional `max_retained_vms`: 1-64, default 8. Optional `min_free_bytes`:
  1 GiB-1 TiB, default 10 GiB. Both record and VM storage must meet the floor.
- `allowed_cidrs`, `dns_servers`, optional `command_args`: explicit public
  IPv4 destinations, public DNS servers within those CIDRs, and guest args.
- Optional `materialized_inputs`: at most 32 grants, each with `source`,
  `target`, and `sha256`. `source` is a canonical absolute regular file;
  `target` is an existing protected repository path. Each file is bounded
  at 64 MiB, checked against its authorized hash, and frozen before transfer.

No `/0`, private, special, or host-connected network is accepted. Dependency
CDNs need explicit CIDRs; DNS does not expand authority. Softnet drops IPv6.
The runner blocks the vmnet gateway, disables clipboard, audio and USB, and
supplies no shared directories. Input travels over the guest-agent channel.

## Acceptance and retention

Run `alamode-check-builder --config /absolute/trusted-config.json`. It creates its
own Git fixture, checks the guest boundary, then compiles and executes C in a
fresh Nix source build with substitution disabled. JSON output names the
retained report. Exit 2 means a missing prerequisite; exit 1 means failure.

Every job clones the pinned base, checks host canary visibility and host TCP
access from guest root, then repeats host-file and network probes in a Nix
source derivation requesting a permissive `__sandboxProfile`. Only a passed
probe starts the requested workload. Test representative package builds and
fixed-output dependency fetches on both target Macs before enabling service.

The result records the commit, VM, record path, exit code and stop failures.
Workload streams remain separate in `stdout.log` and `stderr.log`, with a
combined 32 MiB limit. VM diagnostics have a separate 32 MiB limit.
Disks and logs remain for inspection. Source
bundles at 256 MiB. Host interface changes stop active jobs; another VM
starting can trigger this check. Detection is polled, so do not change host
network configuration during a job. A per-Tart-home file lock serializes jobs,
including direct acceptance checks. Admission refuses when retained
`build-<uuid>` VM directories reach the limit. Low free space stops boot or
workload collection. Review and remove retained VMs and records explicitly;
the runner never deletes them. Artifacts are not imported into the host Nix store.

Protected paths remain omitted unless individually granted as materialized
inputs. The guest receives only those file bytes, never source paths or Git
keys. Materialized inputs select `path:` flakes so Nix sees the granted bytes:
direct `nix build` and `nix eval` local flake arguments are rewritten and `make` receives
`ALAMODE_BUILD_FLAKE`. Never supply a git-crypt master key. A grant permits the guest
workload to read that file and include its contents in build output.

## Reviewed upstream

- [Tart 2.40.1 runtime options](https://github.com/cirruslabs/tart/blob/05edeac562bae804ea4f88592cfbc98cc6791b5d/Sources/tart/Commands/Run.swift)
  and [guest execution](https://github.com/cirruslabs/tart/blob/05edeac562bae804ea4f88592cfbc98cc6791b5d/Sources/tart/Commands/Exec.swift).
- [Softnet 0.24.1 filtering](https://github.com/cirruslabs/softnet/blob/6e8b5ff29a3afde5704532f5ef7df3afbaa4d8a9/lib/proxy/vm.rs)
  and [rule precedence](https://github.com/cirruslabs/softnet/blob/6e8b5ff29a3afde5704532f5ef7df3afbaa4d8a9/lib/proxy/rules.rs).
- Both releases use [FSL-1.1-ALv2](https://github.com/cirruslabs/tart/blob/05edeac562bae804ea4f88592cfbc98cc6791b5d/LICENSE).

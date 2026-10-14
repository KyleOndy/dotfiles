# alamode development requirements

Desired end state for alamode, its launcher, and the coordinator. Acceptance
requires recorded test evidence.

Pi should be our primary interface for daily development. We should be able
to choose models, run real workloads, and delegate work without managing a
collection of terminals or disabling containment to finish ordinary tasks.
This dotfiles repository is a required workload, including Nix builds and
agent-authored commits.

The requirements describe outcomes. Replacing the wrapper, broker, storage
layout, or child execution model is acceptable when needed to meet them.
The current implementation is not an architectural constraint.

## Confirmed goals

- **Daily use:** alamode is the main development interface, with usable model
  selection, tools, builds, tests, and background jobs.
- **Safe development:** an agent can work and commit on its assigned branch
  without gaining authority over the human's host or unrelated work.
- **One human entrypoint:** the main conversation directs children and
  handles their questions, progress, results, and failures.
- **Independent coordinator:** ordinary coordination works with Forge
  absent. Forge is an optional resource for local Kubernetes work.
- **Durable design:** substantial refactoring is allowed. Passing the
  requirements matters more than preserving existing scripts and flags.

The security and operational requirements below define the baseline for
these goals. Implementation choices follow the acceptance scenarios.

## Threat model and scope

Treat model output, repository content, dependency scripts, build recipes,
tool output, and child reports as untrusted. An agent may run arbitrary code
within its granted workspace. Assume it can deliberately attempt every
operation its operating system permissions permit.

The human authorizes resources and capabilities. Enforcement, credential
access, and resource ownership live outside agent-writable state. The main
model has the same obligation to stay within its authority as every child.
Instructions and output guards may guide behavior; OS and service boundaries
must enforce permissions even when that guidance is ignored.

The boundary must contain arbitrary workload code without assuming it is
well behaved. Kernel, hypervisor, and trusted service vulnerabilities remain
outside that guarantee. Data deliberately supplied to a selected model goes
to its approved provider; we cannot promise that this provider never sees it.

Acceptance targets are work-mac and trex on Darwin. Linux is deferred.
Any future Linux backend must pass equivalent behavior and containment tests
before it is advertised as supported.

## Requirements

### Security and authority

- **SEC-1: Consistent enforcement.** Direct launches, convenience commands,
  resumes, regrants, research tasks, and coordinator children enforce the
  same policy semantics. Changing network mode must not widen filesystem,
  Git, process, socket, or credential access. Missing enforcement fails
  closed.
- **SEC-2: Complete capability records.** Each session has a trusted record
  of its workspace, provider, network destinations, filesystem paths,
  services, and workload resources. The human can inspect it. Children may
  receive subsets of human-authorized capabilities without repeated prompts;
  neither model may widen them. New authority requires a human decision.
- **SEC-3: No executable persistence.** Agent writes cannot become trusted
  code or configuration in a later session or the human's shell. This covers
  Git metadata, direnv inputs, executable search paths, extensions, model
  catalogs, auth resolvers, and trust records. Settings changes remain scoped
  to their session unless the human promotes them. Concurrent sessions and
  resume must preserve this boundary.
- **SEC-4: Credential separation.** Arbitrary workload code cannot read
  reusable human or provider credentials. Required authenticated operations
  use scoped authority without exposing backing credentials. Secrets stay
  managed through sops or the existing credential store. Private model IDs
  and endpoints stay out of public commits, fixtures, and diagnostics.
- **SEC-5: Trusted mediation.** Operations outside a session validate the
  caller, capability, resource owner, and parameters. Child-controlled paths,
  symlinks, reports, and state files cannot redirect host operations. Checks
  must survive concurrent requests and resource reassignment. Prompt text
  cannot create approval.

### Development and Git

- **DEV-1: Ordinary work succeeds.** An authorized session can inspect and
  edit code, install permitted dependencies, compile, test, and run project
  verifiers. A clean checkout and cold caches must work. Required steps must
  not depend on hidden state from an earlier human session.
- **DEV-2: Normal branch commits.** Agents can stage and commit ordinary
  changes with a distinct agent identity, without the human's signing key.
  Index refresh in a git-crypt repository must not require granting the
  repository's master key for unrelated files. Editing protected content
  requires separately defined authority; encryption filters are never
  bypassed to make staging succeed.
- **DEV-3: Repository integrity.** An agent cannot alter another workspace,
  branch, index, configuration, or existing Git object through shared
  storage. Protection covers loose and packed refs, pointer files, aliases,
  and resources created after launch. Integration into another branch is an
  explicit coordinator operation under its assigned authority.
- **DEV-4: Usable tools and jobs.** Interactive and headless tools use the
  configured shell and writable scratch paths. Long builds and local test
  servers have visible progress, logs, cancellation, and completion. Local
  service access is scoped to the workload; a preview server must not grant
  access to every host service. Limits prevent runaway resource use.
- **DEV-5: Model choice is reliable.** The human can select and change models
  and supported reasoning levels for the main session and children. Known
  tool, image, or context incompatibilities produce actionable errors;
  fallback is explicit. Provider changes cannot silently send context to a
  destination outside the session's authority. Provider failures preserve
  completed work and remain distinguishable from policy refusals.

### Nix and workload execution

- **BUILD-1: This repository is supported.** An authorized main session or
  child can evaluate both Darwin configurations, build representative
  changed packages, and run this repository's verifier. Cached outputs alone
  do not establish support. Source builds must have a supported execution
  path when the local backend cannot run them safely.
- **BUILD-2: Delegation preserves containment.** A daemon, remote builder,
  container, or VM does not turn build permission into host root, host secret
  access, arbitrary host mounts, or unrestricted access to host services.
  The effective builder boundary must be verified before accepting work;
  unknown or weaker protection cannot be accepted by printing a warning.
- **BUILD-3: Network authority is explicit.** Dependency fetching and
  fixed-output builds have a declared network policy enforced where they
  execute. Daemon-side network access cannot silently bypass that policy.
  Whether the approved build profile permits general internet egress is an
  open decision. Human credentials remain protected under either choice.
- **BUILD-4: State and artifacts have owners.** Workload temporary files,
  sockets, caches, and outputs cannot expose unrelated host or session data.
  Shared caches need an integrity argument. The human can inspect and retain
  outputs without reusing an agent's executable configuration or granting
  write access to the human environment.
- **BUILD-5: Forge is optional.** Launch, delegation, builds, tests, commits,
  follow-ups, recovery, and cleanup work with Forge uninstalled. A Kubernetes
  task may request an authorized Forge resource. Its resource lifetime and
  quota are separate from the child conversation's lifetime and quota.

### Coordinator and child sessions

- **COORD-1: One control surface.** The human can start work, answer child
  questions, change direction, inspect output, and stop work through the main
  session. Optional child terminals provide visibility; routine control must
  not require entering them. Human cancellation must work when the model is
  stalled or unavailable.
- **COORD-2: Follow-up is normal.** The coordinator can send, steer,
  interrupt, retry, and resume a child while preserving its context,
  workspace, branch, and permissions. A changed capability set is explicit;
  when replacement is required, completed work and session identity survive.
- **COORD-3: State means what it says.** Distinguish starting, executing,
  waiting for input, idle, failed, lost, and closed sessions. An accepted
  request is not completion. A live process or terminal is not active work.
  Child summaries and verifier evidence are separate from process outcomes.
- **COORD-4: Bounded scheduling.** Active turns, idle processes, workload
  resources, and retained artifacts have separate limits. Idle children do
  not consume active-turn capacity. Global limits hold across coordinators;
  failed starts and abandoned operations cannot permanently consume capacity.
- **COORD-5: Work survives interruption.** A terminal disconnect does not
  discard children. Reattachment restores the main conversation and resource
  inventory. Broker restart reconciles actual workers before retrying work
  or freeing ownership. Retried requests cannot duplicate tasks or destroy a
  resource now assigned elsewhere. Host reboot reports lost work accurately.

### Results and maintenance

- **OPS-1: Truthful results.** Success requires the correct assistant outcome
  and applicable verifier results. Tool text, an empty response, accepted
  requests, and process exit zero cannot stand in for success. Cancellation,
  timeout, provider failure, permission denial, and test failure stay distinct.
- **OPS-2: Visible recovery.** The human sees child state, last activity,
  questions, errors, and available recovery actions. Refusal guidance uses
  actual failure evidence and names the missing authority without inventing
  a cause. Successful searches quoting errors must remain successful.
- **OPS-3: Faithful resume.** Resume restores the workspace, session,
  selected model, configuration version, and authorized capabilities,
  including ad hoc paths and network modes. Changed or unavailable authority
  is explained before work continues. Credentials are never embedded in a
  printed resume command.
- **OPS-4: Safe cleanup.** Cleanup preserves uncommitted and unintegrated
  work unless the human explicitly authorizes discarding it. Branch removal
  checks the intended integration target. Destructive resource operations
  verify current ownership. Partial failures remain visible and retryable;
  repeated cleanup cannot affect a later owner.
- **OPS-5: Verifiable operation.** Trusted lifecycle and permission records
  cannot be forged by rewriting a child transcript. Records identify which
  model, policy, configuration, and tree a result used without publishing
  secrets. Normal verification includes real-pi integration and platform
  containment checks. Upgrades and policy changes repeat affected checks;
  existing cached results are insufficient evidence of a changed boundary.

## Acceptance scenarios

Each scenario needs a runnable check and recorded result before the relevant
requirements are considered met. These are target tests, not claims about
the current branch.

| Scenario                 | Required result                                                                                                                                                                                             | Requirements                                |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Ordinary development     | From a fresh workspace and cold caches, edit, build, test, commit, and inspect the result without signing credentials or manual sandbox repair.                                                             | DEV-1, DEV-2, DEV-4                         |
| Dotfiles workload        | A child completes the Darwin evaluation, representative source build, verifier, and ordinary commit. Git-crypt files remain protected. Repeat after a cache miss.                                           | DEV-2, BUILD-1, BUILD-2                     |
| Hostile Git writes       | Attempt pointer replacement, packed-ref updates, object replacement, sibling writes, and writes to later-created siblings. Protected state remains unchanged; normal commits still work.                    | SEC-1, DEV-2, DEV-3                         |
| Executable persistence   | Plant Git, direnv, settings, extension, credential-resolver, and executable-path changes. Start and resume sessions concurrently. No plant runs with greater authority or in another session.               | SEC-3, SEC-4, SEC-5                         |
| Mode and platform parity | Repeat boundary probes through direct launch, convenience commands, resume, regrant, children, and each network mode on every supported OS. Only the declared capabilities differ.                          | SEC-1, SEC-2, OPS-3                         |
| Builder boundary         | Probe synthetic private host files, public temporary files, sockets, loopback, network destinations, and privilege overrides, including from fixed-output recipes. Only the declared build policy succeeds. | BUILD-2, BUILD-3, BUILD-4                   |
| Central child control    | With Forge absent, spawn, answer a question, steer, interrupt, follow up, and resume through the main session. Settled children release active-turn capacity.                                               | BUILD-5, COORD-1, COORD-2, COORD-3, COORD-4 |
| Interrupted operations   | Disconnect the UI and kill the broker during startup, execution, and cleanup. Reattach without duplicate work, leaked quota, lost commits, or incorrect ownership.                                          | COORD-4, COORD-5, OPS-4                     |
| Truthful failures        | Inject authentication errors, rate limits, failed tools, empty replies, cancellation, and quoted refusal text in successful output. Each produces the correct state and recovery action.                    | DEV-5, OPS-1, OPS-2                         |
| Safe cleanup             | Test a dirty workspace, a branch merged only into its upstream, a partially failed cleanup, and a reassigned resource. Preserve work and the new owner's resource; retain visible errors.                   | OPS-4, SEC-5                                |
| Evidence and upgrades    | Attempt to forge completion or authority through child files. Change pi or policy versions and rerun affected tests, including real-pi behavior and scoped live provider checks.                            | SEC-2, DEV-5, OPS-5                         |

Tests use synthetic credentials and disposable resources. Live provider
checks use approved endpoints and bounded workloads. Model IDs remain private.

## Implementation choices

- **Coordinator:** one persistent service per coordinator session, with a
  repository snapshot and supervised children. Forge is an optional grant.
- **Git:** independent repositories and private branches. Export and child
  integration validate bundles outside worker-controlled Git metadata.
- **Builds:** disposable native Darwin VMs with explicit public IPv4 CIDRs,
  no host shares, and no host daemon access. Protected files require
  individual materialized-input grants; Git encryption keys stay outside.
- **Configuration:** immutable deployed runtime and policy, private writable
  session preferences, and host-side provider credential mediation.
- **Limits:** defaults of 8 active turns and 16 live workers across
  coordinators, 64 retained children per coordinator, and 8 retained build
  VMs. Admission preserves existing work when a limit is reached.

See [session operation](alamode-sessions.md), [builder configuration](../nix/pkgs/alamode-builder/README.md),
and the [regression suite](alamode-sandbox-tests.md) for the implementation and
runnable checks.

## Design constraints and evidence

Pi already exposes steering, follow-up, abort, and session events. Its
`agent_settled` event identifies when automatic work has settled; an accepted
prompt alone does not establish completion. Any child-control design should
account for these semantics ([Pi 1.0.0 RPC][pi-rpc]). Reuse the existing
control work in [alamode-delegate](../nix/pkgs/alamode-delegate/alamode-delegate.py) where it
meets the requirements. RPC is a candidate mechanism, not a security boundary.

Nix client trust and builder confinement are separate controls. Trusted
clients have authority equivalent to host root, while the sandbox configuration
also governs additional exposed paths and build isolation
([Nix 2.35 configuration][nix-config]). Builder network and temporary-file
exposure must therefore be part of the chosen execution design.

The [sandbox audit](pi-sandbox-audit.md) and
[Nix build sandbox measurements](darwin-nix-sandbox.md) are historical
records of the revisions they tested; the acceptance scenarios above
determine readiness for this end state.

Track design decisions and implementation work against requirement IDs.
Change a requirement explicitly when the desired behavior changes. A missing
test, unsupported platform, or known escape remains an unmet requirement.

[pi-rpc]: https://github.com/earendil-works/pi/blob/a13d35a742c6ef8462812a28fbe1d8c8b7431c32/packages/coding-agent/docs/rpc.md#run-lifecycle
[nix-config]: https://nix.dev/manual/nix/2.35/command-ref/conf-file.html#conf-trusted-users

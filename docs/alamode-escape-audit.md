# alamode escape audit: 2026-10-14

Status: audit report, 2026-10-14, with the fixes that follow it in this
session's commits. The launch was sealed at the admission-gate fix, short
of the pseudo-terminal fix and the marker removal; the session resumed
from its export finished both, and "The resumed session" below records
what that one added. Run from inside the sandbox the way a compromised
session would run it: one default-grant session (`git-write` only) in
this worktree on trex (aarch64-darwin, macOS 27.0.1, srt 0.0.79 in
strict mode). Every claim below was probed live; the proofs are the
admission PoC harness, pty markers, and errno tables quoted in place.
Nothing sensitive was read or moved: no credential file was opened, no
key was printed, and the one file planted in this worktree
(`CLAUDE.local.md`, a labeled marker) is removed again before landing —
the commit that removes it closes the resumed session — so what lands
is the proof chain, not the plant.

## What held, re-measured on srt 0.0.79

The 2026-10-11 audit's OS-layer findings were re-probed, since its own
residuals say to re-verify on every srt bump:

- All seven alamode profile patches still match the 0.0.79 profile, and
  the runner stays fail-closed on a layout change.
- `link(2)` is EPERM even on readable sources, and `clonefile(2)` is
  EPERM on deny-read sources, so the read denies still cannot be
  sidestepped by inode aliasing.
- The loopback allowlist is per-port: only the relay and proxy ports
  answer, every other port is EPERM, and `allowLocalBinding`'s
  0.0.78-era hole (every loopback service admitted) stays closed by the
  alamode port carve.
- The proxy 403s CONNECT and SOCKS to every loopback spelling probed
  (`127.1`, `2130706433`, `0177.0.0.1`, `0x7f.1`, a trailing dot,
  `[::1]`, `localhost`) and to public hosts; unauthenticated requests
  get 407. Direct UDP and DNS are dead.
- The agent-directory class that audit called high (bin, npm, mcp.json,
  trust.json, auth.json, models-store.json) is deny-written in-session
  and the OS denies hold across every case spelling probed — eleven
  variants of the guarded names, denied while sibling files write fine.
- Keychain, `/run/secrets` (both provider keys), `~/Library`, the
  record root and `/private/var/db` stay read-denied; `security(1)`
  runs but sees a sandboxed, empty keychain view.
- `ps` is EPERM and `kern.proc` sysctls are out of the profile, so a
  session cannot enumerate host processes.
- The clipboard mach service is denied without the grant (`pbcopy` and
  `pbpaste` both fail).
- The relay is as narrow as designed: exact-match routes, one token,
  pinned upstreams, re-serialized bodies, kagi extract URLs fetched by
  kagi.com rather than the host, and a bell that spawns one fixed
  binary with no arguments.
- The host's prompt and status tooling (`git-worktree-prompt`,
  `tmux-status`) parse `.git` files directly and never run git commands
  from a session-controlled repository.

## Finding 1: CLAUDE.local.md rides admission as ordinary content (high)

The landing chain is seal (`session.py:seal_session`), admit
(`workspace.py:admit_bundle`), then `land()`, which moves the launch
branch only when the launch was clean, the checkout is still on it, and
`admit_bundle` recorded no context files. The context-file record is
built from `CONTEXT_FILES = ("agents.md", "agents.override.md",
"claude.md")` (`workspace.py:24`) plus the `.agents` and `.claude`
directories — but Claude Code also loads `CLAUDE.local.md` as project
memory, and it is not in the list.

Running the real gate against scratch proposals:

    [exact-case .gitattributes]   REFUSED (control: the gate fires)
    [CLAUDE.local.md]             ADMITTED, context_files=[]
    [CLAUDE.md control]           ADMITTED, context_files=['CLAUDE.md']

So a session that adds a `CLAUDE.local.md` — model-authored
instructions for the human's unsandboxed Claude Code — passes admission
as ordinary content and, on a clean launch, fast-forwards the launch
branch on quit with no hold and no review warning. This session armed
exactly that chain with a labeled marker commit; the sealing cut the
launch short of its removal, and the resumed session removed it once
the fixes were in. The branch history keeps the proof.

Fix: add `claude.local.md` to `CONTEXT_FILES`, so the hold
`land()` already applies to `CLAUDE.md` covers it.

## Finding 2: every host pseudo-terminal is session-writable (high)

srt's `allowPty` block (`macos-sandbox-utils.js:975-983` in 0.0.79)
admits read, write and ioctl on `/dev/ptmx` and every `/dev/ttys*`, and
alamode passes `allowPty: True` (`session.py:sandbox_policy`). The allow
is load-bearing: pi re-opens `/dev/tty` for its TUI, and pty slaves pi
creates for its children are opened by path. But it also covers every
other pane on the host.

Measured from inside the sandbox:

- Every live pty opens by path — ten panes with correct window sizes —
  and `FIONREAD` and `TIOCGWINSZ` answer on all of them.
- A by-path open and write round-trips to the master: proven on a
  self-created slave, then once, labeled, against another pane's
  display (`/dev/ttys004`; cosmetic, one-shot).
- Reading a foreign slave drains that pane's input queue: typed-ahead
  keystrokes can be stolen and consumed before the pane's program reads
  them. A pane waiting at a password prompt is the crown-jewel case.
- Writing a foreign slave paints that pane's display: forged prompts,
  including a "Relaunch with these grants? [y/N]" twin in a different
  pane. The real confirmation's `tcflush` only clears pre-typed input,
  so it does not cover a spoofed prompt in another pane.
- What stays closed: `TIOCSTI` is EPERM even on a self-created pty
  (re-measured on 0.0.79), and tmux's master halves are fd-only, so
  keystroke injection into other panes is not available. Theft and
  display-spoofing are.

Fix: the session profile now denies, by literal path, every
`/dev/ttys*` that exists at launch except the launching pane's own
slave (`session.py:session_tty_denies`, appended after srt's allow
block in `sandbox.mjs`; Seatbelt resolves last-match-wins). The
session's own terminal and slaves pi creates later keep working.
Residual: a slot first used after launch — a pane opened mid-session,
or a fresh slave pi creates — is outside the frozen deny list until the
next launch, which is why the enumeration runs at every launch. A
denied slot that devfs later reuses for one of pi's own slaves would
break that one child, not the session.

## Finding 3: two case-sensitive checks in a case-insensitive gate (moderate)

`admit_bundle`'s header comment says every comparison below is
lowercased because APFS is, but two are not: `.gitattributes`
(`workspace.py:708`) and `.git-crypt/` (`workspace.py:264`). Git
honors case-variant attribute files on APFS: measured, a
`.GITATTRIBUTES` holding `crlf.txt text eol=lf` normalized CRLF to LF at
`git add`, and `git check-attr` answered `text: set`. The gate's answer:

    [exact-case .gitattributes]  REFUSED
    [upper-case .GITATTRIBUTES]  ADMITTED, context_files=[]
    [mixed-case .GitAttributes]   ADMITTED, context_files=[]

Impact: in a repository that tracks no attributes file, a case variant
lands silently and can hide diffs from review (`-diff`), force a filter
pipeline, or flip encodings; in one that does (like this one), the
tree collision makes the landing's checkout refuse — a landing DoS.
The same class applies to `.GIT-CRYPT/` key paths, which `_protected`
must treat as the real thing. The launch-side special case at
`workspace.py:346` needs no change: both branches read the file with
`_read_entry` and hash it raw, so the snapshot treats a variant spelling
as data either way.

Fix: lowercase both comparisons, and test the variants the same way
the trust-gated configuration is tested.

## Verification in this session

- The admission PoC harness, re-run against the patched gate: both
  case variants of the attributes file are refused with the same
  message as exact case, and `CLAUDE.local.md` now lands in
  `context_files`, so `land()` holds it for review.
- `python3 test_workspace.py` and `python3 test_session.py` run the way
  the flake check runs them, from inside the sandbox. Baseline
  environmental failures (a global-ignore resolution test and four
  tests that need `/tmp` writes or long AF_UNIX paths, both denied
  here) are unchanged by the fixes; every test the fixes touch passes.
- What this session cannot verify: the darwin system build and the
  native containment probes (`native-check.nix`) need the `nix` grant,
  which a default session does not carry. The profile patch is
  fail-closed — an srt bump that changes the pty block refuses to start
  the session rather than running wide — and the flake check exercises
  the runner against the real srt.

## The resumed session

The launch was sealed at the admission-gate fix, so the exported bundle
stopped short of finding 2's fix and of the marker removal. The session
resumed from that export finished both:

- `session_tty_denies` (session.py) enumerates every `/dev/ttys*` that
  exists at a launch or resume, keeping the launching pane's own slave,
  and the patch in sandbox.mjs appends a literal deny for each slot
  after srt's pty allow block, where Seatbelt resolves last-match-wins.
  The patch is anchored on the block's exact text, matched exactly once
  against a profile the real srt 0.0.79 generated.
- test_session.py covers the enumeration (foreign slots frozen, the
  own slave kept, Darwin-only) and the payload plumbing, and adds a
  native probe (`test_real_pi_denies_foreign_tty_slots`) that plants a
  foreign pty before the launch, expects EPERM on both an open-for-read
  and an open-for-write of it, and proves a pty the session itself
  creates still opens and answers `TIOCGWINSZ`.
- What the resumed session cannot verify is the same wall the launch
  hit, now measured directly: this Mac refuses to nest a Seatbelt
  profile inside a session's own — even an `(allow default)` one fails
  with `sandbox_apply: Operation not permitted` — so the live verdict
  is the flake check's native probe. In the resumed session's sandbox
  the payload test joins the four `/tmp`-denied tests of the baseline;
  the suites otherwise hold that baseline (the global-ignore test still
  fails environmentally, identical to the sealed tree).
- A later regrant added the flake bundle, which let the nix-side checks
  run through the session daemon. `nix build .#alamode-runtime` and
  `.#alamode` build clean (the wrapper execs the patched runtime), and
  `checks.aarch64-darwin.alamode` runs the full suites in the daemon's
  build sandbox: 50 of 52 pass — the global-ignore and AF_UNIX failures
  of the direct in-session runs disappear there, and both
  `session_tty_denies` tests pass. The two errors are the pair that
  call `execute()` — the pre-existing tmpdir test and the new payload
  test — because the session daemon's sandbox is darwin's default
  deliberately without `/private/tmp`; the host daemon, where `make
check` runs, admits it. The four skips are the native probes, which
  no nested sandbox can run. The darwin system build now evaluates and
  starts building, and stops where every session must: the git-crypt
  fonts, whose sources session worktrees exclude by design. That
  verifier target goes green only from the human's full worktree.
- The host then closed both gaps: `make check` and `nix run
.#alamode-check-native` pass. On the host daemon the `execute()`
  pair clears too, and the native probes — the new tty slot probe among
  them — returned the live verdict finding 2's fix was built for: a
  foreign slot planted before the launch is EPERM to open, for read and
  for write, while a pty the session itself creates still opens and
  answers `TIOCGWINSZ`. Between the two runs every test in the suites
  has now passed host-side; the audit's record said the live verdict
  was the native probe's to return, and it has.
- The commit before this one removes `CLAUDE.local.md`, so the landed
  history is the proof chain, not the plant.

## Residuals

- The tty deny list is frozen at launch (Finding 2's fix): panes first
  opened mid-session stay reachable until the next launch or resume.
- A session can still rewrite its own transcript, every allowlisted
  domain is an exfil surface, and the proxy username still
  base64-encodes the wrapped command — unchanged from the 2026-10-11
  audit's residuals.
- Grants that are escapes by definition (`--allow-nix`, `--allow-rw`)
  are unchanged.
- These fixes protect sessions started after a rebuild; this session's
  own landing ran under the deployed wrapper, which is why the marker
  was removed rather than left to land.

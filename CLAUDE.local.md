# Sandbox-escape proof — remove this file

This file was committed by the sandboxed alamode audit session
(20261014-182757-5a554599) to demonstrate a gap in `admit_bundle`:

`CONTEXT_FILES` in `nix/pkgs/alamode-runtime/workspace.py` gates
`agents.md`, `agents.override.md`, `claude.md`, and the `.agents` /
`.claude` directories — but not `claude.local.md`, which Claude Code
also loads as untrusted-input-free project memory.

So a commit adding this file:

- passes admission with `context_files=[]` (proven with a local
  `admit_bundle` run against a scratch workspace), and
- fast-forwards the launch branch on quit with no "model-authored
  instructions" hold, because the launch was clean and the branch
  unmoved.

An adversarial session would have put real instructions here, and your
unsandboxed Claude Code would have followed them on its next run in
this repository.

To clean up:

    git reset --keep origin/alamode-escape-01

(the pre-session position of the branch), or simply:

    git rm CLAUDE.local.md && git commit

---
name: code-comments
description: Comment standards for source code; applies whenever writing, editing, or reviewing code in any language, and when asked to clean up, audit, or reduce comments
---

# Code Comments

The default is no comment. A comment earns its place only by carrying
information the code cannot carry itself. Everything below is how to tell
those two cases apart.

This is not "why, never what". Some of the most valuable comments state
_what_, one level of abstraction above the code. What is always wrong is
stating what at the _same_ level as the code, because that is a restatement.

## The two tests

Run both before keeping any comment.

**1. The deletion test.** Could someone who has never seen this code write
this comment just by reading the line next to it? If yes, delete it. It adds
nothing and it is one more thing to keep in sync.

**2. The tense test.** Is the comment true of the file exactly as it stands,
to a reader who has never seen the previous version? A comment describes a
state, never a transition. If deleting all git history would make the comment
confusing, wrong, or orphaned, rewrite it.

The tense test is the one most often failed. Attribute a constraint to its
durable cause (an upstream bug, a protocol, a hardware limit, a business
rule), never to the edit that introduced it.

```nix
# BAD   switched to systemd.tmpfiles because the activation script raced
# GOOD  activation runs before the ZFS pool mounts, so the directory has to
#       come from tmpfiles instead
```

## Comments worth writing

These carry information genuinely absent from the code. Claude
under-produces all five.

| Kind                    | Example                                                   |
| ----------------------- | --------------------------------------------------------- |
| Units and scale         | `# seconds, not milliseconds; upstream API uses ms`       |
| Boundary semantics      | `;; end is exclusive; callers pass count, not last index` |
| Meaning of empty or nil | `# empty list means "all hosts", not "no hosts"`          |
| Ownership and lifetime  | `# caller closes the handle; this only borrows it`        |
| Invariants              | `;; always holds at least one entry after init!`          |

Two more, each once per construct at most:

- **The durable reason** a non-obvious construct exists, with a reference:
  `# workaround for NixOS/nixpkgs#12345; drop when that lands`.
- **The intent** of a long block or a non-obvious loop, stated one level
  above the code: `# each pass drains one host's queue`. Never per line,
  and never for a loop whose body is already obvious.

Where a reason is subtle enough to write in a commit body, it belongs in the
source too. Nobody scans the log to find out why a line exists, and a
reason that lives only in history gets reverted by the next person who sees
the line as pointless.

## Comments to delete on sight

| Anti-pattern        | Example                                               | Fix                                                        |
| ------------------- | ----------------------------------------------------- | ---------------------------------------------------------- |
| Restates the line   | `# enable the exporter` above `enable = true;`        | Delete                                                     |
| Echoes the name     | `;; returns the normalized name` on `normalized-name` | Delete or state what "normalized" means                    |
| Narrates the edit   | `# now uses a mutex`, `# removed the old handler`     | Rewrite per the tense test, or delete                      |
| Snapshot hedges     | `# for now`, `# currently only supports X`            | Delete, or make it a `TODO` with an owner and a condition  |
| Change markers      | `# NEW:`, `# UPDATED:`, `# FIXED:`                    | Delete; that is what the log is for                        |
| Dangling comparison | `# faster than the previous approach`                 | Delete; the previous approach is not in the file           |
| Commented-out code  | any                                                   | Delete it, always                                          |
| Phase banners       | `# ---- setup ----` over four obvious lines           | Delete; if the function needs signposts it needs splitting |

Keep unconditionally: `TODO`, `FIXME`, and tool directives such as
`# shellcheck disable=SC2016`, `// eslint-disable-next-line`,
`# nixpkgs-fmt: off`. Keep any comment that stops a block being empty or
syntactically invalid.

## Placement

Put the comment on its own line above what it describes, at the same
indentation. Trailing comments are fine on enumerated items where the
comment annotates one entry, which is how they already read in this repo:

```nix
environment.systemPackages = with pkgs; [
  ffmpeg # roku-transcode shells out to ffprobe
];
```

Anywhere else, move it above the line.

## Editing existing code

Leave comments you did not touch alone. A file's existing comments are out
of scope unless the change makes one false.

When a change makes an existing comment wrong, fix the comment in the same
edit. A comment that has drifted from its code is worse than no comment:
inconsistent code and comment changes are around 1.5 times more likely to
carry a bug than consistent ones (Wen et al., ICPC 2019).

Never delete a `why` comment while refactoring the code it explains. If the
construct survives in any form, the reason survives with it.

## Language notes

- **Nix**: comment the option, not the assignment. Module-level `#` blocks
  explaining a non-obvious interaction between services are the highest
  value comments in this repo; per-attribute narration is the lowest.
- **Shell**: `set -euo pipefail` and `readonly` need no comment. Comment the
  quoting or subshell trick that is not obvious, and nothing else.
- **Clojure**: prefer a docstring on the var over a `;;` block above it.
  Use `;;` for block comments, `;` for a trailing comment, `#_` to disable a
  form rather than commenting it out.

## References

- [Google eng-practices, what to look for in a code review: comments](https://google.github.io/eng-practices/review/reviewer/looking-for.html#comments)
- John Ousterhout, _A Philosophy of Software Design_, 2nd ed., 13.2 (don't
  repeat the code), 13.3 (lower-level comments add precision), 13.4
  (higher-level comments enhance intuition), 13.6 (what and why, not how),
  16.3 (comments belong in the code, not the commit log).
  [PDF](https://milkov.tech/assets/psd.pdf)
- [Wen et al., A Large-Scale Empirical Study on Code-Comment Inconsistencies, ICPC 2019](https://www.inf.usi.ch/lanza/Downloads/Wen2019a.pdf)

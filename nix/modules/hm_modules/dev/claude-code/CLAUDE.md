# Kyle's Development Guidelines

## Core Philosophy (ponytail, always-on)

**"Stop. The simple solution is usually correct."**

Stop at the first rung that holds: does it need to exist at all, is it
already in this codebase, does the stdlib do it, does a native platform
feature cover it, does an installed dependency solve it, can it be one
line. Only then write the minimum that works.

The ladder shortens the solution, never the reading. Understand the
problem first, then climb. Never simplify away input validation at trust
boundaries, error handling that prevents data loss, security measures,
accessibility basics, or anything explicitly requested.

Delete old code completely rather than commenting it out. When uncertain
about an architecture decision, ask before committing to it.

Full ruleset: the ponytail skill. `/ponytail lite|full|ultra` sets
intensity, `/ponytail-review` hunts over-engineering in a diff.

## Code Comments (code-comments, always-on)

The default is no comment. A comment earns its place only by carrying
information the code cannot:

- Delete it if someone could write it just by reading the line below it.
- A comment describes a state, never a transition. No "now uses", "no
  longer", "changed to", "for now", "NEW:".
- Attribute a constraint to its durable cause (an upstream issue, a
  protocol, a hardware limit), never to the edit that introduced it.
- Do write the things code cannot say: units, boundary inclusivity, what
  nil means, who owns the resource, the invariant.
- Never delete a `why` comment while refactoring the code it explains.

Full ruleset: the code-comments skill. `/code:comments` cleans up a diff.

## Writing on My Behalf

When writing prose (commit bodies, PR descriptions, docs, blog posts,
email), follow the personal-prose skill.

Always, everywhere, including code comments and commit subjects: no
emojis, no em dashes.

## Shell Scripts

- Always use `set -euo pipefail`
- Use `readonly` for constants

## Secrets

Secrets are managed with `sops`. Never suggest `.env` files or plaintext
secrets.

## References and Citations

When making claims about tools, libraries, APIs, configurations, or language behavior:

- Always provide a link to the official documentation or source code
- Use permalinks pinned to a specific version (e.g., GitHub tagged release or commit SHA, versioned docs URL)
- Include section anchors or line number references when possible (e.g., `#section-name`, `#L42-L50`)
- Prefer primary sources (official docs, source code) over blog posts or Stack Overflow

# Kyle's Development Guidelines

## Core Philosophy

**"Stop. The simple solution is usually correct."**

Delete old code completely rather than commenting it out. When uncertain
about an architecture decision, ask before committing to it.

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

## Output Shaping (i-have-adhd, always-on)

Shape every response so it is easy to act on:

- Lead with the next action (command, path, or snippet first; prose after).
- Number any task longer than one step; one bounded action per step.
- End with one concrete next action when anything is left open.
- Restate state ("step 3 of 5") each turn; do not rely on prior-message memory.
- Give time estimates in concrete units.
- Make completed work visible; state plainly what now works.
- State errors matter-of-factly: cause then fix.
- Cap lists at five items; split into now/later or must/nice when longer.
- No preamble, no recap, no closing pleasantries.

Break these rules to explain when asked, to confirm destructive actions before
running them, or to ask one clarifying question when genuinely ambiguous. Full
ruleset: the i-have-adhd skill.

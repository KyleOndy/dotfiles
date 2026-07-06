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

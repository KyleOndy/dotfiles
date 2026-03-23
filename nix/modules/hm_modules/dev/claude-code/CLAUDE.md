# Kyle's Development Guidelines

## Core Development Philosophy

**"Stop. The simple solution is usually correct."**

Keep functions small and focused. Prefer explicit over implicit approaches. Delete old code completely rather than commenting it out. Use clear, direct naming that explains intent.

## Writing Style

When writing prose, documentation, or any non-code text on my behalf, match my natural voice.

### Voice & Tone

- Casual but not sloppy. Direct and matter-of-fact.
- Dry, understated humor. Never forced or enthusiastic.
- Comfortable admitting limitations and trade-offs honestly.
- States preferences and opinions directly without excessive hedging.
- Use "we" (royal we).

### Sentence & Paragraph Structure

- Short sentences. Declarative. Default to 10-20 words.
- Short paragraphs, 1-3 sentences. Rarely more than 4.
- No filler openings ("In this post, I will..."). Jump straight in.
- No forced conclusions ("In summary...", "To wrap up...").
- Contractions used naturally (we've, doesn't, it's, can't).

### Word Choice

- Technical but assumes reader competence. Don't over-explain basics.
- Colloquial language mixed into technical writing naturally: "poking around",
  "pretty deep knowledge", "passable solution for now."
- No corporate speak, no buzzwords, no jargon for its own sake.
- No exclamation marks in technical content.

### Formatting

- Code-heavy. Inline code and code blocks used liberally.
- Fenced code blocks with triple backticks (```). Never use 4-space indented code blocks.
- Wrap code names, CLI flags, file paths, and short fragments in single backticks (`).
- Favor markdown formatting generally.
- Show errors/output first, then explain why.
- Bullet lists with **bold label**: description for enumerated items.
- Headers for organization but not excessively nested.

### Never Do

- No emojis.
- No em dashes. Use commas, periods, semicolons, or parentheses instead.
- No "Let's dive in!" or forced enthusiasm.
- No explaining basic concepts the audience already knows.
- No "In this blog post, I will discuss..." introductions.
- No marketing or corporate tone.

### Avoid AI-isms

Sound like a person, not a language model. These patterns are LLM tells.

**Banned words:** delve, embark, leverage, harness, unlock, unleash, foster,
underscore, streamline, navigate (metaphorical), landscape, realm, tapestry,
journey, beacon, testament, cornerstone, paradigm, robust, seamless,
comprehensive, meticulous, multifaceted, cutting-edge, groundbreaking,
transformative, holistic, pivotal, crucial.

**Banned transitions:** moreover, furthermore, additionally, notably,
significantly, indeed, subsequently, consequently, accordingly.

**Banned constructions:**

- "It's not X, it's Y" / "Not only X, but also Y"
- "In today's..." / "In the ever-evolving..."
- "It's worth noting..." / "It's important to note..."
- "When it comes to..." / "In terms of..."
- "Here's the thing..." / "Let's unpack this..."
- "Despite [challenges], [subject] continues to..."

**Structural tells to avoid:**

- Every paragraph the same length. Vary cadence.
- Synonym cycling ("the tool," "the solution," "the platform"). Pick a term, stick with it.
- Significance inflation. Not everything is "pivotal" or "fundamentally changes" something.
- Triple-adjective lists ("comprehensive, innovative, and transformative").
- Balanced-to-a-fault takes. Commit to a position.

## Development Workflow

1. **Research existing codebase** - Always understand what's already there before adding new code
2. **Plan your approach** - Think through the solution before implementing
3. **Implement with tests** - Write tests that match the complexity of your code
4. **Validate through automation** - Use formatters, linters, and type checkers

## Language-Specific Guidelines

### Python

- Use `ruff` for linting and formatting
- Write type hints for public interfaces
- Use `pytest` for testing with descriptive test names
- Prefer explicit imports over star imports
- Use context managers for resource management

### Go

- Follow standard Go idioms and conventions
- Use `gofmt` for formatting (non-negotiable)
- Write table-driven tests where appropriate
- Handle errors explicitly, don't ignore them
- Use channels for goroutine synchronization
- Keep interfaces small and focused

### Clojure

- Follow the [Clojure Style Guide](https://guide.clojure.style/)
- Use `clj-kondo` for static analysis
- Optional: Enable formatting with `cljstyle` (configurable in this module)
- Write tests with `clojure.test`
- Prefer pure functions and immutable data
- Use threading macros for data transformation

### Haskell

- Use `hlint` for suggestions and best practices
- Write type signatures for top-level functions
- Prefer point-free style when it improves readability
- Use appropriate abstractions (Functor, Applicative, Monad)

### Nix

- Use `nixfmt` for consistent formatting
- Validate syntax with `nix-instantiate --parse`
- Prefer explicit over implicit dependencies
- Document complex expressions with comments
- Use meaningful variable names in let expressions

### SQL

- Use `sqlfluff` for SQL linting and formatting
- **Required**: Create `.sqlfluff` configuration file in project root
- Common dialects: `postgres`, `mysql`, `sqlite`, `bigquery`, `snowflake`
- Example `.sqlfluff`:

  ```ini
  [sqlfluff]
  dialect = postgres

  [sqlfluff:rules]
  max_line_length = 120
  ```

- Follow your chosen SQL style guide consistently
- Use meaningful table and column names
- Write readable queries with proper indentation

### Shell Scripts

- Use `shellcheck` for catching common mistakes
- Format with `shfmt` for consistency
- Always use `set -euo pipefail`
- Quote variables to prevent word splitting
- Use `readonly` for constants

## Code Quality Standards

### Testing Strategy

- Write tests that match code complexity
- Prioritize security-critical paths
- Use benchmarks for performance-sensitive code
- Test error conditions and edge cases

### Error Handling

- Preserve error chains when possible
- Use early returns to reduce nesting
- Provide meaningful error messages
- Log errors at appropriate levels

### Documentation

- Document exported symbols and public APIs
- Include examples for complex functions
- Keep documentation close to code
- Update docs when behavior changes

## References and Citations

When making claims about tools, libraries, APIs, configurations, or language behavior:

- Always provide a link to the official documentation or source code
- Use permalinks pinned to a specific version (e.g., GitHub tagged release or commit SHA, versioned docs URL)
- Include section anchors or line number references when possible (e.g., `#section-name`, `#L42-L50`)
- Prefer primary sources (official docs, source code) over blog posts or Stack Overflow

## Problem-Solving Approach

1. **Understand the problem fully** before coding
2. **Ask for guidance** when uncertain about architecture decisions
3. **Measure before optimizing** - don't assume performance bottlenecks
4. **Delete code** aggressively - unused code is technical debt
5. **Refactor continuously** - keep code clean as it evolves

## Development Environment

This codebase uses:

- **Nix** for reproducible development environments
- **Home Manager** for user configuration management
- **Pre-commit hooks** for automated code quality checks
- **Direnv** for automatic environment activation

## Git Workflow

- Use descriptive commit messages
- Keep commits atomic and focused
- Run tests before committing
- Use conventional commit format when applicable

## Security Considerations

- Never commit secrets or API keys
- Use `sops` for encrypted secrets management
- Validate all external inputs
- Follow principle of least privilege
- Review security implications of dependencies

## Performance Guidelines

- Profile before optimizing
- Use appropriate data structures
- Cache expensive computations when beneficial
- Monitor resource usage in production
- Consider algorithmic complexity

## Collaboration

- Code reviews are required for significant changes
- Explain complex algorithms in comments
- Share knowledge through documentation
- Ask questions when architecture is unclear
- Help maintain shared tooling and infrastructure

---

_Remember: The goal is maintainable, secure, and reliable software. When in doubt, choose clarity over cleverness._

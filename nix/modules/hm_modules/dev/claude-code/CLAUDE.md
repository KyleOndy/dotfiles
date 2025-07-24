# Kyle's Development Guidelines

## Core Development Philosophy

**"Stop. The simple solution is usually correct."**

Keep functions small and focused. Prefer explicit over implicit approaches. Delete old code completely rather than commenting it out. Use clear, direct naming that explains intent.

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

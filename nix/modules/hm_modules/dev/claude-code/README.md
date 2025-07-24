# Claude Code Home Manager Module

A comprehensive Nix Home Manager module for configuring Claude Code with intelligent hooks and multi-language development support.

## Features

- **Declarative Installation**: Claude Code installed via `nixpkgs-master`
- **Smart Linting**: Multi-language linting with appropriate tools (ruff, gofmt, clj-kondo, etc.)
- **Intelligent Testing**: Automatic test suite detection and execution
- **Desktop Notifications**: Optional Linux desktop notifications
- **Configurable Clojure Formatting**: Support for cljstyle, zprint, or cljfmt
- **Development Guidelines**: Custom CLAUDE.md with your development philosophy

## Installation

1. Add the module to your Home Manager configuration:

```nix
# In your home.nix or similar
{
  hmFoundry.dev.claude-code.enable = true;
}
```

2. Rebuild your Home Manager configuration:

```bash
home-manager switch
```

## Configuration Options

### Basic Configuration

```nix
hmFoundry.dev.claude-code = {
  enable = true;                    # Enable the module
  enableHooks = true;               # Enable intelligent hooks (default: true)
  enableNotifications = false;      # Enable desktop notifications (default: false)
};
```

### Clojure Formatting

```nix
hmFoundry.dev.claude-code = {
  enable = true;
  clojureFormatting = {
    enable = true;                  # Enable Clojure formatting (default: true)
    formatter = "cljstyle";         # Options: "cljstyle", "zprint", "cljfmt" (default: "cljstyle")
  };
};
```

### Custom Development Guidelines

```nix
hmFoundry.dev.claude-code = {
  enable = true;
  projectMemory = ./path/to/custom/CLAUDE.md;  # Custom development guidelines
};
```

## Project Setup

### New Project Setup

1. **Enable Claude Code in your project**:

   ```bash
   cd /path/to/your/project
   claude  # This will create .claude/settings.json if needed
   ```

2. **The module automatically configures**:

   - Smart linting hooks that run after file modifications
   - Intelligent test execution
   - Desktop notifications (if enabled)

3. **Verify hook configuration**:
   ```bash
   cat .claude/settings.json
   ```

### Language-Specific Setup

The module automatically detects and configures tooling for:

#### Python

- **Linting**: `ruff check` and `ruff format --check`
- **Testing**: `pytest` (primary) or `unittest`
- **Requirements**: `pyproject.toml`, `setup.py`, or `requirements.txt`

#### Go

- **Linting**: `gofmt -l` and `go vet`
- **Testing**: `go test ./...`
- **Requirements**: `go.mod` file

#### Clojure

- **Linting**: `clj-kondo`
- **Formatting**: Configurable (`cljstyle`, `zprint`, or `cljfmt`)
- **Testing**: `lein test` or `clojure -M:test`
- **Requirements**: `project.clj` or `deps.edn`

#### Nix

- **Linting**: `nixfmt --check` and `nix-instantiate --parse`
- **Testing**: `nix flake check`
- **Requirements**: `.nix` files or `flake.nix`

#### Haskell

- **Linting**: `hlint`
- **Testing**: `stack test` or `cabal test`
- **Requirements**: `stack.yaml` or `.cabal` files

#### Shell Scripts

- **Linting**: `shellcheck` and `shfmt -d`
- **Requirements**: `.sh` or `.bash` files

#### JavaScript/TypeScript

- **Formatting**: `prettier --check`
- **Testing**: `npm test` or `yarn test`
- **Requirements**: `package.json`

## Hook Behavior

### Smart Linting Hook (`smart-lint.sh`)

- **Triggers**: After `Write`, `Edit`, or `MultiEdit` operations
- **Timeout**: 60 seconds
- **Behavior**:
  - Detects modified files via git
  - Runs appropriate linters based on file extensions
  - Provides colored output with success/failure indicators
  - Exits with non-zero code if any linting fails

### Smart Testing Hook (`smart-test.sh`)

- **Triggers**: After `Write`, `Edit`, or `MultiEdit` operations
- **Timeout**: 5 minutes
- **Behavior**:
  - Detects project type and available test frameworks
  - Runs appropriate test commands
  - Provides summary of test results
  - Supports parallel test execution where possible

### Notification Hook (`ntfy-notifier.sh`)

- **Triggers**: When Claude Code session ends
- **Timeout**: 5 seconds
- **Behavior**:
  - Sends desktop notification with project name
  - Only runs if desktop environment is available
  - Gracefully handles missing notification system

## Customization

### Disabling Specific Hooks

Create a local `.claude/settings.json` in your project to override module defaults:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "command": "~/.claude/hooks/smart-lint.sh",
        "timeout": 60000,
        "triggers": ["Write", "Edit", "MultiEdit"]
      }
    ]
  }
}
```

### Custom Development Guidelines

Create your own `CLAUDE.md` file:

```nix
hmFoundry.dev.claude-code = {
  enable = true;
  projectMemory = ./my-custom-guidelines.md;
};
```

### Environment Variables

The module sets these environment variables for hook configuration:

- `CLAUDE_CLOJURE_FORMATTING`: "true" or "false"
- `CLAUDE_CLOJURE_FORMATTER`: "cljstyle", "zprint", or "cljfmt"

## Troubleshooting

### Hooks Not Running

1. **Check hook permissions**:

   ```bash
   ls -la ~/.claude/hooks/
   # Should show executable permissions (rwxr-xr-x)
   ```

2. **Verify settings.json**:

   ```bash
   cat ~/.claude/settings.json
   # Should contain hook configurations
   ```

3. **Test hooks manually**:
   ```bash
   ~/.claude/hooks/smart-lint.sh
   ~/.claude/hooks/smart-test.sh
   ```

### Missing Tools

If you see "command not found" errors:

1. **Rebuild Home Manager**:

   ```bash
   home-manager switch
   ```

2. **Check installed packages**:

   ```bash
   which ruff clj-kondo shellcheck
   ```

3. **Verify module is enabled**:
   ```bash
   grep -r "claude-code" ~/.config/home-manager/
   ```

### Clojure Formatting Issues

1. **Check formatter availability**:

   ```bash
   which cljstyle  # or zprint, cljfmt
   ```

2. **Verify environment variables**:

   ```bash
   echo $CLAUDE_CLOJURE_FORMATTING
   echo $CLAUDE_CLOJURE_FORMATTER
   ```

3. **Test formatter manually**:
   ```bash
   cljstyle check src/  # or equivalent for your formatter
   ```

### Performance Issues

If hooks are slow:

1. **Adjust timeouts** in `.claude/settings.json`
2. **Disable resource-intensive hooks** for large projects
3. **Use faster formatters** (e.g., native binaries over JVM tools)

## Integration with Existing Workflow

### Pre-commit Hooks

This module complements existing pre-commit hooks. The Claude Code hooks run during development, while pre-commit hooks run before commits.

### CI/CD Integration

The same tools used by these hooks can be used in CI/CD:

```yaml
# Example GitHub Actions
- name: Lint Python
  run: ruff check --output-format=github .

- name: Test Go
  run: go test ./...

- name: Check Nix formatting
  run: nixfmt --check **/*.nix
```

### Editor Integration

These hooks work alongside editor-based linting and formatting. They provide an additional safety net during Claude Code sessions.

## Contributing

To modify or extend this module:

1. **Edit the module**: `nix/modules/hm_modules/dev/claude-code.nix`
2. **Update hooks**: `nix/modules/hm_modules/dev/claude-code/hooks/`
3. **Test changes**: `home-manager switch && claude`
4. **Update documentation**: This README.md

## Support

For issues specific to this module, check:

1. **Home Manager logs**: `journalctl --user -u home-manager-*`
2. **Claude Code logs**: Enable debug mode with `ANTHROPIC_LOG=debug`
3. **Hook output**: Run hooks manually to see detailed error messages

For general Claude Code support, see the [official documentation](https://docs.anthropic.com/en/docs/claude-code).

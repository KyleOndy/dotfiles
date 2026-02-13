# Claude Code Home Manager Module

A Nix Home Manager module for configuring Claude Code with notification hooks and development guidelines.

## Features

- **Declarative Installation**: Claude Code installed via `nixpkgs`
- **Desktop Notifications**: Optional Linux desktop notifications for Claude Code operations
- **Slash Commands**: Pre-configured task, git, code, and documentation commands
- **Development Guidelines**: Custom CLAUDE.md with your development philosophy

## Installation

1. Add the module to your Home Manager configuration:

```nix
# In your home.nix or similar
{
  hmFoundry.dev.claude-code.enable = true;
}
```

1. Rebuild your Home Manager configuration:

```bash
home-manager switch
```

## Configuration Options

### Basic Configuration

```nix
hmFoundry.dev.claude-code = {
  enable = true;                    # Enable the module
  enableHooks = true;               # Enable notification hooks (default: true)
  enableCommands = true;            # Enable slash commands (default: true)
  enableNotifications = false;      # Enable desktop notifications (default: false)
  projectMemory = ./CLAUDE.md;      # Path to development guidelines (default: ./CLAUDE.md)
};
```

## What This Module Provides

### Configuration Files

- `~/.claude/settings.json`: Claude Code settings with notification hooks
- `~/.claude/CLAUDE.md`: Development guidelines and coding standards
- `~/.claude/statusline.sh`: Custom status line showing git branch and status

### Notification Hooks

The module configures hooks that trigger on specific events:

- **Stop Hook**: Sends notification when Claude Code session ends (via ntfy or desktop)
- **Notification Hook**: Plays sound when Claude requests user attention

### Slash Commands

Pre-configured commands available in Claude Code sessions:

- `/task`: Task management and status
- `/git/*`: Git operations (commit, history, etc.)
- `/code/*`: Code operations (debug, refactor, etc.)
- `/docs/*`: Documentation generation
- `/test/*`: Test generation and execution
- `/project/*`: Project-level operations

## Customization

### Custom Development Guidelines

Override the default CLAUDE.md with your own guidelines:

```nix
hmFoundry.dev.claude-code = {
  enable = true;
  projectMemory = ./my-custom-guidelines.md;
};
```

### Disabling Notifications

To disable all notifications:

```nix
hmFoundry.dev.claude-code = {
  enable = true;
  enableHooks = false;  # Disables notification hooks
};
```

### Project-Specific Settings

Create `.claude/settings.json` in your project to override defaults:

```json
{
  "model": "sonnet",
  "hooks": {
    "Stop": [] // Disable stop hook for this project
  }
}
```

## Troubleshooting

### Notifications Not Working

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

3. **Test notification manually**:

   ```bash
   ~/.claude/hooks/enhanced-ntfy-notifier.sh
   ```

### Module Not Enabled

If Claude Code isn't configured:

1. **Verify module is enabled**:

   ```bash
   grep -r "claude-code" ~/.config/home-manager/
   ```

2. **Rebuild Home Manager**:

   ```bash
   home-manager switch
   ```

3. **Check Claude Code is installed**:

   ```bash
   which claude
   ```

## Integration with Development Workflow

### Pre-commit Hooks

This module focuses on Claude Code configuration. Use pre-commit hooks (via the pre-commit module) for automated linting and testing before commits.

### Editor Integration

Claude Code works alongside your editor. The CLAUDE.md guidelines help Claude understand your coding standards and project conventions.

## Module Structure

```text
nix/modules/hm_modules/dev/claude-code/
├── default.nix              # Main module configuration
├── settings.json            # Claude Code settings
├── CLAUDE.md                # Development guidelines
├── statusline.sh            # Git-aware status line
├── README.md                # This file
├── hooks/
│   ├── enhanced-ntfy-notifier.sh
│   ├── notification-bell.sh
│   └── ntfy-notifier.sh
├── commands/                # Slash commands
│   ├── task.md
│   ├── code/
│   ├── docs/
│   ├── git/
│   ├── project/
│   └── test/
└── assets/
    └── notification.wav

## Support

For issues specific to this module, check:

1. **Home Manager logs**: `journalctl --user -u home-manager-*`
2. **Claude Code logs**: Enable debug mode with `ANTHROPIC_LOG=debug`
3. **Hook output**: Run hooks manually to see detailed error messages

For general Claude Code support, see the [official documentation](https://docs.anthropic.com/en/docs/claude-code).
```

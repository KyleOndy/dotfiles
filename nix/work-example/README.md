# Work Fork Example Templates

This directory contains example templates for creating work-specific forks of the dotfiles repository. These templates demonstrate how to extend the base configuration without modifying core files, making rebasing from upstream easier.

## Files

### `darwin-system.nix`

Example nix-darwin system configuration for macOS work environments. This handles:

- System-level macOS settings
- Homebrew integration for GUI apps
- Company VPN/network tools
- Security settings (TouchID for sudo, etc.)

### `darwin-home.nix`

Example home-manager configuration for macOS that extends the base workstation profile with:

- Work-specific development tools
- Git configuration for work repositories
- SSH settings for work servers
- Shell aliases and functions
- Kubernetes and AWS configurations

### `wsl-home.nix`

Example home-manager configuration for WSL (Windows Subsystem for Linux) that includes:

- WSL-specific utilities and Windows interop
- Path configurations for Windows tools
- Clipboard integration with Windows
- Docker Desktop integration
- Work VPN status checking

## Usage

1. **Copy these files** to your work fork's `nix/work/` directory
2. **Customize** the configurations with your specific:
   - Email address and git settings
   - Company tools and packages
   - SSH hosts and credentials
   - AWS/Kubernetes contexts
3. **Update your fork's `flake.nix`** as shown in the main [work-forks documentation](../../docs/work-forks.md)

## Important Notes

- These are **templates only** - you must customize them for your environment
- Replace placeholder values like:
  - `your.name@company.com`
  - `work-github.com` / `work-gitlab.com`
  - `bastion.company.com`
  - `WORK_GPG_KEY_ID`
  - `YourWindowsUser` (in WSL config)
- Remove or comment out features you don't need
- Add company-specific tools and configurations as needed

## Security Reminders

- **Never commit real credentials** - use environment variables or secure secret management
- **Use different SSH keys** for work and personal repositories
- **Keep work GPG keys separate** from personal keys
- **Review all git URLs** to ensure they point to the correct work repositories
- **Test VPN/network settings** in a safe environment before using in production

## Extending the Examples

These templates follow patterns that make them easy to extend:

### Adding New Packages

```nix
home.packages = with pkgs; [
  # Existing packages...
  your-new-package
];
```

### Overriding Settings

Use `lib.mkForce` to override settings from the base profile:

```nix
programs.git.userEmail = lib.mkForce "work@company.com";
```

### Conditional Configuration

Enable specific development features using module enables:

```nix
# Enable individual development tools as needed
hmFoundry.dev = {
  aws.enable = true;        # AWS CLI tools
  kubernetes.enable = true;  # kubectl, k9s, etc.
  docker.enable = true;      # Docker tools
  terraform.enable = true;   # Terraform
  monitoring.enable = true;  # Monitoring tools
  security.enable = true;    # Security tools
};
```

## Troubleshooting

### Common Issues

1. **Package conflicts**: Use `lib.mkForce` to override conflicting packages
2. **Path issues in WSL**: Ensure Windows paths are properly escaped
3. **SSH agent problems**: Check agent forwarding settings
4. **Git credentials**: Verify credential helper configuration

### Testing Changes

Always test configuration changes before deploying:

```bash
# macOS
darwin-rebuild build --flake .#work-mac

# WSL (home-manager only)
home-manager build --flake .#kyle@work-wsl
```

## Additional Resources

- [Main work-forks documentation](../../docs/work-forks.md)
- [Nix Darwin manual](https://daiderd.com/nix-darwin/manual/index.html)
- [Home Manager manual](https://nix-community.github.io/home-manager/)
- [WSL documentation](https://docs.microsoft.com/en-us/windows/wsl/)

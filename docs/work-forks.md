# Managing Work Forks

This guide explains how to maintain work-specific forks of this dotfiles repository that can be easily rebased with upstream changes while keeping work configurations private and separate.

## Overview

The architecture of this repository is designed to be fork-friendly. Work forks can extend the base configuration without modifying core files, minimizing merge conflicts during rebases.

## Strategy

The recommended approach is to:

1. Fork this repository privately for your work environment
2. Add work-specific configurations in isolated files
3. Extend (rather than modify) the base `flake.nix`
4. Use Nix's override mechanisms (`lib.mkForce`, `lib.mkDefault`) for changes

## macOS Work Fork Setup

For a macOS work environment using nix-darwin:

### 1. Fork and Clone

```bash
# Fork this repo privately on your work GitHub/GitLab
git clone git@work-github.com:yourname/dotfiles.git ~/src/work-dotfiles
cd ~/src/work-dotfiles
git remote add upstream git@github.com:yourusername/dotfiles.git
```

### 2. Understanding the Base Configuration

The upstream repository includes base configurations in `nix/hosts/work-mac/`:

- `configuration.nix` - System-level darwin settings (hostname, nix daemon, Homebrew, etc.)
- `home.nix` - Home-manager configuration (imports workstation profile)

Both files use **conditional imports** to load work-specific overrides if they exist:

```nix
# configuration.nix includes:
imports = [ ] ++ lib.optional (builtins.pathExists ./work.nix) ./work.nix;

# home.nix includes:
imports = [ ../../profiles/workstation.nix ]
  ++ lib.optional (builtins.pathExists ./work-home.nix) ./work-home.nix;
```

This means:

- ✅ Upstream base configs flow through rebases automatically
- ✅ You only maintain **your deltas** in `work.nix` and `work-home.nix`
- ✅ No flake.nix modifications needed (it already has `darwinConfigurations.work-mac`)

### 3. Create Work-Specific Files

Add your company-specific overrides in `nix/hosts/work-mac/`:

```
nix/hosts/work-mac/
├── configuration.nix    # Base (from upstream)
├── home.nix             # Base (from upstream)
├── work.nix             # Your system overrides
└── work-home.nix        # Your user overrides
```

#### Example `work.nix` (system-level)

```nix
{ pkgs, lib, ... }:
{
  # Override hostname
  networking.computerName = "My Work MacBook";
  networking.hostName = "work-macbook-123";

  # Company VPN
  services.tailscale.enable = true;

  # Work-required Homebrew apps
  homebrew.casks = lib.mkForce [
    "slack"
    "zoom"
    "docker"
    "1password"
  ];

  # Company-specific system packages
  environment.systemPackages = with pkgs; [
    # Add work tools here
  ];
}
```

#### Example `work-home.nix` (user-level)

```nix
{ pkgs, lib, ... }:
{
  # Work git configuration
  programs.git = {
    userEmail = lib.mkForce "you@company.com";
    userName = lib.mkForce "Your Name";
    extraConfig = {
      url."git@work-github.com:" = {
        insteadOf = "https://work-github.com/";
      };
      user.signingkey = "WORK_GPG_KEY_ID";
      commit.gpgsign = true;
    };
  };

  # Work SSH configuration
  programs.ssh.matchBlocks = {
    "work-*" = {
      user = "your-username";
      forwardAgent = true;
    };
    "work-bastion" = {
      hostname = "bastion.company.com";
      user = "your-username";
    };
  };

  # Work packages
  home.packages = with pkgs; [
    awscli2
    kubectl
    k9s
    terraform
  ];

  # Work aliases
  programs.zsh.shellAliases = {
    kdev = "kubectl --context=dev-cluster";
    vpn = "tailscale up --accept-routes";
  };

  # Enable work tools
  hmFoundry.features = {
    isAWS = true;
    isKubernetes = true;
    isTerraform = true;
    isDocker = true;
  };
}
```

### 4. Build and Switch

The flake already includes the `darwinConfigurations.work-mac` configuration, so just build and switch:

```bash
# Build (first time)
nix build .#darwinConfigurations.work-mac.system

# Apply
./result/sw/bin/darwin-rebuild switch --flake .#work-mac

# Subsequent updates
darwin-rebuild switch --flake .#work-mac
```

## WSL Work Fork Setup

For a WSL environment that only needs home-manager configuration:

### 1. Fork and Clone

Same as macOS setup above.

### 2. Understanding the Base Configuration

The upstream repository includes a base configuration in `nix/hosts/work-wsl/`:

- `home.nix` - Home-manager configuration with WSL-specific settings

It uses **conditional imports** to load work-specific overrides:

```nix
imports = [ ../../profiles/workstation.nix ]
  ++ lib.optional (builtins.pathExists ./work-home.nix) ./work-home.nix;
```

This means:

- ✅ Upstream base config flows through rebases automatically
- ✅ You only maintain **your deltas** in `work-home.nix`
- ✅ No flake.nix modifications needed (it already has `homeConfigurations."kyle@work-wsl"`)

### 3. Create Work-Specific File

Add your company-specific overrides in `nix/hosts/work-wsl/`:

```
nix/hosts/work-wsl/
├── home.nix       # Base (from upstream)
└── work-home.nix  # Your overrides
```

#### Example `work-home.nix`

```nix
{ pkgs, lib, ... }:
{
  # Work packages
  home.packages = with pkgs; [
    awscli2
    azure-cli
    kubectl
    terraform
    docker-compose
  ];

  # Work git configuration
  programs.git = {
    userEmail = lib.mkForce "you@company.com";
    userName = lib.mkForce "Your Name";
    extraConfig = {
      core.autocrlf = "input";
      core.credentialStore = "wincredman";  # Windows credential manager
      user.signingkey = "WORK_GPG_KEY_ID";
      commit.gpgsign = true;
    };
  };

  # Work SSH configuration
  programs.ssh.matchBlocks = {
    "work-*" = {
      user = "your-username";
      forwardAgent = true;
      identityFile = "/mnt/c/Users/YourUser/.ssh/work_id_rsa";
    };
    "work-bastion" = {
      hostname = "bastion.company.com";
      user = "your-username";
    };
  };

  # Work-specific shell configuration
  programs.zsh.shellAliases = {
    docker = "docker.exe";  # Use Windows Docker Desktop
    kdev = "kubectl --context=dev";
    vpn-check = "ping -c 1 internal.company.com";
  };

  programs.zsh.sessionVariables = {
    WORK_ENV = "wsl";
    DEFAULT_AWS_PROFILE = "company-dev";
  };

  # Enable work tools
  hmFoundry.features = {
    isAWS = true;
    isKubernetes = true;
    isDocker = true;
  };
}
```

### 4. Build and Switch

The flake already includes the `homeConfigurations."kyle@work-wsl"` configuration:

```bash
# Build and activate
home-manager switch --flake .#kyle@work-wsl
```

## Rebasing from Upstream

To incorporate changes from the public dotfiles repository:

### 1. Fetch Upstream Changes

```bash
git fetch upstream main
```

### 2. Rebase Your Work Branch

```bash
git rebase upstream/main
```

### 3. Resolve Conflicts

Conflicts should be minimal and typically only in `flake.nix`. Your work-specific files in `nix/work/` or `nix/work-wsl-home.nix` should never conflict.

Common conflict resolution:

- **flake.nix**: Keep both your `darwinConfigurations`/`homeConfigurations` additions and upstream changes
- **Feature additions**: New features added upstream won't affect your work files

### 4. Test and Push

```bash
# Test the configuration
darwin-rebuild build --flake .#work-mac  # macOS
# or
home-manager build --flake .#kyle@work-wsl  # WSL

# If successful, push to your work fork
git push --force-with-lease origin main
```

## Best Practices

### 1. Keep Work Changes Isolated

- Never modify core modules directly
- Use separate files for all work-specific configuration
- Prefer extending over replacing

### 2. Use Override Mechanisms

```nix
# Force a specific value (highest priority)
programs.git.userEmail = lib.mkForce "work@company.com";

# Set a default (can be overridden)
programs.tmux.terminal = lib.mkDefault "screen-256color";

# Merge with existing config
programs.zsh.shellAliases = lib.mkMerge [
  (config.programs.zsh.shellAliases or {})
  { work = "cd ~/work"; }
];
```

### 3. Document Work-Specific Changes

Keep a `WORK-CHANGES.md` in your work fork documenting:

- What work-specific tools are added
- Any security requirements implemented
- Special configuration needed for work services

### 4. Separate Secrets Management

- Never commit work secrets to the repository
- Use `sops-nix` or similar for encrypted secrets
- Consider using separate secret files:

```nix
sops.secrets.work-aws-credentials = {
  sopsFile = ./work-secrets.yaml;
};
```

### 5. Regular Rebasing

- Rebase frequently (weekly/monthly) to avoid large conflicts
- Test thoroughly after each rebase
- Keep work changes minimal to reduce rebase complexity

## Troubleshooting

### Common Issues

**Q: Conflicts in flake.nix during rebase**
A: This is expected. Usually you just need to keep both your additions and upstream changes. The structure is designed to minimize conflicts.

**Q: New upstream features aren't working**
A: Check if new modules were added to `hmCoreModules` or `hmDesktopModules`. You may need to update your `sharedModules` reference in your work configuration.

**Q: Work-specific package conflicts with upstream**
A: Use `lib.mkForce` to ensure your work version takes precedence:

```nix
home.packages = lib.mkForce (with pkgs; [
  your-work-version-of-package
]);
```

## Alternative Approaches

### Git Subtree (Not Recommended)

While possible, using git subtree adds complexity without significant benefits for this use case.

### Separate Work Module Repository

You could maintain work modules in a completely separate repository and import them:

```nix
let
  work-modules = builtins.fetchGit {
    url = "git@work-github.com:yourname/work-nix-modules.git";
    ref = "main";
  };
in
{
  imports = [
    ./profiles/workstation.nix
    "${work-modules}/work-config.nix"
  ];
}
```

This adds complexity but provides complete separation if required by company policies.

## Security Considerations

1. **Never commit secrets** - Use sops-nix or similar
2. **Review rebase changes** - Ensure no work data leaks upstream
3. **Separate SSH keys** - Use different keys for work/personal
4. **Git config conditional includes** - Consider using:

```gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
```

## Questions?

If you need help with specific work fork scenarios, consider:

1. Creating an issue in the upstream repo (without work details)
2. Consulting the Nix community for advanced override patterns
3. Reviewing the NixOS manual section on overlays and overrides

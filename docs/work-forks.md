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

### 2. Create Work-Specific Files

Create the following structure:

```
nix/
└── work/
    ├── darwin-system.nix    # nix-darwin system configuration
    └── darwin-home.nix      # home-manager user configuration
```

#### Example `nix/work/darwin-system.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  # Work-specific system configuration
  networking.computerName = "work-macbook";
  networking.hostName = "work-macbook";

  # Company-required security settings
  security.pam.enableSudoTouchIdAuth = true;

  # Work-specific services
  services.tailscale.enable = true;  # Company VPN

  # System packages needed for work
  environment.systemPackages = with pkgs; [
    # Company tools
  ];

  # Homebrew for work-specific apps that aren't in nixpkgs
  homebrew = {
    enable = true;
    casks = [
      "slack"
      "zoom"
      # Other work apps
    ];
  };
}
```

#### Example `nix/work/darwin-home.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  # Import the base workstation profile
  imports = [ ../profiles/workstation.nix ];

  # Work-specific packages
  home.packages = with pkgs; [
    awscli2
    kubectl
    # Company-specific tools
  ];

  # Override git configuration for work
  programs.git = {
    userEmail = lib.mkForce "you@company.com";
    extraConfig = {
      url."git@work-github.com:" = {
        insteadOf = "https://work-github.com/";
      };
    };
  };

  # Work-specific shell aliases
  programs.zsh.shellAliases = {
    kc = "kubectl --context=work-cluster";
    vpn = "tailscale up --accept-routes";
  };

  # Work-specific environment variables
  home.sessionVariables = {
    WORK_ENV = "true";
    DEFAULT_AWS_PROFILE = "work-profile";
  };

  # Enable work-relevant features
  hmFoundry.features = {
    isAWS = true;
    isKubernetes = true;
    isTerraform = true;
    isDocker = true;
  };
}
```

### 3. Modify flake.nix

Add the `darwinConfigurations` section (which doesn't exist in the base repo):

```nix
# At the end of outputs, after nixosConfigurations
darwinConfigurations = {
  work-mac = inputs.nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";  # or "x86_64-darwin" for Intel
    modules = [
      ./nix/work/darwin-system.nix
      inputs.home-manager.darwinModules.home-manager
      {
        nixpkgs.overlays = overlays;  # Reuse base overlays
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          sharedModules = hmCoreModules ++ hmDesktopModules;
          users.kyle = import ./nix/work/darwin-home.nix;
        };
      }
    ];
  };
};
```

### 4. Build and Switch

```bash
# First time setup
nix build .#darwinConfigurations.work-mac.system
./result/sw/bin/darwin-rebuild switch --flake .#work-mac

# Subsequent updates
darwin-rebuild switch --flake .#work-mac
```

## WSL Work Fork Setup

For a WSL environment that only needs home-manager configuration:

### 1. Fork and Clone

Same as macOS setup above.

### 2. Create Work-Specific File

Create a single file for WSL home configuration:

```
nix/
└── work-wsl-home.nix
```

#### Example `nix/work-wsl-home.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  # Import the base workstation profile
  imports = [ ./profiles/workstation.nix ];

  # WSL-specific work packages
  home.packages = with pkgs; [
    wslu  # WSL utilities
    # Work tools
  ];

  # Work git config
  programs.git = {
    userEmail = lib.mkForce "you@company.com";
  };

  # WSL-specific settings
  home.sessionVariables = {
    BROWSER = "wslview";  # Use Windows browser
  };

  # WSL often needs different SSH config
  programs.ssh = {
    extraConfig = ''
      # Use Windows ssh-agent
      Host *
        ForwardAgent yes
    '';
  };
}
```

### 3. Modify flake.nix

Add `homeConfigurations` for standalone home-manager:

```nix
# After nixosConfigurations
homeConfigurations = {
  "kyle@work-wsl" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    modules = [
      ./nix/work-wsl-home.nix
      {
        nixpkgs.overlays = overlays;
      }
    ];
  };
};
```

### 4. Build and Switch

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

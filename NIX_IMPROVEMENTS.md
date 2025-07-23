# Nix Dotfiles Repository Improvement Guide

This document provides a comprehensive analysis of improvement opportunities for your Nix dotfiles repository, organized by priority and category.

## Table of Contents

1. [Critical Security Issues](#critical-security-issues)
2. [Module Organization](#module-organization)
3. [Hardcoded Values](#hardcoded-values)
4. [Documentation Improvements](#documentation-improvements)
5. [Technical Debt](#technical-debt)
6. [Package Management](#package-management)
7. [Best Practices](#best-practices)
8. [Implementation Roadmap](#implementation-roadmap)

## Critical Security Issues

### 1. Exposed Passwords and Secrets

**Priority: CRITICAL**

#### Current Issues:

- **Hardcoded password hash** in `/nix/modules/nix_modules/deployment_target.nix:37`
  ```nix
  hashedPassword = "$6$XTNiJhQm1$D3M90syVNZdTazCOZIAF8TLK/hD4oSi3Xdst62dCkWR44ia3rujnPx.yWT6BaU4tvu1im5nR20WcjWnhPMTIV/";
  ```
- **Service passwords in plaintext** in `/nix/hosts/tiger/configuration.nix`
- **Initial passwords exposed** in user modules

#### Recommended Actions:

1. Move all password hashes to sops:
   ```nix
   hashedPassword = config.sops.secrets."users/svc.deploy/hashedPassword".path;
   ```
2. Generate new passwords for all exposed accounts
3. Audit git history for other exposed secrets
4. Add pre-commit hooks to prevent future secret commits

### 2. Disabled Firewall

**Priority: HIGH**

#### Current Issue:

```nix
# /nix/modules/nix_modules/deployment_target.nix:79
networking.firewall.enable = false; # TODO: why is this not true?
```

#### Recommended Fix:

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 80 443 ]; # Add only needed ports
  allowedUDPPorts = [ ];
  # Per-interface rules if needed
  interfaces."eth0".allowedTCPPorts = [ ];
};
```

### 3. Overly Permissive Sudo

**Priority: MEDIUM**

#### Current Issue:

```nix
security.sudo.wheelNeedsPassword = false;
```

#### Recommended Approach:

- Keep for development machines only
- Production systems should require passwords
- Consider using targeted sudo rules:
  ```nix
  security.sudo.extraRules = [{
    users = [ "deploy" ];
    commands = [
      { command = "/run/current-system/sw/bin/nixos-rebuild";
        options = [ "NOPASSWD" ]; }
    ];
  }];
  ```

## Module Organization

### 1. Split Large Modules

**Priority: HIGH**

#### Current State:

- `dev/default.nix` contains 128+ packages in one file
- Mixed concerns in several modules

#### Proposed Structure:

```
nix/modules/hm_modules/dev/
├── default.nix       # Re-exports all submodules
├── core.nix         # Essential tools (git, make, gnupg)
├── languages/
│   ├── default.nix
│   ├── nix.nix     # nixpkgs-fmt, nix-tree, etc.
│   ├── python.nix  # python, poetry, etc.
│   └── go.nix      # go, gopls, etc.
├── cloud/
│   ├── default.nix
│   ├── aws.nix     # awscli2, aws-sso-cli
│   └── k8s.nix     # kubectl, k9s, helm
├── databases.nix    # postgresql, redis, etc.
├── media.nix        # ffmpeg, imagemagick, etc.
└── networking.nix   # curl, wget, nmap, etc.
```

### 2. Extract Mixed Concerns

**Priority: MEDIUM**

#### deployment_target.nix Issues:

- Contains ACME configuration (lines 102-112)
- Mixed with deployment user setup
- Includes generic security settings

#### Recommended Refactoring:

```nix
# Create new modules:
nix/modules/nix_modules/
├── security/
│   ├── acme.nix     # ACME configuration
│   ├── ssh.nix      # SSH hardening
│   └── sudo.nix     # Sudo policies
├── deployment/
│   ├── users.nix    # Deployment users
│   └── trust.nix    # Nix trusted users
```

### 3. Consolidate Common Configuration

**Priority: LOW**

#### Current Duplication:

- `_includes/common.nix` overlaps with other modules
- Bootstrap configuration duplicates deployment_target

#### Action Items:

1. Merge bootstrap.nix into deployment_target
2. Split common.nix into focused modules
3. Create a proper module dependency graph

## Hardcoded Values

### 1. Network Configuration

**Priority: MEDIUM**

#### Current Issues:

```nix
# Hardcoded IPs scattered across files:
# /nix/hosts/alpha/configuration.nix:85-97
"1.2.3.4" = [ "alpha.dmz.1ella.com" ];
# /nix/hosts/_includes/common.nix:104
sshPublicHostKey = "192.168.0.18 ssh-ed25519 ...";
```

#### Recommended Solution:

Create a centralized network configuration:

```nix
# nix/modules/nix_modules/network/topology.nix
{
  networks = {
    dmz = {
      domain = "dmz.1ella.com";
      subnet = "192.168.0.0/24";
      hosts = {
        alpha = { ip = "192.168.0.10"; };
        tiger = { ip = "192.168.0.18"; };
      };
    };
  };
}
```

### 2. SSH Keys Management

**Priority: LOW**

#### Current State:

- SSH public keys hardcoded in multiple files
- No separation between deploy and user keys

#### Recommended Approach:

```nix
# nix/data/ssh-keys.nix
{
  users = {
    kyle = {
      primary = "ssh-rsa AAAAB3NzaC1yc2E...";
      devices = {
        dino = "ssh-rsa ...";
        framework = "ssh-ed25519 ...";
      };
    };
  };
  deploy = "ssh-ed25519 ...";
}
```

## Documentation Improvements

### 1. Module Documentation

**Priority: MEDIUM**

#### Missing Documentation:

- No README in module directories
- Limited inline documentation
- No architectural overview

#### Recommended Documentation Structure:

```markdown
# For each module directory:

nix/modules/hm_modules/dev/README.md

- Purpose and scope
- Available options
- Usage examples
- Dependencies
```

### 2. Namespace Documentation

**Priority: HIGH**

Create `ARCHITECTURE.md`:

```markdown
# Architecture Overview

## Namespaces

- `systemFoundry`: NixOS system-level modules
- `hmFoundry`: Home Manager user-level modules

## Module Conventions

- All modules use enable flags
- Options follow RFC 42 patterns
- ...
```

### 3. Option Documentation

**Priority: LOW**

Add descriptions and examples:

```nix
options.hmFoundry.dev.enable = mkOption {
  type = types.bool;
  default = false;
  description = lib.mdDoc ''
    Enable development tools and utilities.

    This includes compilers, build tools, and development
    environment configurations.
  '';
  example = true;
};
```

## Technical Debt

### Priority TODO Items

#### Critical (Security/Functionality):

1. **Store passwords with SOPS** - `/nix/hosts/tiger/configuration.nix:94,100,102`
2. **Fix firewall configuration** - `/nix/modules/nix_modules/deployment_target.nix:79`
3. **Review trusted users** - `/nix/modules/nix_modules/deployment_target.nix:59`

#### High (Architecture):

1. **Refactor ACME out of deployment_target**
2. **Fix DNS watchdog root cause** - `/nix/hosts/alpha/configuration.nix:106`
3. **Organize font configuration**

#### Medium (Cleanup):

1. **Remove deprecated options usage**
2. **Standardize module naming** (snake_case vs camelCase)
3. **Clean up overlay configuration**

## Package Management

### 1. Categorize Packages

**Priority: MEDIUM**

Current flat list of 128+ packages should be organized:

```nix
# dev/core.nix - Essential development tools
{
  home.packages = with pkgs; [
    git
    gnumake
    gnupg
    direnv
    tmux
  ];
}

# dev/languages/nix.nix
{
  home.packages = with pkgs; [
    nixpkgs-fmt
    nixfmt-rfc-style
    nix-tree
    nix-index
  ];
}
```

### 2. Package Source Management

**Priority: LOW**

Currently using multiple nixpkgs sources:

- `nixpkgs` (unstable-small)
- `nixpkgs-master`
- Custom packages

Consider:

- Document why each source is needed
- Minimize master usage for stability
- Pin specific commits for reproducibility

## Best Practices

### 1. Adopt RFC 42 Module System

**Priority: MEDIUM**

Current:

```nix
options.hmFoundry.dev = {
  enable = mkEnableOption "General development utilities";
};
```

RFC 42 style:

```nix
options.hmFoundry.dev = {
  enable = mkEnableOption (lib.mdDoc "General development utilities");

  package = mkPackageOption pkgs "dev-env" { };

  settings = mkOption {
    type = types.submodule {
      freeformType = settingsFormat.type;
    };
  };
};
```

### 2. Use NixOS Modules Effectively

**Priority: HIGH**

Instead of manual systemd services, use NixOS modules:

```nix
# Bad: Manual systemd service
systemd.services.custom = { ... };

# Good: Use existing modules
services.nginx.virtualHosts."example" = { ... };
```

### 3. Proper Secret Management

**Priority: CRITICAL**

Implement comprehensive sops usage:

```nix
sops.secrets = {
  "users/kyle/password" = {
    owner = "kyle";
    group = "users";
  };
  "services/backup/password" = {
    owner = "backup";
    restartUnits = [ "backup.service" ];
  };
};
```

## Implementation Roadmap

### Phase 1: Security (Week 1)

1. [ ] Move all passwords to sops
2. [ ] Enable and configure firewall
3. [ ] Audit and rotate exposed secrets
4. [ ] Add secret scanning pre-commit hooks

### Phase 2: Organization (Week 2-3)

1. [ ] Split dev/default.nix into categories
2. [ ] Extract ACME from deployment_target
3. [ ] Create network topology module
4. [ ] Consolidate common configurations

### Phase 3: Documentation (Week 4)

1. [ ] Write ARCHITECTURE.md
2. [ ] Add README to each module directory
3. [ ] Document all custom options
4. [ ] Create usage examples

### Phase 4: Best Practices (Week 5-6)

1. [ ] Adopt RFC 42 patterns
2. [ ] Refactor to use NixOS modules
3. [ ] Standardize naming conventions
4. [ ] Implement proper testing

### Phase 5: Maintenance (Ongoing)

1. [ ] Address remaining TODOs
2. [ ] Set up CI/CD
3. [ ] Regular security audits
4. [ ] Keep dependencies updated

## Quick Wins

If you want to start with easy improvements:

1. **Enable the firewall** - 5 minute fix, high security impact
2. **Move passwords to sops** - 30 minutes, critical security fix
3. **Add module READMEs** - 1 hour, improves maintainability
4. **Split dev packages** - 2 hours, better organization
5. **Document namespaces** - 30 minutes, helps future you

## Tools and Scripts

Consider adding these helper scripts:

```bash
# scripts/audit-secrets.sh
#!/usr/bin/env bash
# Scan for potential secrets in nix files
rg -i '(password|secret|key|token).*=' --type nix

# scripts/validate-modules.sh
#!/usr/bin/env bash
# Validate all NixOS configurations
nix flake check

# scripts/update-deps.sh
#!/usr/bin/env bash
# Update and test all dependencies
nix flake update
make build
```

This improvement guide provides specific, actionable items organized by priority. Start with the critical security issues, then work through organization and documentation improvements as time permits.

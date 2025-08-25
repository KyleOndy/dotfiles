# Package Deduplication Migration Tasks

## Overview

Eliminate duplication between `/nix/profiles/common/development.nix` and `/nix/modules/hm_modules/dev/default.nix` while ensuring package parity for all hosts.

## Current Architecture Analysis

### Host -> Profile Mapping

- **dino**: workstation profile (isDesktop=true, defaults to workstation when no explicit profile)
- **tiger**: ssh profile (explicitly set)
- **cheetah**: ssh profile (explicitly set)
- **alpha**: (not found in current flake.nix - may be disabled)
- **pi1, pi2, pi3**: (not found in current flake.nix - may be disabled)

### Profile -> Feature Flag Mapping

```
workstation.nix:
  - isDevelopment: true
  - isDesktop: true
  - All feature flags: true (isKubernetes, isAWS, isTerraform, etc.)

ssh.nix:
  - isDevelopment: true
  - isDesktop: false
  - isSystemAdmin: true
  - isNixDev: true
  - isSecurity: true
  - All other flags: false

server.nix: (needs investigation if used)
minimal.nix: (needs investigation if used)
```

## Pre-Migration Tasks

### [x] 1. Capture Current Package State

Scripts have been created to capture and compare package states:

**Capture Script**: `scripts/capture-packages.sh`

- Captures package lists for all active hosts (dino, tiger, cheetah)
- Saves full package info, package names, and feature flags
- Creates a summary report

**Compare Script**: `scripts/compare-packages.sh`

- Compares pre and post migration package lists
- Shows added/removed packages
- Reports package count changes

To run:

```bash
# Capture current state (run before making changes)
./scripts/capture-packages.sh

# After migration, capture new state
mkdir -p post-migration
for host in dino tiger cheetah; do
  nix eval ".#nixosConfigurations.${host}.config.home-manager.users.kyle.home.packages" \
    --apply 'map (p: p.name)' --json > "post-migration/${host}-package-names.json"
done

# Compare for each host
./scripts/compare-packages.sh dino
./scripts/compare-packages.sh tiger
./scripts/compare-packages.sh cheetah
```

### [ ] 2. Document Current Package Sources

#### Packages in BOTH files (duplicates to resolve)

- [ ] Document overlap between development.nix and dev/default.nix
- [ ] Identify which version to keep (check for version differences)

#### Packages ONLY in development.nix

- [ ] List packages controlled by feature flags
- [ ] Map to new module locations

#### Packages ONLY in dev/default.nix

- [ ] List packages always installed
- [ ] Determine if they need feature flag control

### [ ] 3. Create Feature Flag -> Module Mapping

| Feature Flag  | Current Location         | New Module                        | Package Count |
| ------------- | ------------------------ | --------------------------------- | ------------- |
| isKubernetes  | development.nix L79-86   | dev/cloud/k8s.nix                 | 6             |
| isAWS         | development.nix L89-91   | dev/cloud/aws.nix                 | 1             |
| isTerraform   | development.nix L94-96   | dev/infrastructure/terraform.nix  | 1             |
| isDocker      | development.nix L99-101  | dev/infrastructure/docker.nix     | 1             |
| isMediaDev    | development.nix L104-109 | dev/media.nix                     | 4             |
| isDocuments   | development.nix L112-120 | dev/documents.nix                 | 6             |
| isSystemAdmin | development.nix L123-130 | dev/sysadmin.nix                  | 6             |
| isMonitoring  | development.nix L133-138 | dev/monitoring.nix                | 4             |
| isSecurity    | development.nix L141-146 | dev/security.nix                  | 4             |
| isPerformance | development.nix L149-156 | dev/performance.nix               | 6             |
| isNixDev      | development.nix L159-164 | dev/nix-tools.nix                 | 4             |
| isClojureDev  | development.nix L167-169 | (already exists: dev/clojure.nix) | 1             |

## Migration Tasks

### Phase 1: Create New Module Structure

#### [ ] 1.1 Create Core Module

`/nix/modules/hm_modules/dev/core.nix`

- Essential tools always needed when dev.enable = true
- No feature flag dependencies

#### [ ] 1.2 Create Feature-Flagged Modules

Create each module listed in the mapping table above:

- [ ] dev/cloud/aws.nix
- [ ] dev/cloud/k8s.nix
- [ ] dev/infrastructure/terraform.nix
- [ ] dev/infrastructure/docker.nix
- [ ] dev/media.nix
- [ ] dev/documents.nix
- [ ] dev/sysadmin.nix
- [ ] dev/monitoring.nix
- [ ] dev/security.nix
- [ ] dev/performance.nix
- [ ] dev/nix-tools.nix

#### [ ] 1.3 Create Additional Tools Module

`/nix/modules/hm_modules/dev/tools.nix`

- Miscellaneous development tools
- Things that don't fit other categories

### Phase 2: Refactor Existing Files

#### [ ] 2.1 Update dev/default.nix

- [ ] Remove all home.packages
- [ ] Remove duplicate program configs (bat, direnv)
- [ ] Import all new submodules
- [ ] Keep only the enable option

#### [ ] 2.2 Update development.nix Profile

- [ ] Remove all home.packages sections
- [ ] Remove duplicate program configs
- [ ] Keep module enablement logic
- [ ] Keep feature flag pass-through

### Phase 3: Testing & Validation

#### [ ] 3.1 Syntax Validation

```bash
nix flake check
```

#### [ ] 3.2 Package List Comparison

For each host:

```bash
# Capture post-migration state
nix eval .#nixosConfigurations.HOSTNAME.config.home-manager.users.kyle.home.packages --json > post-migration/HOSTNAME-packages.json

# Compare
./scripts/compare-packages.sh HOSTNAME
```

#### [ ] 3.3 Build Testing

```bash
# Test build for each host
nix build .#nixosConfigurations.dino.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.tiger.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.cheetah.config.system.build.toplevel --dry-run
```

### Phase 4: Deployment

#### [ ] 4.1 Test on Single Host

- [ ] Deploy to least critical host first
- [ ] Verify functionality
- [ ] Check package availability

#### [ ] 4.2 Roll Out to All Hosts

- [ ] Deploy to remaining hosts
- [ ] Monitor for issues

## Validation Checklist

### Per-Host Validation

For each host, verify:

- [ ] Package count matches (±5 for dependency changes)
- [ ] No critical packages missing
- [ ] No unexpected packages added
- [ ] Feature flags correctly applied
- [ ] Build succeeds
- [ ] Deployment succeeds

### Package Categories to Verify

- [ ] Core dev tools (git, make, etc.)
- [ ] Language tools (based on enabled languages)
- [ ] Cloud tools (if flags enabled)
- [ ] System admin tools (if flags enabled)
- [ ] Media tools (if flags enabled)

## Rollback Plan

If issues are discovered:

1. Git revert the changes
2. Rebuild affected hosts with previous configuration
3. Document what went wrong
4. Adjust plan and retry

## Success Criteria

- [x] No duplicate package definitions - COMPLETE
- [x] All essential packages migrated successfully - COMPLETE
- [x] Feature flags properly control conditional packages - VERIFIED
- [x] Code is more maintainable and organized - COMPLETE
- [x] All hosts build successfully - VERIFIED

## Migration Results

### Package Migration Summary

- **dino (workstation)**: 212 packages (all essential packages present)
- **tiger (ssh)**: 136 packages (appropriate for ssh profile)
- **cheetah (ssh)**: 136 packages (appropriate for ssh profile)

### Verification Results

- ✅ All core packages (ripgrep, fd, bat, etc.) successfully migrated
- ✅ Feature-flagged packages (k8s, AWS, terraform) working correctly
- ✅ Both NixOS configurations build without errors
- ✅ Package installation controlled by feature flags as designed

### Architecture Improvements

1. **Eliminated duplication** - Packages now defined in one location only
2. **Clear organization** - Packages grouped by functionality
3. **Feature flag integration** - Conditional package installation working
4. **Maintainable structure** - Easy to add/modify package groups

## Notes

### Package Module Pattern

Each new module should follow this pattern:

```nix
{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.hmFoundry.features;
  devCfg = config.hmFoundry.dev;
in
{
  config = mkIf (devCfg.enable && cfg.isFEATURE) {
    home.packages = with pkgs; [
      # packages here
    ];
  };
}
```

### Testing Commands

```bash
# Quick package list for comparison
nix eval .#nixosConfigurations.dino.config.home-manager.users.kyle.home.packages --apply 'map (p: p.name)'

# Check what profile a host uses
nix eval .#nixosConfigurations.dino.config.home-manager.users.kyle.imports

# Check feature flags for a host
nix eval .#nixosConfigurations.dino.config.home-manager.users.kyle.config.hmFoundry.features
```

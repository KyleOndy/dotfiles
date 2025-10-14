# git-worktree-prompt

Fast git prompt with worktree support for Starship.

## Overview

A pure Rust implementation that displays git branch and worktree information for shell prompts. Optimized for <2ms execution time with zero production dependencies.

**Status:** This package is **internal to the dotfiles repository**. It's consumed via the overlay system and integrated into NixOS/Home Manager configurations.

## Architecture

### Package Integration

This package is made available through the overlay in `nix/pkgs/default.nix`:

```nix
git-worktree-prompt = super.callPackage ./git-worktree-prompt { };
```

The overlay is applied to all NixOS configurations in the root `flake.nix`, making `pkgs.git-worktree-prompt` available throughout the system.

### Consumption

Used in Home Manager configurations:

```nix
home.packages = [ pkgs.git-worktree-prompt ];
```

Or referenced directly in Starship configuration:

```nix
custom.git_worktree = {
  command = "git-worktree-prompt";
  format = "on [$output]($style)";
};
```

## Development

### Recommended: Package Build

Build just the package using the flake's pinned nixpkgs (fast, reproducible):

```bash
# From repository root
cd ~/src/dotfiles

# Build the package (20-30s, uses flake's pinned nixpkgs)
nix build .#git-worktree-prompt

# Test the binary (creates ./result symlink at repo root)
./result/bin/git-worktree-prompt

# Benchmark with hyperfine
nix-shell -p hyperfine --run "hyperfine --warmup 10 --shell=none './result/bin/git-worktree-prompt'"
```

**Why this is recommended:**

- ✅ Uses flake's pinned nixpkgs (no drift)
- ✅ Fast builds (20-30s, not minutes)
- ✅ Perfect for package-level testing and benchmarking
- ✅ Result at convenient root location

### Quick Iteration

For rapid prototyping during active development:

```bash
cd nix/pkgs/git-worktree-prompt

# Build (fast, debug mode)
cargo build

# Run tests
cargo test

# Build optimized binary
cargo build --release

# Test the binary
./target/release/git-worktree-prompt
```

**⚠️ Warning:** Cargo may use a different Rust toolchain version than Nix builds. Always verify with `nix build .#git-worktree-prompt` before considering work complete.

### System Integration Testing

Test within the complete system context where the package will be deployed:

```bash
# From repository root
cd ~/src/dotfiles

# Build full Home Manager configuration
home-manager build
./result/home-path/bin/git-worktree-prompt

# Or build entire NixOS system (takes minutes)
nixos-rebuild build
./result/sw/bin/git-worktree-prompt

# Or use the Makefile
make build
./result/sw/bin/git-worktree-prompt
```

**Use this for:**

- Pre-deployment verification
- Testing integration with Starship configuration
- Validating system-wide PATH availability

### Deployment

Deploy to running system for live testing:

```bash
# Test without activation
nixos-rebuild test  # or build-vm

# Full activation
home-manager switch
nixos-rebuild switch
```

After activation, `git-worktree-prompt` will be available in `$PATH`.

## Project Structure

```text
.
├── src/
│   └── main.rs          # Pure Rust implementation (~650 lines)
├── Cargo.toml           # Zero production dependencies
├── Cargo.lock           # Locked dependency versions
├── default.nix          # Nix package definition
└── README.md            # This file
```

### Key Features

- **Pure Rust:** Zero production dependencies (only stdlib)
- **Fast:** ~1.9ms execution time (meets <2ms target)
- **Small:** 435KB stripped binary
- **Optimized:** LTO enabled, single codegen unit, panic=abort
- **Tested:** 11 tests (4 unit, 7 integration)

### Build Configuration

Optimized release profile in `Cargo.toml`:

```toml
[profile.release]
lto = true           # Link-time optimization
codegen-units = 1    # Maximum optimization
strip = true         # Strip debug symbols
panic = "abort"      # Smaller binary, faster startup
```

## Testing

Tests run automatically during Nix builds:

```bash
# Runs during: home-manager build, nixos-rebuild build
# Or manually with:
cargo test

# With output:
cargo test -- --nocapture

# Specific test:
cargo test test_regular_repo_on_main
```

### Test Categories

- **Unit tests:** Path normalization, output formatting
- **Integration tests:** Real git repository operations, error logging

### Performance Benchmarking

Verify the <2ms performance target:

```bash
# From repository root
cd ~/src/dotfiles

# Build with flake's pinned nixpkgs
nix build .#git-worktree-prompt

# Benchmark with hyperfine (use nix-shell if not installed)
nix-shell -p hyperfine --run "hyperfine --warmup 10 --shell=none './result/bin/git-worktree-prompt'"

# Expected result: ~1.9ms ± 0.2ms
```

**Target:** <2ms execution time ✅

## Deployment

Changes are deployed by rebuilding system configurations:

```bash
# Home Manager only
home-manager switch

# Full system
nixos-rebuild switch

# Remote deployment (via deploy-rs)
deploy .#dino
```

## Troubleshooting

### Debug Mode

Run with `--debug` flag to see error messages:

```bash
git-worktree-prompt --debug
```

### Error Logs

Errors are logged to:

```text
$XDG_STATE_HOME/git-worktree-prompt/error.log
# Usually: ~/.local/state/git-worktree-prompt/error.log
```

### Build Issues

If Nix build fails:

```bash
# Check for syntax errors
nix-instantiate --parse default.nix

# Build with verbose output
home-manager build --show-trace
```

## Contributing

This is a personal dotfiles package. Changes should:

1. Maintain <2ms performance target
2. Keep zero production dependencies
3. Pass all tests (run via `cargo test`)
4. Work in both regular and worktree repositories
5. Be verified via system rebuild before committing

## License

MIT

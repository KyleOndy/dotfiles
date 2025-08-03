# Personal Development Infrastructure System

A comprehensive, declarative system for managing development environments, personal infrastructure, and configurations across multiple platforms and architectures.

This repository defines everything needed to bootstrap and maintain a complete development ecosystem - from individual developer workstations to production servers and homelab infrastructure.

## Features

### 🏗️ **Modular Architecture**

- **Custom namespace system** with `hmFoundry` (Home Manager) and `systemFoundry` (NixOS) modules
- **Profile-based configuration** for different roles (workstation, server, gaming, minimal)
- **Multi-platform support** for Linux (x86_64, ARM), macOS (Intel, Apple Silicon)
- **Sophisticated include system** for shared configurations

### 🤖 **AI-Assisted Development**

- **Claude Code integration** with intelligent hooks for linting, testing, and notifications
- **Multi-language development workflows** with automatic tool detection
- **Smart testing and linting** that adapts to project structure
- **Custom development guidelines** and automated code quality enforcement

### 🔧 **Advanced Tooling**

- **Babashka ecosystem** for custom scripting and automation
- **Custom package collection** including fonts, tools, and utilities
- **Infrastructure as Code** with Terraform for cloud resources
- **Comprehensive secrets management** with SOPS encryption

### 🌐 **Complete Infrastructure Management**

- **Multi-host deployment** with deploy-rs
- **Service orchestration** for media servers, monitoring, and development tools
- **Network topology management** with DNS and reverse proxy configuration
- **Security-first design** with proper firewall, SSH hardening, and secret handling

## Quick Start

### Prerequisites

1. **Install Nix** with flakes enabled:

   ```bash
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```

2. **Clone the repository**:

   ```bash
   git clone https://github.com/kyleondy/dotfiles.git ~/src/dotfiles
   cd ~/src/dotfiles
   ```

### Setup Paths

#### Development Workstation

```bash
# Enable flakes and direnv
nix-shell -p direnv
direnv allow

# Deploy full workstation configuration
make deploy
```

#### Server/Minimal Setup

```bash
# Deploy server profile (no desktop environment)
sudo nixos-rebuild switch --flake .#<hostname>
```

#### macOS Setup

```bash
# Install nix-darwin and deploy
nix run nix-darwin -- switch --flake .#<hostname>
```

### Post-Setup

1. **Clone password store** (if using pass):

   ```bash
   git clone git@github.com:kyleondy/password-store.git ~/.password-store
   ```

2. **Configure Claude Code** (optional):

   ```bash
   claude  # Initialize in any project directory
   ```

## Architecture

### Module Organization

```text
nix/modules/
├── hm_modules/           # Home Manager modules (user-level)
│   ├── dev/             # Development tools and environments
│   ├── desktop/         # Desktop applications and window managers
│   ├── shell/           # Shell configuration (zsh, bash)
│   └── terminal/        # Terminal tools and editors
└── nix_modules/         # NixOS modules (system-level)
    ├── security/        # Security configurations
    ├── services/        # System services
    └── users/           # User account management
```

### Profile System

- **`minimal`**: Base system with essential tools
- **`ssh`**: Minimal + SSH access for servers
- **`server`**: SSH + server services and monitoring
- **`workstation`**: Full development environment with desktop
- **`gaming`**: Workstation + gaming tools and optimizations

### Host Configuration

Each host in `nix/hosts/` defines:

- Hardware-specific configuration
- Service assignments and networking
- User profiles and role assignments
- Environment-specific overrides

## Development Philosophy

### Core Principles

> "Stop. The simple solution is usually correct."

- **Explicit over implicit**: Clear, readable configurations
- **Modular design**: Small, focused modules with single responsibilities
- **Security first**: Proper secrets management and hardening
- **Reproducible environments**: Deterministic builds across all platforms

### Quality Standards

- **Automated testing**: Comprehensive test coverage for infrastructure
- **Continuous validation**: Pre-commit hooks and CI/CD checks
- **Documentation**: Every module and configuration is documented
- **Maintainability**: Regular updates and dependency management

## Repository Structure

- **[bin/](./bin/)**: Management scripts and utilities
- **[docs/](./docs/)**: Detailed documentation and guides
- **[keyboard/](./keyboard/)**: QMK configuration for custom keyboards
- **[nix/](./nix/)**: Core Nix/NixOS configuration system
  - **[hosts/](./nix/hosts/)**: Per-host configurations
  - **[modules/](./nix/modules/)**: Reusable system and user modules
  - **[pkgs/](./nix/pkgs/)**: Custom package definitions
  - **[profiles/](./nix/profiles/)**: Role-based configuration profiles
- **[notes/](./notes/)**: Infrastructure documentation and planning
- **[tf/](./tf/)**: Terraform infrastructure definitions
- **[util/](./util/)**: Additional utilities and tools

## Available Commands

```bash
make help           # Show all available commands
make build          # Build configuration for current host
make deploy         # Deploy configuration to current host
make update         # Update all flake inputs
make check          # Run validation checks
make vm             # Build and run VM for testing
make cleanup        # Clean up old generations and optimize store
```

## Host Types and Roles

### Current Infrastructure

- **`dino`**: Development workstation (Framework laptop)

  - Full desktop environment with KDE
  - Complete development toolchain
  - Claude Code integration with notifications
  - Gaming and media capabilities

- **`tiger`**: Home server

  - Media services (Jellyfin, Sonarr, Radarr)
  - Binary cache and build services
  - Network storage and backup

- **`cheetah`**: Remote server
  - Lightweight services
  - Monitoring and alerting
  - External access point

## Advanced Configuration

### Custom Packages

The repository includes custom packages in `nix/pkgs/`:

- **Fonts**: Berkeley Mono, Pragmata Pro
- **Scripts**: Custom automation and utility scripts
- **Development tools**: Enhanced versions of standard tools
- **Babashka projects**: Structured Clojure scripting solutions

### Service Management

Services are configured declaratively:

```nix
# Example: Enable media server stack
systemFoundry = {
  services = {
    jellyfin.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
  };
};
```

### Development Environment

Development tools are organized by language and purpose:

```nix
# Example: Enable development environment
hmFoundry = {
  dev = {
    enable = true;
    python.enable = true;
    go.enable = true;
    claude-code = {
      enable = true;
      enableNotifications = true;
    };
  };
};
```

## Use Cases

### Multi-Node Scenarios

- **Laptop + Server**: Synchronized development environment with remote build capacity
- **Work + Personal**: Separate profiles with shared base configuration
- **VM Testing**: Quick environment spinning for testing configurations

### Multi-Architecture Support

- **x86_64-linux**: Primary development and server platform
- **aarch64-linux**: Raspberry Pi and ARM servers
- **x86_64-darwin**: Intel Mac support
- **aarch64-darwin**: Apple Silicon Mac support

## Security

- **Secrets management**: All sensitive data encrypted with SOPS
- **SSH hardening**: Key-only authentication with proper key management
- **Firewall configuration**: Minimal attack surface with required ports only
- **User privilege management**: Principle of least privilege across all systems

## Contributing

This is a personal infrastructure repository, but the patterns and modules may be useful as reference. Key areas of innovation include:

- Modular Nix configuration patterns
- Multi-platform consistency approaches
- Development workflow automation
- Infrastructure as Code practices

## Goals and Non-Goals

### Goals

- **Complete configuration**: Define everything that plugs into a wall
- **Learning platform**: Experiment with new technologies and approaches
- **Reproducible environments**: Consistent development experience everywhere
- **Security by default**: Proper secrets and access management

### Non-Goals

- **Reference architecture**: This prioritizes personal workflow over best practices
- **General reusability**: Optimized for specific use cases, not broad adoption
- **Stability guarantees**: Main branch may break as experimentation continues

## Roadmap

Current focus areas include:

- **Enhanced testing**: Automated testing for all configurations
- **Improved secrets**: Migration to more sophisticated secret management
- **Service expansion**: Additional homelab and development services
- **Documentation**: Comprehensive guides for all major components

## External Resources

Inspiration and reference materials:

- [Terje Larsen's (terlar) dotfiles](https://github.com/terlar/nix-config)
- [Utku Demir's (utdemir) dotfiles](https://github.com/utdemir/dotfiles)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)

---

_This repository represents years of iteration on development environment management. While primarily personal, the architectural patterns and automation approaches may provide useful reference for others building similar systems._

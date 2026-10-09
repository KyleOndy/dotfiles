UNAME := $(shell uname)
HOSTNAME=$(shell hostname -s)
ALLOW_BROKEN=false
ALLOW_UNSUPPORTED=false
ALLOW_UNFREE=false

# Captured at make-time so home-manager modules using mkOutOfStoreSymlink
# (currently: pi-coding-agent) symlink into the worktree you actually
# `make`d from, not a hardcoded path. Threaded into the flake via the
# DOTFILES_WORKTREE env var; consumed in flake.nix and read with
# builtins.getEnv. Empty when run outside a git worktree — the consuming
# module throws with a pointer back here.
export DOTFILES_WORKTREE := $(shell git rev-parse --show-toplevel 2>/dev/null)

# --impure unconditionally so the flake can read DOTFILES_WORKTREE. The
# ALLOW_* flags below still toggle their respective NIXPKGS_ALLOW_* env
# vars, but the --impure flag itself is always on.
IMPURE := --impure

# GC roots for builds no substituter serves, so a garbage collection on
# this machine does not force a rebuild. Each build replaces its own root.
DEPLOY_GC := $(HOME)/.local/state/deploy-rs/gcroots

# Lift this repo's core.sshCommand into GIT_SSH_COMMAND so Nix's git+ssh
# fetchers (e.g. the private cogsworth flake input) use the same key as
# git operations in this worktree. Repo-level core.sshCommand only
# applies when git is invoked from inside the repo; GIT_SSH_COMMAND
# applies anywhere git runs. Expand ~ here because it would otherwise
# resolve to /var/root once the value crosses sudo.
GIT_SSH_COMMAND := $(subst ~,$(HOME),$(shell git config --get core.sshCommand 2>/dev/null))
ifneq ($(GIT_SSH_COMMAND),)
  export GIT_SSH_COMMAND
endif

# Work config override. Set to the work config flake directory on work machines
# to inject work-specific configuration. That flake sits in the work repo's nix/
# subdirectory, not at its root. Example:
#   make build-mac WORK_CONFIG=/Users/kondy/work/nix
#   export WORK_CONFIG=/Users/kondy/work/nix && make deploy
WORK_CONFIG ?=
ifdef WORK_CONFIG
  WORK_INPUT_FLAG = --override-input work-config path:$(WORK_CONFIG)
endif

# I don't like to do this, but sometimes I just need to move ahead
ifeq ($(ALLOW_BROKEN), true)
	export NIXPKGS_ALLOW_BROKEN=1
endif

ifeq ($(ALLOW_UNSUPPORTED), true)
	export NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
endif

ifeq ($(ALLOW_UNFREE), true)
	export NIXPKGS_ALLOW_UNFREE=1
endif

# this is my naive approach to supporting multiple systems.
ifeq ($(UNAME), Linux)
	REBUILD := nixos-rebuild $(IMPURE)
	# --preserve-env so DOTFILES_WORKTREE (and NIXPKGS_ALLOW_*) survive sudo
	SWITCH := sudo --preserve-env=DOTFILES_WORKTREE,GIT_SSH_COMMAND,NIXPKGS_ALLOW_BROKEN,NIXPKGS_ALLOW_UNFREE,NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM $(REBUILD)
else ifeq ($(UNAME), Darwin)
	REBUILD := darwin-rebuild $(IMPURE)
	# darwin-rebuild requires root for activation. --preserve-env keeps
	# GIT_SSH_COMMAND so private flake inputs (e.g. ssh://git@github.com/...)
	# can still authenticate via the key configured in this repo's
	# core.sshCommand.
	SWITCH := sudo --preserve-env=DOTFILES_WORKTREE,GIT_SSH_COMMAND,NIXPKGS_ALLOW_BROKEN,NIXPKGS_ALLOW_UNFREE,NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM $(REBUILD)
else
  $(error Unsupported system: $(UNAME))
endif

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-26s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Buld single host
	$(REBUILD) --flake .#$(HOSTNAME) build --keep-going

.PHONY: deploy
deploy: ## Deploy currently defined configuration
	$(SWITCH) $(WORK_INPUT_FLAG) --flake .#$(HOSTNAME) switch

.PHONY: deploy-rs-gcroots
deploy-rs-gcroots:
	nix build $(IMPURE) --out-link $(DEPLOY_GC)/cogsworth-kernel \
	  .#nixosConfigurations.cogsworth.config.system.build.kernel \
	  .#nixosConfigurations.cogsworth.config.system.modulesTree

.PHONY: deploy-rs
deploy-rs: $(if $(filter cogsworth,$(HOSTNAME)),deploy-rs-gcroots)
	deploy .#$(HOSTNAME) -- $(IMPURE)

.PHONY: deploy-rs-all
deploy-rs-all: deploy-rs-gcroots
	nix flake check $(IMPURE) -L
	deploy --skip-checks . -- $(IMPURE)

.PHONY: deploy-rs-all-dry
deploy-rs-all-dry: deploy-rs-gcroots
	nix flake check $(IMPURE) -L
	deploy --skip-checks --dry-activate . -- $(IMPURE)

.PHONY: diff-system
diff-system: ## Print system diff without color
	@nix store diff-closures $(shell readlink -f /nix/var/nix/profiles/system) $(shell readlink -f ./result) |  sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g'

.PHONY: update
update: ## Update all flake soruces
	nix flake update

.PHONY: update/nixpkgs
update/nixpkgs: ## Updage just nixpkgs source
	nix flake update nixpkgs

.PHONY: update/nixpkgs-master
update/nixpkgs-master: ## Updage just nixpkgs-master source
	nix flake update nixpkgs-master

.PHONY: update/home-manager
update/home-manager: ## Update just home-manager source
	nix flake update home-manager

.PHONY: update/nur
update/nur: ## Update just the nur source
	nix flake update nur

.PHONY: update/claude-code
update/claude-code: ## Update just claude-code source
	nix flake update claude-code-nix

.PHONY: update/pi-coding-agent
update/pi-coding-agent: ## Update pi.dev coding agent (via numtide/llm-agents.nix)
	nix flake update llm-agents

.PHONY: check
check: ## Run nix checks
	nix flake check $(IMPURE)

.PHONY: info
info: ## Print information about the system
	@echo "Current generation's largest dependencies:"
	@du -shc $(shell nix-store -qR "$(shell realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: sdcard-cogsworth
sdcard-cogsworth: ## Build cogsworth SD card image with WiFi
	@echo "Decrypting SSH host key locally..."
	@export COGSWORTH_SSH_KEY=$$(sops -d nix/hosts/cogsworth/keys/ssh_host_ed25519_key.sops) && \
		echo "Building SD image (this takes a while)..." && \
		nix build --impure .#nixosConfigurations.cogsworth.config.system.build.sdImage && \
		echo "Done! Image at: result/sd-image/" || \
		(echo "Build failed"; exit 1)

# x86_64-linux, and trex has no local x86_64 builder, so this runs on tiger
# and copies ~1GB back.
.PHONY: iso-pika
iso-pika: ## Build pika's headless install and rescue ISO
	nix build $(IMPURE) .#nixosConfigurations.pika-installer.config.system.build.isoImage
	@echo "Done! Image at: result/iso/pika-installer.iso"

.PHONY: cleanup
cleanup: ## Cleanup and reduce diskspace of current system
	sudo nix-collect-garbage --delete-older-than 7d
	nix-collect-garbage --delete-older-than 7d
	sudo nix store optimise

# Cache push targets
# macOS-specific targets
.PHONY: build-mac
build-mac: ## Build work-mac darwin configuration (set WORK_CONFIG=/path/to/work for work config)
	nix build $(IMPURE) $(WORK_INPUT_FLAG) .#darwinConfigurations.work-mac.system

.PHONY: build-mac-dry
build-mac-dry: ## Dry-run build of work-mac darwin configuration
	nix build $(IMPURE) $(WORK_INPUT_FLAG) .#darwinConfigurations.work-mac.system --dry-run

.PHONY: deploy-mac
deploy-mac: ## Deploy work-mac darwin configuration (set WORK_CONFIG=/path/to/work for work config)
	$(SWITCH) $(WORK_INPUT_FLAG) --flake .#work-mac switch

.PHONY: build-trex
build-trex: ## Build trex darwin configuration
	nix build $(IMPURE) .#darwinConfigurations.trex.system

.PHONY: build-trex-dry
build-trex-dry: ## Dry-run build of trex darwin configuration
	nix build $(IMPURE) .#darwinConfigurations.trex.system --dry-run

.PHONY: deploy-trex
deploy-trex: ## Deploy trex darwin configuration
	$(SWITCH) --flake .#trex switch

.PHONY: flash-ergodox
flash-ergodox:
	nix run .#flash-ergodox

.PHONY: flash-pad
flash-pad: ## Flash the domestique push-to-talk pad
	nix run .#flash-pad

# Replaces the script Roundcube's Filters UI edits, so changes made there
# are lost on the next push. The server rejects a script that fails to
# parse, a still-encrypted git-crypt file included.
SIEVE_CONNECT = pass show email/kyle@ondy.org | head -1 | nix run --inputs-from . nixpkgs\#sieve-connect -- \
	--server london.mxroute.com --user kyle@ondy.org --passwordfd 0 --remotesieve managesieve

.PHONY: sieve-push
sieve-push: ## Upload and activate the ondy.org mail filters
	$(SIEVE_CONNECT) --localsieve mail/ondy.org.sieve --upload
	$(SIEVE_CONNECT) --activate

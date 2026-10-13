UNAME := $(shell uname)

# The machine make runs on. Used only where the machine itself matters --
# picking the local nix daemon's launchd label -- and as the last-resort
# default for HOST. On work-mac this is a company hostname that must never
# appear in this repo, which is why the host to deploy is its own variable.
MACHINE := $(shell hostname -s)

# The host to act on: the flake attr to build or switch, and the deploy-rs
# node to push to. The make command line wins, then DOTFILES_HOST (work-mac
# can export it from its own config, so the company name never has to be
# typed or committed here), then the machine you are on.
HOST ?= $(if $(DOTFILES_HOST),$(DOTFILES_HOST),$(MACHINE))
ALLOW_BROKEN ?= false
ALLOW_UNSUPPORTED ?= false
ALLOW_UNFREE ?= false

# Captured at make-time so home-manager modules using mkOutOfStoreSymlink
# (currently: alamode) symlink into the worktree you actually
# `make`d from, not a hardcoded path. Threaded into the flake via the
# DOTFILES_WORKTREE env var; consumed in flake.nix and read with
# builtins.getEnv. Empty when run outside a git worktree — the consuming
# module throws with a pointer back here.
export DOTFILES_WORKTREE := $(shell git rev-parse --show-toplevel 2>/dev/null)

# --impure unconditionally so the flake can read DOTFILES_WORKTREE. The
# ALLOW_* flags below still toggle their respective NIXPKGS_ALLOW_* env
# vars, but the --impure flag itself is always on.
IMPURE := --impure

# Builder guests use path flakes to include explicitly authorized protected files.
ALAMODE_BUILD_FLAKE ?= .

# nix-output-monitor renders nix's output only when it is on PATH and
# stderr is a terminal. Piped into a file, it redraws its whole tree on
# every line.
NOM := $(shell [ -t 2 ] && command -v nom)
NIX_BUILD := $(if $(NOM),nom,nix) build
# $(call WITH_NOM,command) appends the flags nom reads to command, so
# command has to end where nix flags go. pipefail keeps a failed build
# from passing as nom's exit status.
WITH_NOM = $(if $(NOM),set -o pipefail; $(1) --log-format internal-json -v 2>&1 | nom --json,$(1))

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
	# The nixos switch handles its own service reloads; the darwin daemon
	# dance below is a no-op here.
	NIX_DAEMON_BEFORE := :
	NIX_DAEMON_RESTART := :
else ifeq ($(UNAME), Darwin)
	REBUILD := darwin-rebuild $(IMPURE)
	# darwin-rebuild requires root for activation. --preserve-env keeps
	# GIT_SSH_COMMAND so private flake inputs (e.g. ssh://git@github.com/...)
	# can still authenticate via the key configured in this repo's
	# core.sshCommand.
	# sudo dies with EXC_GUARD in pam_tid on the retry after a wrong password
	# once pam_reattach has run, so each attempt gets a fresh `sudo -v` and
	# the switch reuses the cached credential. Only that crash (SIGKILL, 137)
	# retries: sudo catches ^C at the prompt and exits 1, so any other status
	# has to end the loop or ^C cannot stop it.
	SWITCH := until sudo -v; do [ $$? -eq 137 ] || exit 1; done; sudo --preserve-env=DOTFILES_WORKTREE,GIT_SSH_COMMAND,NIXPKGS_ALLOW_BROKEN,NIXPKGS_ALLOW_UNFREE,NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM $(REBUILD)

	# Activation rewrites these without restarting the nix daemon, which reads
	# them only at start. A change to any of them restarts it, which kills any
	# build in flight. The label is the daemon's launchd name, picked per
	# machine: Determinate's on trex, nix-darwin's on work-mac.
	NIX_DAEMON_SUM := cat /etc/nix/nix.conf /etc/nix/nix.custom.conf /etc/nix/machines 2>/dev/null | shasum
	NIX_DAEMON_LABEL := $(if $(filter trex,$(MACHINE)),systems.determinate.nix-daemon,org.nixos.nix-daemon)
	NIX_DAEMON_BEFORE := before=$$($(NIX_DAEMON_SUM))
	NIX_DAEMON_RESTART = { [ "$$before" = "$$($(NIX_DAEMON_SUM))" ] || sudo launchctl kickstart -k system/$(NIX_DAEMON_LABEL); }
else
  $(error Unsupported system: $(UNAME))
endif

.PHONY: help
help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-26s\033[0m %s\n", $$1, $$2}'

# --keep-going so a local build reports every failing derivation, not just the first.
.PHONY: build
build: ## Build this host's system
	$(call WITH_NOM,$(REBUILD) --flake .#$(HOST) build --keep-going)

# WORK_CONFIG only ever applies to work-mac: mkDarwinSystem imports
# work-config's darwinModule on every darwin host, so honoring the override
# for trex would layer the work modules onto a personal machine. The trex
# targets deliberately ignore it.
.PHONY: deploy
deploy: ## Switch this machine to the new configuration
	$(NIX_DAEMON_BEFORE); $(call WITH_NOM,$(SWITCH) $(if $(filter work-mac,$(HOST)),$(WORK_INPUT_FLAG)) --flake .#$(HOST) switch) && $(NIX_DAEMON_RESTART)
	$(if $(filter work-mac trex,$(HOST)),$(ALAMODE_SEATS_CHECK))

# Aliases that pin the host; a HOST=... on the command line still wins.
.PHONY: deploy-mac
deploy-mac: HOST := work-mac
deploy-mac: deploy ## Deploy work-mac (set WORK_CONFIG=/path/to/work for work config)

.PHONY: deploy-trex
deploy-trex: HOST := trex
deploy-trex: deploy ## Deploy trex

# Every kernel output plus the configfile, because cogsworth's dtbo overlays
# build from kernel.dev and nixpkgs' ASLR sysctl reads the configfile. A
# collected dev output rebuilds the whole kernel.
.PHONY: deploy-rs-gcroots
deploy-rs-gcroots:
	$(NIX_BUILD) $(IMPURE) --out-link $(DEPLOY_GC)/cogsworth-kernel \
	  .#nixosConfigurations.cogsworth.config.system.build.kernel^* \
	  .#nixosConfigurations.cogsworth.config.system.build.kernel.configfile \
	  .#nixosConfigurations.cogsworth.config.system.modulesTree

.PHONY: deploy-rs
deploy-rs: $(if $(filter cogsworth,$(HOST)),deploy-rs-gcroots)
deploy-rs: ## Deploy to the deploy-rs host HOST selects (tiger, pika, cogsworth)
	$(call WITH_NOM,deploy .#$(HOST) -- $(IMPURE))

.PHONY: deploy-rs-all
deploy-rs-all: deploy-rs-gcroots
deploy-rs-all: ## flake check, then deploy tiger, pika and cogsworth
	$(call WITH_NOM,nix flake check $(IMPURE) -L)
	$(call WITH_NOM,deploy --skip-checks . -- $(IMPURE))

.PHONY: deploy-rs-all-dry
deploy-rs-all-dry: deploy-rs-gcroots
deploy-rs-all-dry: ## flake check, then dry-activate tiger, pika and cogsworth
	$(call WITH_NOM,nix flake check $(IMPURE) -L)
	$(call WITH_NOM,deploy --skip-checks --dry-activate . -- $(IMPURE))

# This host first (its sudo prompt happens while you are watching), then
# every deploy-rs host. make stops at the first failure; -k deploys on.
.PHONY: deploy-all
deploy-all: deploy deploy-rs-all
deploy-all: ## Switch this host, then every deploy-rs host (-k continues past a failure)

.PHONY: diff-system
diff-system: ## Print system diff without color
	@nix store diff-closures $$(readlink -f /nix/var/nix/profiles/system) $$(readlink -f ./result) | sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g'

.PHONY: update
update: ## Update every flake input
	nix flake update

.PHONY: update/cogsworth
update/cogsworth: ## Update just the cogsworth input
	nix flake update cogsworth

.PHONY: update/nixpkgs-master
update/nixpkgs-master: ## Update just the nixpkgs-master input
	nix flake update nixpkgs-master

.PHONY: check
check: ## Run the flake checks
	$(call WITH_NOM,nix flake check $(IMPURE) -L)

.PHONY: secrets-status
secrets-status: ## Show whether each git-crypt and sops file is stored encrypted, locally and upstream
	@nix run .#secrets-check -- status

.PHONY: info
info: ## Print information about the system
	@echo "Current generation's largest dependencies:"
	@du -shc $$(nix-store -qR "$$(realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: sdcard-cogsworth
sdcard-cogsworth: ## Build cogsworth SD card image with WiFi
	@echo "Decrypting SSH host key locally..."
	@export COGSWORTH_SSH_KEY=$$(sops -d nix/hosts/cogsworth/keys/ssh_host_ed25519_key.sops) && \
		echo "Building SD image (this takes a while)..." && \
		$(NIX_BUILD) $(IMPURE) .#nixosConfigurations.cogsworth.config.system.build.sdImage && \
		echo "Done! Image at: result/sd-image/"

# x86_64-linux, and trex has no local x86_64 builder, so this runs on tiger
# and copies ~1GB back.
.PHONY: iso-pika
iso-pika: ## Build pika's headless install and rescue ISO
	$(NIX_BUILD) $(IMPURE) .#nixosConfigurations.pika-installer.config.system.build.isoImage
	@echo "Done! Image at: result/iso/pika-installer.iso"

.PHONY: cleanup
cleanup: ## Cleanup and reduce diskspace of current system
	sudo nix-collect-garbage --delete-older-than 7d
	nix-collect-garbage --delete-older-than 7d
	sudo nix store optimise

# The seats and catalog are sops secrets, which nix cannot see at eval, so
# they are checked here against what the switch just decrypted to
# /run/secrets, then each pinned mcloud id against the live endpoint,
# images included where the catalog declares them. The new generation is
# active by now, so a failure means another deploy. Both name the seat var or
# catalog entry and what to change, never a model id. An endpoint that does
# not answer at all only warns, since an outage says nothing about this
# host's config.
ALAMODE_SEATS_CHECK := alamode-seats check --deploy && mcloud-pins --deploy
# The built wrapper parses its baked session config on every start, so a
# conflict only the real work config carries fails the build instead of
# the first session start after a deploy. The glob is the host's one user.
ALAMODE_SMOKE := ./result/etc/profiles/per-user/*/bin/alamode --help >/dev/null
# $(call DARWIN_SYSTEM,host) is host's darwin system attr, quoted once for
# every target that builds one.
DARWIN_SYSTEM = "$(ALAMODE_BUILD_FLAKE)\#darwinConfigurations.$(1).system"

.PHONY: build-mac
build-mac: ## Build work-mac (set WORK_CONFIG=/path/to/work for work config)
	$(NIX_BUILD) $(IMPURE) $(WORK_INPUT_FLAG) $(call DARWIN_SYSTEM,work-mac)
	$(ALAMODE_SMOKE)

.PHONY: build-mac-dry
build-mac-dry: ## Dry-run build of work-mac (set WORK_CONFIG=... for work config)
	nix build $(IMPURE) $(WORK_INPUT_FLAG) $(call DARWIN_SYSTEM,work-mac) --dry-run

.PHONY: build-trex
build-trex: ## Build trex
	$(NIX_BUILD) $(IMPURE) $(call DARWIN_SYSTEM,trex)
	$(ALAMODE_SMOKE)

.PHONY: build-trex-dry
build-trex-dry: ## Dry-run build of trex
	nix build $(IMPURE) $(call DARWIN_SYSTEM,trex) --dry-run

# Replaces the script Roundcube's Filters UI edits, so changes made there
# are lost on the next push. The server rejects a script that fails to
# parse, a still-encrypted git-crypt file included.
SIEVE_CONNECT = pass show email/kyle@ondy.org | head -1 | nix run --inputs-from . nixpkgs\#sieve-connect -- \
	--server london.mxroute.com --user kyle@ondy.org --passwordfd 0 --remotesieve managesieve

.PHONY: sieve-push
sieve-push: ## Upload and activate the ondy.org mail filters
	$(SIEVE_CONNECT) --localsieve mail/ondy.org.sieve --upload
	$(SIEVE_CONNECT) --activate

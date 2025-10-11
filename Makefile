UNAME := $(shell uname)
HOSTNAME=$(shell hostname -s)
ALLOW_BROKEN=false
ALLOW_UNSUPPORTED=false
ALLOW_UNFREE=false

# I don't like to do this, but sometimes I just need to move ahead
ifeq ($(ALLOW_BROKEN), true)
	export NIXPKGS_ALLOW_BROKEN=1
	IMPURE=--impure
endif

ifeq ($(ALLOW_UNSUPPORTED), true)
	export NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
	IMPURE=--impure
endif

ifeq ($(ALLOW_UNFREE), true)
	export NIXPKGS_ALLOW_UNFREE=1
	IMPURE=--impure
endif

# this is my naive approach to supporting multiple systems.
ifeq ($(UNAME), Linux)
	REBUILD := nixos-rebuild $(IMPURE)
	SWITCH := sudo $(REBUILD) $(IMPURE)
else ifeq ($(UNAME), Darwin)
	REBUILD := darwin-rebuild $(IMPURE)
	SWITCH := $(REBUILD) $(IMPURE)
else
	(echo "Unsupported file system: $(UNAME)"; exit 1)
endif

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-26s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Buld single host
	$(REBUILD) --flake .#$(HOSTNAME) build --keep-going

.PHONY: diff-current-system
diff-current-system:
	nix store diff-closures /var/run/current-system "$(shell readlink -f ./result)"

.PHONY: deploy
deploy: ## Deploy currently defined configuration
	$(SWITCH) --flake .#$(HOSTNAME) switch

.PHONY: boot
boot: ## Deploy currently defined configuration for next boot
	$(SWITCH) --flake .#$(HOSTNAME) boot

.PHONY: test
test: ## Apply the current config without persisting it
	$(SWITCH) --flake .#$(HOSTNAME) test

.PHONY: deploy-rs
deploy-rs:
	deploy -- .#$(HOSTNAME)

.PHONY: deploy-rs-all
deploy-rs-all:
	nix flake check -L
	deploy --skip-checks -- .

.PHONY: deploy-rs-all-dry
deploy-rs-all-dry:
	nix flake check -L
	deploy --skip-checks --dry-activate -- .

.PHONY: diff-system
diff-system: ## Print system diff without color
	@nix store diff-closures $(shell readlink -f /nix/var/nix/profiles/system) $(shell readlink -f ./result) |  sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g'

.PHONY: vm
vm: ## build qemu vm
	$(REBUILD) build-vm --flake .#$(HOSTNAME)
	./result/bin/run-$(HOSTNAME)-vm

# port forward: QEMU_NET_OPTS="hostfwd=tcp::8080-:8080"
.PHONY: run-vm
run-vm:
	./result/bin/run-$(HOSTNAME)-vm

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

.PHONY: check
check: ## Run nix checks
	nix flake check

.PHONY: info
info: ## Print information about the system
	@echo "Current generation's largest dependencies:"
	@du -shc $(shell nix-store -qR "$(shell realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: iso
iso: ## build install media with my customizations
	nix build .#nixosConfigurations.iso.config.system.build.isoImage

.PHONY: sdcard
sdcard: ## build install media with my customizations
	nix build .#nixosConfigurations.sd_card.config.system.build.sdImage

.PHONY: cleanup
cleanup: ## Cleanup and reduce diskspace of current system
	nix-collect-garbage --delete-older-than 7d
	sudo nix-collect-garbage --delete-older-than 7d
	sudo nix store optimise

# https://kgolding.co.uk/snippets/makefile-check-git-status/
.PHONY: git-status
git-status:
	@status=$$(git status --porcelain); \
	if [ ! -z "$${status}" ]; \
	then \
		echo "Error - working directory is dirty. Commit those changes!"; \
		exit 1; \
	fi

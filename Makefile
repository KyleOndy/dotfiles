UNAME := $(shell uname)
HOSTNAME=$(shell hostname -s)
ALLOW_BROKEN=false
ALLOW_UNSUPPORTED=false
ALLOW_UNFREE=false

# Binary cache configuration
CACHE_HOST=wolf
CACHE_URL=ssh://$(CACHE_HOST)

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

.PHONY: apply
apply: ## Apply the current config without persisting it
	$(SWITCH) --flake .#$(HOSTNAME) test

.PHONY: deploy-rs
deploy-rs:
	deploy .#$(HOSTNAME)

.PHONY: deploy-rs-all
deploy-rs-all:
	nix flake check -L
	deploy --skip-checks .

.PHONY: deploy-rs-all-dry
deploy-rs-all-dry:
	nix flake check -L
	deploy --skip-checks --dry-activate .

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

.PHONY: sdcard-cogsworth
sdcard-cogsworth: ## Build cogsworth SD card image with WiFi
	@echo "Decrypting SSH host key locally..."
	@export COGSWORTH_SSH_KEY=$$(sops -d nix/hosts/cogsworth/keys/ssh_host_ed25519_key.sops) && \
		echo "Building SD image (this takes a while)..." && \
		nix build --impure .#nixosConfigurations.cogsworth.config.system.build.sdImage && \
		echo "Done! Image at: result/sd-image/" || \
		(echo "Build failed"; exit 1)

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

# Cache push targets
.PHONY: cache-push-dino
cache-push-dino: ## Push dino system closure to binary cache
	nix copy --to $(CACHE_URL) --derivation .#nixosConfigurations.dino.config.system.build.toplevel

.PHONY: cache-push-tiger
cache-push-tiger: ## Push tiger system closure to binary cache
	nix copy --to $(CACHE_URL) --derivation .#nixosConfigurations.tiger.config.system.build.toplevel

.PHONY: cache-push-wolf
cache-push-wolf: ## Push wolf system closure to binary cache
	nix copy --to $(CACHE_URL) --derivation .#nixosConfigurations.wolf.config.system.build.toplevel

.PHONY: cache-push-all
cache-push-all: cache-push-dino cache-push-tiger cache-push-wolf ## Push all system closures to binary cache

# macOS-specific targets
.PHONY: build-mac
build-mac: ## Build work-mac darwin configuration
	nix build $(IMPURE) .#darwinConfigurations.work-mac.system

.PHONY: build-mac-dry
build-mac-dry: ## Dry-run build of work-mac darwin configuration
	nix build $(IMPURE) .#darwinConfigurations.work-mac.system --dry-run

.PHONY: test-mac
test-mac: ## Test work-mac configuration evaluation
	nix eval $(IMPURE) .#darwinConfigurations.work-mac.config.system.stateVersion

.PHONY: test-mac-home
test-mac-home: ## Test work-mac home-manager configuration
	nix eval $(IMPURE) .#darwinConfigurations.work-mac.config.home-manager.users.'"kyle.ondy"'.home.homeDirectory

# WSL-specific targets
.PHONY: build-wsl
build-wsl: ## Build work-wsl home-manager configuration
	nix build --impure .#homeConfigurations."kyle@work-wsl".activationPackage

.PHONY: build-wsl-dry
build-wsl-dry: ## Dry-run build of work-wsl home-manager configuration
	nix build --impure .#homeConfigurations."kyle@work-wsl".activationPackage --dry-run

.PHONY: deploy-wsl
deploy-wsl: ## Deploy work-wsl home-manager configuration
	nix run --impure .#homeConfigurations."kyle@work-wsl".activationPackage

.PHONY: flash-ergodox
flash-ergodox:
	nix run .#flash-ergodox

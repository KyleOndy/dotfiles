UNAME := $(shell uname)
HOSTNAME=$(shell hostname)

# this is my naive approach to supporting multiple systems.
ifeq ($(UNAME), Linux)
	REBUILD := nixos-rebuild
	SWITCH := sudo $(REBUILD)
else ifeq ($(UNAME), Darwin)
	REBUILD := darwin-rebuild
	SWITCH := sudo $(REBUILD)
else
	# todo: this will need to be addressed when I try to extend this repository
	#       to a WSL, or any machine that isn't NixOS or nix-darwin.
	(echo "Unsupported file system: $(UNAME)"; exit 1)
endif

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-26s\033[0m %s\n", $$1, $$2}'


.PHONY: build
build: ## Build currently defined configuration
	@# tood: not sure why I need to remove the result symlink for the
	@#       diff-closures command to show anything
	@rm -f result
	@# hack: todo: there appears to be some issues where the first build command
	@#              doesn't build everything, but the second invocation does. To be
	@#              safe, until I get to dig into it, just build it all twice.
	@#              Due to this, pipe STDOUT out of the first build to /dev/null
	@nix build .#$(HOSTNAME) --keep-going > /dev/null
	nix build .#$(HOSTNAME) --keep-going
	nix store diff-closures /var/run/current-system $(shell readlink -f ./result)

.PHONY: switch
switch: git-status build ## Switch the system to the defined state
	@# todo: is there an issue using {darwin,nixos}-rebuild and not `./result/activate`? I am doing this becuase it appeared that `*-rebuild build` was not creating the `result` directory.
	$(SWITCH) switch --flake .

# todo: add targets to update a single dependencies instead of blindly updating
#       them all.
.PHONY: update
update: ## Update all flake soruces
	nix flake update

.PHONY: update/nixpkgs
update/nixpkgs: ## Updage just nixpkgs source
	nix flake lock --update-input nixpkgs

.PHONY: update/home-manager
update/home-manager: ## Update just home-manager source
	nix flake lock --update-input home-manager

.PHONY: update/nur
update/nur: ## Update just the nur source
	nix flake lock --update-input nur

.PHONY: update/nix-darwin
update/nix-darwin: ## Update just the nur source
	nix flake lock --update-input nix-darwin

.PHONY: update/pre-commit-hooks
update/pre-commit-hooks: ## Update just the pre-commit-hooks source
	nix flake lock --update-input pre-commit-hooks

.PHONY: check
check: ## Run nix checks
	nix flake check

.PHONY: info
info: ## Print information about the system
	@echo "Current generation's largest dependencies:"
	@du -shc $(shell nix-store -qR "$(shell realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: iso
iso: ## build install media with my customizations
	nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=iso.nix

.PHONY: cleanup
cleanup: ## Cleanup and reduce diskspace of current system
	sudo nix-collect-garbage --delete-older-than 31d
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

UNAME := $(shell uname)
HOSTNAME=$(shell hostname)

# this is my naive approach to supporting multiple systems.
ifeq ($(UNAME), Linux)
	REBUILD := nixos-rebuild
else ifeq ($(UNAME), Darwin)
	REBUILD := darwin-rebuild
else
	# todo: this will need to be addressed when I try to extend this repository
	#       to a WSL, or any machine that isn't NixOS or nix-darwin.
	(echo "Unsupported file system: $(UNAME)"; exit 1)
endif

.PHONY: build
build:
	@# hack: todo: there appears to be some issues where the first build command
	@#              doesn't build everything, but the second invocation does. To be
	@#              safe, until I get to dig into it, just build it all twice.
	@#              Due to this, pipe STDOUT out of the first build to /dev/null
	@nix build .#alpha > /dev/null
	nix build .#alpha
	nix store diff-closures /var/run/current-system $(shell readlink -f ./result)

.PHONY: switch
switch: build
	sudo $(REBUILD) switch --flake .

# todo: add targets to update a single dependencies instead of blindly updating
#       them all.
.PHONY: update
update:
	nix flake update

.PHONY: update/nixpkgs
update/nixpkgs:
	nix flake lock --update-input nixpkgs

.PHONY: update/home-manager
update/home-manager:
	nix flake lock --update-input home-manager

.PHONY: update/neovim-nightly
update/neovim-nightly:
	nix flake lock --update-input neovim-nightly-overlay

.PHONY: update/nur
update/nur:
	nix flake lock --update-input nur

.PHONY: update/pre-commit-hooks
update/pre-commit-hooks:
	nix flake lock --update-input pre-commit-hooks

.PHONY: check
check:
	nix flake check

.PHONY: info
info:
	@echo "Current generation's largest dependencies:"
	@du -shc $(shell nix-store -qR "$(shell realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: iso
iso: ## build install media with my customizations
	nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=iso.nix

.PHONY: cleanup
cleanup:
	sudo nix-collect-garbage --delete-older-than 31d
	sudo nix store optimise

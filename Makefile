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
	$(REBUILD) build --flake .
	nix store diff-closures /var/run/current-system $(shell readlink -f ./result)

.PHONY: switch
switch: build
	sudo $(REBUILD) switch --flake .

# todo: add targets to update a single dependencies instead of blindly updating
#       them all.
.PHONY: update
update:
	nix flake update

.PHONY: check
check:
	nix flake check

.PHONY: info
info:
	@echo "Current generation's largest dependencies:"
	@du -shc $(shell nix-store -qR "$(shell realpath /var/run/current-system)") | sort -hr | head -n 11

.PHONY: cleanup
cleanup:
	sudo nix-collect-garbage --delete-older-than 31d
	sudo nix store optimise

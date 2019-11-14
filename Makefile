# #######################################################################
# This make file is lifted almost entierly from Terje Larsen's nix-config
# respository [1]. He makefile acomplished almost everything I was trying
# to achive. No needed to reinvent the wheel here.
#
# [1] https://github.com/terlar/nix-config/blob/master/Makefile
# #######################################################################

# these enviorment variables are consumed by various nix binaries to override default settings
HOSTNAME            := $(shell hostname)
NIXOS_CONFIG        := $(CURDIR)/hosts/$(HOSTNAME)/configuration.nix
HOME_MANAGER_CONFIG := $(CURDIR)/home/home.nix
NIX_PATH            := nixpkgs=$(CURDIR)/nixpkgs:nixpkgs-overlays=$(CURDIR)/home/overlays:home-manager=$(CURDIR)/home-manager:nixos-config=$(NIXOS_CONFIG)
NIXOS_LABEL         :=$(shell (git rev-parse --long HEAD))

# use one timestamp for everything.
TIMESTAMP           :=$(shell (TZ= date -Iseconds))
OS                  := $(shell uname)


SWITCH_SYSTEM := switch-nixos

# test if the working directory is dirty.
ifeq ($(strip $(shell git status --porcelain 2>/dev/null)),)
 GIT_TREE_STATE=clean
else
 GIT_TREE_STATE=dirty
endif

# why are we exporting these?
export NIX_PATH
export HOME_MANAGER_CONFIG

.PHONY: help
help: ## Show this help message.
	$(info $(NAME) $(TAG))
	@echo "Usage: make [target] ..."
	@echo
	@echo "Targets:"
	@egrep '^(.+)\:[^#]*##\ (.+)' ${MAKEFILE_LIST} | column -t -c 2 -s ':#'

.PHONY: print-path
print-path: ## Print NIX_PATH
	@echo $(NIX_PATH)

.PHONY: init
init: ## Initialize sources (submodules)
	git submodule update --init


.PHONY: install-nix install-nixos install-home
install-nix: ## Install nix and update submodules
	curl https://nixos.org/nix/install | sh
install-home: ## Install home-manager
	nix-shell home-manager -A install --run 'home-manager -b bak switch'


.PHONY: switch switch-home
switch: switch-system switch-home ## Switch all
switch-home: check ## Switch to latest home config
	home-manager -b bak switch
	@echo "Home generation: $$(home-manager generations | head -1)"

.PHONY: switch-system switch-nixos
switch-system: ## Switch to latest system config
switch-system: switch-nixos
switch-nixos: check ## Switch to latest NixOS config
	sudo -E nixos-rebuild switch

.PHONY: build-nixos build-home
build-nixos: ## Build nixos configuration
	nixos-rebuild build
build-home: ## Build home-manager configuration
	home-manager build


.PHONY: pull
pull: pull-nix ## Pull latest upstream changes
pull-nix: ## Pull latest nix upstream changes
	git submodule sync home-manager nixpkgs
	git submodule update --remote home-manager
	git submodule update --remote nixpkgs



.PHONY: home-manager/man
home-manager/man:
	man home-configuration.nix

.PHONY: clean
clean:
	# remove all packages not defined in code
	nix-env --uninstall '*'

.PHONY: check
check:
ifeq ($(GIT_TREE_STATE),dirty)
	$(error git state is not clean)
endif

.PHONY: find-todo
find-todo: ## return all work needed
	grep --color -Ri -e todo -e hack -e fix ./home ./hosts README.md

.PHONY: nixfmt
nixfmt:
	find ./home ./hosts -name "*.nix" | xargs nixfmt

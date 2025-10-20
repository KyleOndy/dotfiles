# Build specific systems with automatic spot selection
# Instance families matched to system CPU architecture
.PHONY: build-tiger
build-tiger:
	./build-remote-auto x86_64-linux 96 \
	  .#nixosConfigurations.tiger.config.system.build.toplevel \
	  --family c6a

.PHONY: build-dino
build-dino:
	./build-remote-auto x86_64-linux 64 \
	  .#nixosConfigurations.dino.config.system.build.toplevel \
	  --family c7i

.PHONY: build-cheetah
build-cheetah:
	./build-remote-auto x86_64-linux 64 \
	  .#nixosConfigurations.cheetah.config.system.build.toplevel \
	  --family c6i

# Quick test with small instance (automatic spot selection)
.PHONY: test
test:
	./build-remote-auto x86_64-linux 4 nixpkgs#hello

# SSH to the running build machine
.PHONY: ssh-builder
ssh-builder:
	@if [ ! -f terraform.tfstate ] || ! terraform output ec2_dns &>/dev/null; then \
		echo "ERROR: No builder instance is currently provisioned."; \
		echo "Run a build target first (e.g., make build-dino)"; \
		exit 1; \
	fi
	@host=$$(terraform output -raw ec2_dns); \
	keypair_path=$$(terraform output -raw keypair_file); \
	echo "Connecting to $$host..."; \
	ssh -i "$$keypair_path" \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		root@$$host

# Emergency cleanup if script fails
.PHONY: cleanup
cleanup:
	./emergency-cleanup

# Manual destroy (if you provisioned manually)
.PHONY: destroy
destroy:
	terraform destroy -auto-approve

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build Targets (automatic spot selection, provision, build, cleanup):"
	@echo "  build-tiger    - Build tiger system (96+ vCPU AMD EPYC)"
	@echo "  build-dino     - Build dino system (64+ vCPU Intel)"
	@echo "  build-cheetah  - Build cheetah system (64+ vCPU Intel)"
	@echo "  test           - Quick test build (4+ vCPU)"
	@echo ""
	@echo "Spot Instance Advisor:"
	@echo "  ./select-best-spot <arch> <min-vcpus> [--family <family>]"
	@echo "  ./check-spot-availability <arch>"
	@echo ""
	@echo "Direct Usage:"
	@echo "  ./build-remote-auto <arch> <min-vcpus> <target>"
	@echo "  ./build-remote <instance-type> <arch> <target>  (manual override)"
	@echo ""
	@echo "Debugging:"
	@echo "  ssh-builder    - SSH to the currently running build machine"
	@echo ""
	@echo "Emergency:"
	@echo "  cleanup        - Emergency cleanup of orphaned instances"
	@echo "  destroy        - Manual terraform destroy (if needed)"
	@echo ""
	@echo "Examples:"
	@echo "  make build-tiger"
	@echo "  ./select-best-spot amd64 96 --family c6a"
	@echo "  ./build-remote-auto x86_64-linux 96 .#nixosConfigurations.tiger.config.system.build.toplevel"

# EC2 Ephemeral Build Machines

Build NixOS systems on optimized EC2 instances that provision on-demand and terminate automatically after the build completes.

## Features

- ✅ **Fully automated** - One command provisions, builds, and cleans up
- ✅ **Architecture-matched** - Use AMD EPYC for Zen 3 builds, Intel Xeon for Skylake
- ✅ **Cost-optimized** - Instances only run during builds (minutes, not hours/days)
- ✅ **Safe cleanup** - Comprehensive bash traps ensure instances are terminated
- ✅ **Accurate CPU detection** - Queries actual vCPU count from running instance
- ✅ **Emergency cleanup** - Fallback script if traps fail

## Quick Start

```bash
# Build a specific system
make build-tiger    # AMD EPYC c6a.24xlarge (96 vCPU)
make build-dino     # Intel c7i.16xlarge (64 vCPU)

# Test with small instance
make test

# Custom build
./build-remote c6a.24xlarge x86_64-linux .#myPackage

# Help
make help
```

## Architecture Matching

Your systems are built on EC2 instances matching their CPU architectures:

| System | CPU                         | EC2 Instance | vCPUs | Architecture |
| ------ | --------------------------- | ------------ | ----- | ------------ |
| tiger  | AMD Ryzen 7 5800X (Zen 3)   | c6a.24xlarge | 96    | znver3       |
| dino   | Intel i5-1240P (Alder Lake) | c7i.16xlarge | 64    | skylake      |

## How It Works

1. **Provision**: Terraform creates EC2 instance with correct architecture
2. **Configure**: User-data sets up optimal Nix configuration
3. **Detect**: SSH queries actual vCPU count with `nproc`
4. **Build**: Nix uses `--builders` to offload build to remote instance
5. **Cleanup**: Bash traps ensure instance is terminated on success/failure/Ctrl+C

## Safety Features

### Layer 1: Bash Traps (Primary)

- Comprehensive traps for EXIT, INT, TERM, ERR
- Retries terraform destroy up to 3 times
- Falls back to direct AWS API if terraform fails

### Layer 2: Instance Auto-Terminate

- `instance_initiated_shutdown_behavior = "terminate"`
- If instance shuts down, it terminates (doesn't stop)

### Layer 3: Emergency Cleanup

- Manual cleanup script: `./emergency-cleanup`
- Queries AWS for orphaned instances by tags
- Direct termination via AWS API

## Cost Estimates

Approximate costs for full system rebuild (2-3 hours):

| Instance     | On-Demand | Spot (avg) | Full Build Cost |
| ------------ | --------- | ---------- | --------------- |
| c6a.24xlarge | $3.67/hr  | ~$1.30/hr  | ~$2.60-$3.90    |
| c7i.16xlarge | $2.89/hr  | ~$1.00/hr  | ~$2.00-$3.00    |
| c6a.xlarge   | $0.15/hr  | ~$0.05/hr  | ~$0.10-$0.15    |

**Key insight**: Only pay for actual build time, not 24/7 running costs!

## Requirements

- Terraform
- AWS CLI (optional, for emergency cleanup)
- jq
- SSH
- Nix with flakes enabled

## Emergency Procedures

If something goes wrong and the instance doesn't terminate:

```bash
# Option 1: Run emergency cleanup script
cd util/ec2_build
./emergency-cleanup

# Option 2: Manual terraform destroy
terraform destroy -auto-approve

# Option 3: AWS Console
# Find instances tagged with ManagedBy=terraform-ephemeral-builder
# Terminate manually
```

## Advanced Usage

```bash
# Build with custom instance and architecture
./build-remote <instance-type> <architecture> <build-target>

# Examples:
./build-remote c6a.48xlarge x86_64-linux .#nixosConfigurations.tiger.config.system.build.toplevel
./build-remote c7g.16xlarge aarch64-linux .#myArmPackage
./build-remote c6a.xlarge x86_64-linux .#hello
```

## Future Enhancements

- [ ] Lambda function for detecting orphaned instances (30-min intervals)
- [ ] CloudWatch billing alarms
- [ ] Spot instance support for 60-70% cost savings
- [ ] Support for building multiple systems in parallel

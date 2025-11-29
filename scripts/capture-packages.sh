#!/usr/bin/env bash
set -euo pipefail

# Script to capture current package state for all hosts
# This will be used to verify package parity after migration

HOSTS="dino tiger wolf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="pre-migration"

echo "Package State Capture - ${TIMESTAMP}"
echo "====================================="

mkdir -p "${OUTPUT_DIR}"

for host in $HOSTS; do
    echo "Capturing packages for ${host}..."

    # Capture full package list as JSON
    if nix eval ".#nixosConfigurations.${host}.config.home-manager.users.kyle.home.packages" --json > "${OUTPUT_DIR}/${host}-packages.json" 2>/dev/null; then
        echo "  ✓ Captured package list"
    else
        echo "  ✗ Failed to capture package list"
        continue
    fi

    # Capture just package names for easier reading
    if nix eval ".#nixosConfigurations.${host}.config.home-manager.users.kyle.home.packages" --apply 'map (p: p.name)' --json > "${OUTPUT_DIR}/${host}-package-names.json" 2>/dev/null; then
        echo "  ✓ Captured package names"
        # Pretty print and count
        PACKAGE_COUNT=$(jq '. | length' "${OUTPUT_DIR}/${host}-package-names.json")
        echo "  → Total packages: ${PACKAGE_COUNT}"
    else
        echo "  ✗ Failed to capture package names"
    fi

    # Capture feature flags
    if nix eval ".#nixosConfigurations.${host}.config.home-manager.users.kyle.config.hmFoundry.features" --json > "${OUTPUT_DIR}/${host}-features.json" 2>/dev/null; then
        echo "  ✓ Captured feature flags"
    else
        echo "  ✗ Failed to capture feature flags"
    fi

    echo ""
done

# Create summary
echo "Creating summary..."
{
    echo "# Package Capture Summary"
    echo "Date: ${TIMESTAMP}"
    echo ""
    echo "## Host Package Counts"
    for host in $HOSTS; do
        if [ -f "${OUTPUT_DIR}/${host}-package-names.json" ]; then
            COUNT=$(jq '. | length' "${OUTPUT_DIR}/${host}-package-names.json")
            echo "- ${host}: ${COUNT} packages"
        fi
    done
    echo ""
    echo "## Feature Flags by Host"
    for host in $HOSTS; do
        if [ -f "${OUTPUT_DIR}/${host}-features.json" ]; then
            echo "### ${host}"
            echo '```json'
            jq '.' "${OUTPUT_DIR}/${host}-features.json"
            echo '```'
        fi
    done
} > "${OUTPUT_DIR}/capture-summary.md"

echo "Summary written to ${OUTPUT_DIR}/capture-summary.md"
echo "Done!"

#!/usr/bin/env bash
set -euo pipefail

# Script to compare package lists before and after migration

if [ $# -ne 1 ]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 dino"
    exit 1
fi

HOST=$1
PRE_FILE="pre-migration/${HOST}-package-names.json"
POST_FILE="post-migration/${HOST}-package-names.json"

if [ ! -f "${PRE_FILE}" ]; then
    echo "Error: Pre-migration file not found: ${PRE_FILE}"
    echo "Run ./scripts/capture-packages.sh first"
    exit 1
fi

if [ ! -f "${POST_FILE}" ]; then
    echo "Error: Post-migration file not found: ${POST_FILE}"
    echo "Capture post-migration state first"
    exit 1
fi

echo "Package Comparison for ${HOST}"
echo "=============================="
echo ""

# Get package counts
PRE_COUNT=$(jq '. | length' "${PRE_FILE}")
POST_COUNT=$(jq '. | length' "${POST_FILE}")

echo "Package counts:"
echo "  Before: ${PRE_COUNT}"
echo "  After:  ${POST_COUNT}"
echo "  Change: $((POST_COUNT - PRE_COUNT))"
echo ""

# Find differences
echo "Analyzing differences..."

# Packages removed (in pre but not in post)
REMOVED=$(jq -r --slurpfile post "${POST_FILE}" '
  . - $post[0] | .[]
' "${PRE_FILE}" | sort)

# Packages added (in post but not in pre)
ADDED=$(jq -r --slurpfile pre "${PRE_FILE}" '
  . - $pre[0] | .[]
' "${POST_FILE}" | sort)

if [ -n "${REMOVED}" ]; then
    echo ""
    echo "Packages REMOVED:"
    while IFS= read -r pkg; do
        echo "  - ${pkg}"
    done <<< "${REMOVED}"
    REMOVED_COUNT=$(echo "${REMOVED}" | wc -l)
    echo "  Total removed: ${REMOVED_COUNT}"
fi

if [ -n "${ADDED}" ]; then
    echo ""
    echo "Packages ADDED:"
    while IFS= read -r pkg; do
        echo "  + ${pkg}"
    done <<< "${ADDED}"
    ADDED_COUNT=$(echo "${ADDED}" | wc -l)
    echo "  Total added: ${ADDED_COUNT}"
fi

if [ -z "${REMOVED}" ] && [ -z "${ADDED}" ]; then
    echo ""
    echo "✓ No package changes detected - perfect parity!"
fi

echo ""
echo "For detailed diff, run:"
echo "  diff -u ${PRE_FILE} ${POST_FILE} | less"
#!/usr/bin/env bash
set -euo pipefail
exec @python@ -I @runtime@/session.py @configuration@ "$0" "$@"

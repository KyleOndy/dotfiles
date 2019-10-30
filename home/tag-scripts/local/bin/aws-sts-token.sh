#!/usr/bin/env bash
# ------------------------------------------------------------------
#          Description
#
# This script assumes into a role using a STS token.
# ------------------------------------------------------------------
set -euo pipefail

ROLE=${1:-"bx_admin"}

temp_role=$(aws sts assume-role \
  --role-arn "arn:aws:iam::072292405059:role/$ROLE" \
  --role-session-name "ondyk-$(date -I)" \
  --profile default)

AWS_ACCESS_KEY_ID=$(echo "$temp_role" | jq .Credentials.AccessKeyId | xargs)
export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(echo "$temp_role" | jq .Credentials.SecretAccessKey | xargs)
export AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN=$(echo "$temp_role" | jq .Credentials.SessionToken | xargs)
export AWS_SESSION_TOKEN

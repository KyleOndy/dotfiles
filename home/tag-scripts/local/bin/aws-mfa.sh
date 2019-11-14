#!/usr/bin/env bash
# ------------------------------------------------------------------
#          Description
#
# This script to used to obtain MFA validated credentials for command line
# usage derived from a set of long lived access and secret keys. These
# long-lived keys alone provide minimal access and are control via policies
# managed by the security team.
#
# Once these MFA credentials are obtained the user is free to assume into any other
# roles they have permissions to.
# ------------------------------------------------------------------
set -eo pipefail

USAGE="Usage: ass-mfa <mfa-code>"
code="$1"
if [ -z "$1" ]; then
  echo "MFA code:"
  read -r code
fi

_configure() {
  aws configure set "$1" "$2" --profile default
}
mfa_serial_number="arn:aws:iam::724483179792:mfa/Kyle.Ondy@blackstone.com"
ten_hour_in_seconds=36000

r_json=$(aws \
  --profile long-lived \
  sts \
  get-session-token \
  --duration-seconds "$ten_hour_in_seconds" \
  --serial-number "$mfa_serial_number" \
  --token-code "$code" | jq '.Credentials')

_configure "region" "us-east-1"
_configure "aws_access_key_id" "$(echo "$r_json" | jq -r '.AccessKeyId')"
_configure "aws_secret_access_key" "$(echo "$r_json" | jq -r '.SecretAccessKey')"
_configure "aws_session_token" "$(echo "$r_json" | jq -r '.SessionToken')"
_configure "expiration" "$(echo "$r_json" | jq -r '.Expiration')"

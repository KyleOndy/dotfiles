# Advanced monitoring and diagnostic tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.monitoring;

  # Script to create Alertmanager silences for specific hosts
  silence-host = pkgs.writeShellScriptBin "silence-host" ''
    #!/usr/bin/env bash
    # Create an Alertmanager silence for a specific host
    # Usage: silence-host <host> <duration> [comment]
    # Example: silence-host cogsworth "7 days" "Maintenance window"

    set -euo pipefail

    # Check arguments
    if [ $# -lt 2 ]; then
      echo "Usage: $0 <host> <duration> [comment]"
      echo ""
      echo "Examples:"
      echo "  $0 cogsworth '7 days' 'Maintenance window'"
      echo "  $0 wolf '2 hours' 'Testing updates'"
      echo "  $0 tiger '1 week'"
      echo ""
      echo "Duration format: Any format accepted by 'date -d' (e.g., '7 days', '2 hours', '1 week')"
      exit 1
    fi

    HOST="$1"
    DURATION="$2"
    COMMENT="''${3:-Maintenance window}"

    # Calculate timestamps
    START=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    END=$(date -u -d "+''${DURATION}" +%Y-%m-%dT%H:%M:%S.000Z)

    # Create silence payload
    PAYLOAD=$(cat <<EOF
    {
      "matchers": [
        {
          "name": "host",
          "value": "''${HOST}",
          "isRegex": false,
          "isEqual": true
        }
      ],
      "startsAt": "''${START}",
      "endsAt": "''${END}",
      "createdBy": "kyle",
      "comment": "''${COMMENT}"
    }
    EOF
    )

    echo "Creating silence for host: ''${HOST}"
    echo "Duration: ''${DURATION}"
    echo "Start: ''${START}"
    echo "End: ''${END}"
    echo "Comment: ''${COMMENT}"
    echo ""

    # Send to Alertmanager via stdin to avoid shell escaping issues
    RESPONSE=$(echo "''${PAYLOAD}" | ssh wolf "curl -s -X POST -H 'Content-Type: application/json' \
      -d @- http://127.0.0.1:9093/api/v2/silences")

    # Check if successful
    if echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.silenceID' > /dev/null 2>&1; then
      SILENCE_ID=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.silenceID')
      echo "✓ Silence created successfully!"
      echo "Silence ID: ''${SILENCE_ID}"
    else
      echo "✗ Failed to create silence"
      echo "Response: ''${RESPONSE}"
      exit 1
    fi
  '';
in
{
  options.hmFoundry.dev.monitoring = {
    enable = mkEnableOption "Advanced monitoring and diagnostic tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      glances
      viddy
      watch
      pv
      silence-host
    ];
  };
}

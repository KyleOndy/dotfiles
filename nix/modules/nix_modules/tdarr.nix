{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.tdarr;
  serverCfg = config.systemFoundry.tdarr.server;
  nodeCfg = config.systemFoundry.tdarr.node;
in
{
  options.systemFoundry.tdarr = {
    server = {
      enable = mkEnableOption "Tdarr server";

      mediaPath = mkOption {
        type = types.path;
        description = "Path to media files on the server";
        example = "/mnt/storage/media";
      };

      domainName = mkOption {
        type = types.str;
        description = "Domain name for Tdarr web UI";
        example = "tdarr.apps.ondy.org";
      };

      provisionCert = mkOption {
        type = types.bool;
        default = true;
        description = "Provision SSL certificate for this service";
      };

      webUIPort = mkOption {
        type = types.port;
        default = 8265;
        description = "Port for Tdarr web UI";
      };

      serverPort = mkOption {
        type = types.port;
        default = 8266;
        description = "Port for Tdarr server communication";
      };

      stateDir = mkOption {
        type = types.path;
        default = "/var/lib/tdarr";
        description = "Directory for Tdarr server state";
      };

      enableAuth = mkOption {
        type = types.bool;
        default = true;
        description = "Enable authentication for Tdarr web UI";
      };

      authSecretKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing auth secret key (optional, auto-generated if not provided)";
        example = "config.sops.secrets.tdarr_auth_secret.path";
      };

      seededApiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing seeded API key for node authentication (must start with tapi_, 14+ chars)";
        example = "config.sops.secrets.tdarr_api_key.path";
      };

      flows = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Descriptive name for this flow";
                example = "H.264 Compatibility Flow";
              };
              file = mkOption {
                type = types.path;
                description = "Path to the Tdarr flow JSON file";
                example = "./tdarr-compatibility-flow.json";
              };
            };
          }
        );
        default = [ ];
        description = "List of Tdarr flows to import via API on service startup";
      };

      libraryFlowAssignments = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Map of library names to flow IDs to assign";
        example = {
          "TV" = "C2cKnC3dx";
          "Movies" = "C2cKnC3dx";
        };
      };
    };

    node = {
      enable = mkEnableOption "Tdarr node";

      serverUrl = mkOption {
        type = types.str;
        description = "URL to Tdarr server";
        example = "http://10.10.0.1:8266";
      };

      mediaPath = mkOption {
        type = types.path;
        description = "Path to media files on the node";
        example = "/mnt/media";
      };

      nodeName = mkOption {
        type = types.str;
        description = "Name for this Tdarr node";
        example = "bear";
      };

      gpuWorkers = mkOption {
        type = types.int;
        default = 1;
        description = "Number of GPU workers for transcoding";
      };

      cpuWorkers = mkOption {
        type = types.int;
        default = 2;
        description = "Number of CPU workers for transcoding";
      };

      enableGpu = mkOption {
        type = types.bool;
        default = false;
        description = "Enable GPU passthrough for hardware transcoding";
      };

      pathTranslators = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              from = mkOption {
                type = types.str;
                description = "Server path";
                example = "/mnt/storage/media";
              };
              to = mkOption {
                type = types.str;
                description = "Node path";
                example = "/mnt/media";
              };
            };
          }
        );
        default = [ ];
        description = "Path mappings from server paths to node paths";
      };

      apiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing API key for server authentication";
        example = "config.sops.secrets.tdarr_api_key.path";
      };

      stateDir = mkOption {
        type = types.path;
        default = "/var/lib/tdarr-node";
        description = "Directory for Tdarr node state";
      };

      cacheDir = mkOption {
        type = types.path;
        default = "/var/cache/tdarr-node";
        description = "Directory for Tdarr node transcode cache";
      };
    };
  };

  config = mkMerge [
    # Server configuration
    (mkIf serverCfg.enable {
      # Use Podman for OCI containers
      virtualisation.oci-containers.backend = "podman";

      # Create state directories
      systemd.tmpfiles.rules = [
        "d ${serverCfg.stateDir}/server 0755 root root -"
        "d ${serverCfg.stateDir}/configs 0755 root root -"
        "d ${serverCfg.stateDir}/logs 0755 root root -"
      ];

      # Tdarr server container
      virtualisation.oci-containers.containers.tdarr-server = {
        image = "ghcr.io/haveagitgat/tdarr:latest";
        autoStart = true;
        ports = [
          "${toString serverCfg.webUIPort}:8265"
          "${toString serverCfg.serverPort}:8266"
        ];
        environment = {
          serverIP = "0.0.0.0";
          serverPort = toString serverCfg.serverPort;
          webUIPort = toString serverCfg.webUIPort;
          internalNode = "false"; # External nodes only
          TZ = "America/New_York";
          auth = if serverCfg.enableAuth then "true" else "false";
        };
        volumes = [
          "${serverCfg.stateDir}/server:/app/server"
          "${serverCfg.stateDir}/configs:/app/configs"
          "${serverCfg.stateDir}/logs:/app/logs"
          "${serverCfg.mediaPath}:${serverCfg.mediaPath}:ro"
        ];
      };

      # Nginx reverse proxy for web UI
      systemFoundry.nginxReverseProxy.sites."${serverCfg.domainName}" = {
        enable = true;
        proxyPass = "http://127.0.0.1:${toString serverCfg.webUIPort}";
        provisionCert = serverCfg.provisionCert;
      };

      # Inject secrets via systemd service override
      systemd.services.podman-tdarr-server =
        mkIf (serverCfg.authSecretKeyFile != null || serverCfg.seededApiKeyFile != null)
          {
            serviceConfig.ExecStart = mkForce (
              pkgs.writeShellScript "podman-tdarr-server-start-with-secrets" ''
                set -e
                ${optionalString (serverCfg.authSecretKeyFile != null) ''
                  export authSecretKey=$(cat ${serverCfg.authSecretKeyFile})
                ''}
                ${optionalString (serverCfg.seededApiKeyFile != null) ''
                  export seededApiKey=$(cat ${serverCfg.seededApiKeyFile})
                ''}
                exec ${pkgs.podman}/bin/podman run \
                  --name=tdarr-server \
                  --log-driver=journald \
                  --cidfile=/run/tdarr-server/ctr-id \
                  --cgroups=enabled \
                  --sdnotify=conmon \
                  -d --replace --rm \
                  -p ${toString serverCfg.webUIPort}:8265 \
                  -p ${toString serverCfg.serverPort}:8266 \
                  -e serverIP=0.0.0.0 \
                  -e serverPort=${toString serverCfg.serverPort} \
                  -e webUIPort=${toString serverCfg.webUIPort} \
                  -e internalNode=false \
                  -e TZ=America/New_York \
                  -e auth=${if serverCfg.enableAuth then "true" else "false"} \
                  ${optionalString (serverCfg.authSecretKeyFile != null) ''-e authSecretKey="$authSecretKey"''} \
                  ${optionalString (serverCfg.seededApiKeyFile != null) ''-e seededApiKey="$seededApiKey"''} \
                  -v ${serverCfg.stateDir}/server:/app/server \
                  -v ${serverCfg.stateDir}/configs:/app/configs \
                  -v ${serverCfg.stateDir}/logs:/app/logs \
                  -v ${serverCfg.mediaPath}:${serverCfg.mediaPath}:ro \
                  ghcr.io/haveagitgat/tdarr:latest
              ''
            );
          };

      # Flow import service - uses Tdarr cruddb API to import flows
      # This approach uses the official API to insert/update flows dynamically
      # Library assignments currently need to be done manually via Tdarr UI
      systemd.services.tdarr-flow-manager = mkIf (serverCfg.flows != [ ]) {
        description = "Tdarr Flow Import via cruddb API";
        after = [ "podman-tdarr-server.service" ];
        requires = [ "podman-tdarr-server.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -e

          ${optionalString (serverCfg.seededApiKeyFile != null) ''
            # Load API key for authentication
            API_KEY=$(cat ${serverCfg.seededApiKeyFile})
          ''}

          # Wait for Tdarr server to be ready (max 60 seconds)
          echo "Waiting for Tdarr server to be ready..."
          for i in $(seq 1 30); do
            if ${pkgs.curl}/bin/curl -s http://127.0.0.1:${toString serverCfg.webUIPort}/api/v2/status >/dev/null 2>&1; then
              echo "Tdarr server is ready"
              break
            fi
            if [ $i -eq 30 ]; then
              echo "ERROR: Tdarr server did not become ready in time"
              exit 1
            fi
            sleep 2
          done

          # Import flows using cruddb API
          ${concatMapStringsSep "\n" (flow: ''
            echo ""
            echo "=== Importing flow: ${flow.name} ==="

            # Read flow JSON and extract _id
            FLOW_DATA=$(cat ${flow.file})
            FLOW_ID=$(echo "$FLOW_DATA" | ${pkgs.jq}/bin/jq -r '._id // empty')

            if [ -z "$FLOW_ID" ]; then
              echo "WARNING: Flow ${flow.name} does not have an _id field, skipping import"
              echo "To import this flow, add a fixed _id field to the JSON and redeploy"
              continue
            fi

            echo "Flow ID: $FLOW_ID"

            # Prepare API request payload - insert mode
            API_PAYLOAD=$(${pkgs.jq}/bin/jq -n \
              --argjson flowData "$FLOW_DATA" \
              '{
                data: {
                  collection: "FlowsJSONDB",
                  mode: "insert",
                  docID: $flowData._id,
                  obj: $flowData
                }
              }')

            # Try to insert the flow
            echo "Attempting to insert flow via cruddb API..."
            ${optionalString (serverCfg.seededApiKeyFile != null) ''
              RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                "http://127.0.0.1:${toString serverCfg.webUIPort}/api/v2/cruddb" \
                -H "Content-Type: application/json" \
                -H "x-api-key: $API_KEY" \
                -d "$API_PAYLOAD" 2>&1 || echo "CURL_FAILED")
            ''}
            ${optionalString (serverCfg.seededApiKeyFile == null) ''
              RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                "http://127.0.0.1:${toString serverCfg.webUIPort}/api/v2/cruddb" \
                -H "Content-Type: application/json" \
                -d "$API_PAYLOAD" 2>&1 || echo "CURL_FAILED")
            ''}

            # Extract HTTP code from response (curl adds it with -w flag)
            HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
            BODY=$(echo "$RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')

            # Check if the request succeeded (HTTP 200 = success, even with empty body)
            if [ "$HTTP_CODE" = "200" ]; then
              echo "✓ Flow imported successfully: ${flow.name}"
            elif [ "$HTTP_CODE" != "200" ] && [ -n "$BODY" ]; then
              # Parse error from response body
              STATUS=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.status // .statusCode // 0')
              MESSAGE=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.message // .error // "Unknown error"')

              # Check if it's a duplicate/exists error
              if echo "$MESSAGE" | grep -qi "exists\|duplicate\|already"; then
                echo "Flow already exists, updating instead..."

                # Prepare update request
                API_PAYLOAD=$(${pkgs.jq}/bin/jq -n \
                  --argjson flowData "$FLOW_DATA" \
                  '{
                    data: {
                      collection: "FlowsJSONDB",
                      mode: "update",
                      docID: $flowData._id,
                      obj: $flowData
                    }
                  }')

                ${optionalString (serverCfg.seededApiKeyFile != null) ''
                  RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
                    "http://127.0.0.1:${toString serverCfg.webUIPort}/api/v2/cruddb" \
                    -H "Content-Type: application/json" \
                    -H "x-api-key: $API_KEY" \
                    -d "$API_PAYLOAD")
                ''}
                ${optionalString (serverCfg.seededApiKeyFile == null) ''
                  RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
                    "http://127.0.0.1:${toString serverCfg.webUIPort}/api/v2/cruddb" \
                    -H "Content-Type: application/json" \
                    -d "$API_PAYLOAD")
                ''}

                HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
                if [ "$HTTP_CODE" = "200" ]; then
                  echo "✓ Flow updated successfully: ${flow.name}"
                else
                  echo "ERROR: Failed to update flow (HTTP $HTTP_CODE)"
                  exit 1
                fi
              else
                echo "ERROR: Failed to import flow (HTTP $HTTP_CODE): $MESSAGE"
                echo "Full response: $BODY"
                exit 1
              fi
            fi
          '') serverCfg.flows}

          ${optionalString (serverCfg.libraryFlowAssignments != { }) ''
            echo ""
            echo "=== Library Flow Assignments ==="
            echo "NOTE: Library flow assignments need to be configured manually in Tdarr UI"
            echo "Please assign the following flows to libraries:"
            ${concatStringsSep "\n" (
              mapAttrsToList (library: flowId: ''
                echo "  - Library '${library}' -> Flow '${flowId}'"
              '') serverCfg.libraryFlowAssignments
            )}
            echo ""
            echo "To assign flows to libraries in Tdarr:"
            echo "1. Go to Libraries tab"
            echo "2. Click on each library"
            echo "3. Select the flow from the dropdown"
            echo "4. Save changes"
          ''}

          echo ""
          echo "Flow import process completed successfully"
        '';
      };
    })

    # Node configuration
    (mkIf nodeCfg.enable {
      # Use Podman for OCI containers
      virtualisation.oci-containers.backend = "podman";

      # Create state directories
      systemd.tmpfiles.rules = [
        "d ${nodeCfg.stateDir}/configs 0755 root root -"
        "d ${nodeCfg.stateDir}/logs 0755 root root -"
        "d ${nodeCfg.cacheDir} 0755 root root -"
      ];

      # Tdarr node container
      virtualisation.oci-containers.containers.tdarr-node = {
        image = "ghcr.io/haveagitgat/tdarr_node:latest";
        autoStart = true;
        environment = {
          serverURL = nodeCfg.serverUrl;
          nodeName = nodeCfg.nodeName;
          TZ = "America/New_York";
          PUID = "0"; # Run as root for device access
          PGID = "0";
        }
        // optionalAttrs (nodeCfg.pathTranslators != [ ]) {
          pathTranslators = builtins.toJSON (
            map (t: {
              server = t.from;
              node = t.to;
            }) nodeCfg.pathTranslators
          );
        };
        volumes = [
          "${nodeCfg.stateDir}/configs:/app/configs"
          "${nodeCfg.stateDir}/logs:/app/logs"
          "${nodeCfg.cacheDir}:/temp"
          "${nodeCfg.mediaPath}:${nodeCfg.mediaPath}"
        ];
        extraOptions = [ "--network=host" ] ++ optional nodeCfg.enableGpu "--device=/dev/dri:/dev/dri";
      };

      # Inject API key via systemd service override
      systemd.services.podman-tdarr-node = mkIf (nodeCfg.apiKeyFile != null) {
        serviceConfig = {
          EnvironmentFile = pkgs.writeText "tdarr-node-env-template" "apiKey=placeholder";
        };
        # Override the ExecStart to include the apiKey environment variable
        serviceConfig.ExecStart = mkForce (
          pkgs.writeShellScript "podman-tdarr-node-start-with-key" ''
            set -e
            export apiKey=$(cat ${nodeCfg.apiKeyFile})
            exec ${pkgs.podman}/bin/podman run \
              --name=tdarr-node \
              --log-driver=journald \
              --cidfile=/run/tdarr-node/ctr-id \
              --cgroups=enabled \
              --sdnotify=conmon \
              -d --replace \
              -e PUID=0 -e PGID=0 \
              -e TZ=America/New_York \
              -e serverURL=${nodeCfg.serverUrl} \
              -e nodeName=${nodeCfg.nodeName} \
              ${
                optionalString (nodeCfg.pathTranslators != [ ])
                  "-e pathTranslators='${
                    builtins.toJSON (
                      map (t: {
                        server = t.from;
                        node = t.to;
                      }) nodeCfg.pathTranslators
                    )
                  }'"
              } \
              -e apiKey="$apiKey" \
              -v ${nodeCfg.stateDir}/configs:/app/configs \
              -v ${nodeCfg.stateDir}/logs:/app/logs \
              -v ${nodeCfg.cacheDir}:/temp \
              -v ${nodeCfg.mediaPath}:${nodeCfg.mediaPath} \
              ${
                optionalString (
                  nodeCfg.pathTranslators != [ ]
                ) "-v ${nodeCfg.mediaPath}:${(builtins.head nodeCfg.pathTranslators).from}"
              } \
              --network=host \
              ${optionalString nodeCfg.enableGpu "--device=/dev/dri:/dev/dri"} \
              ghcr.io/haveagitgat/tdarr_node:latest
          ''
        );
      };
    })
  ];
}

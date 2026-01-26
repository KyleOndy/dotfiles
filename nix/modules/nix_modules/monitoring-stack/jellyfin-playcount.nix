{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.jellyfinPlaycount;

  # Python script to export Jellyfin play counts
  jellyfinPlaycountScript = pkgs.writeScriptBin "jellyfin-playcount-exporter" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    import sys
    import urllib.request
    import urllib.error
    from datetime import datetime
    from time import time

    API_KEY_FILE = "${cfg.apiKeyFile}"
    JELLYFIN_URL = "${cfg.jellyfinUrl}"
    OUTPUT_FILE = "${cfg.textfileDirectory}/jellyfin-playcounts.prom"
    OUTPUT_TMP = OUTPUT_FILE + ".tmp"

    def read_api_key():
        with open(API_KEY_FILE, "r") as f:
            return f.read().strip()

    def jellyfin_api_request(endpoint):
        api_key = read_api_key()
        url = f"{JELLYFIN_URL}{endpoint}"
        headers = {"X-MediaBrowser-Token": api_key}

        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.loads(response.read().decode())
        except urllib.error.URLError as e:
            print(f"Error querying Jellyfin API: {e}", file=sys.stderr)
            sys.exit(1)

    def sanitize_label(s):
        """Sanitize string for Prometheus label value"""
        # Escape backslashes first, then quotes, then newlines
        return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')

    def get_users():
        """Get all users or a specific user based on configuration"""
        if ${if cfg.monitorAllUsers then "True" else "False"}:
            # Get all users
            users_response = jellyfin_api_request("/Users")
            return users_response
        else:
            # Get specific user
            user_id = "${toString cfg.userId}"
            if not user_id or user_id == "null":
                print("Error: userId must be specified when monitorAllUsers is false", file=sys.stderr)
                sys.exit(1)
            user = jellyfin_api_request(f"/Users/{user_id}")
            return [user]

    def main():
        users = get_users()
        all_metrics = []
        global_never_played_counts = {}

        for user in users:
            user_id = user.get("Id")
            username = sanitize_label(user.get("Name", "Unknown"))

            # Get all items with play count information for this user
            # Recursive=true gets all items in all libraries
            params = "Recursive=true&Fields=PlayCount,DateLastPlayed,DateCreated,ProviderIds&IncludeItemTypes=Movie,Series,Episode,Audio,MusicAlbum,Book"
            items = jellyfin_api_request(f"/Users/{user_id}/Items?{params}")

            user_never_played_counts = {}

            for item in items.get("Items", []):
                item_type = item.get("Type", "Unknown")
                item_id = item.get("Id", "")
                title = sanitize_label(item.get("Name", "Unknown"))
                play_count = item.get("UserData", {}).get("PlayCount", 0)

                # Get year from PremiereDate or DateCreated
                year = ""
                if "PremiereDate" in item:
                    year = item["PremiereDate"][:4]
                elif "ProductionYear" in item:
                    year = str(item["ProductionYear"])

                # Track items by type
                if play_count == 0:
                    user_never_played_counts[item_type] = user_never_played_counts.get(item_type, 0) + 1
                    global_never_played_counts[item_type] = global_never_played_counts.get(item_type, 0) + 1

                # Add play count metric with user label
                labels = f"item_id=\"{item_id}\",title=\"{title}\",type=\"{item_type}\",user_id=\"{user_id}\",username=\"{username}\""
                if year:
                    labels += f",year=\"{year}\""
                all_metrics.append(f"jellyfin_item_play_count{{{labels}}} {play_count}")

                # Add last played timestamp
                if "LastPlayedDate" in item.get("UserData", {}):
                    last_played = item["UserData"]["LastPlayedDate"]
                    # Convert ISO timestamp to epoch
                    dt = datetime.fromisoformat(last_played.replace("Z", "+00:00"))
                    epoch = int(dt.timestamp())
                    all_metrics.append(f"jellyfin_item_last_played_timestamp{{{labels}}} {epoch}")

                # Add creation timestamp
                if "DateCreated" in item:
                    created = item["DateCreated"]
                    dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                    epoch = int(dt.timestamp())
                    all_metrics.append(f"jellyfin_item_added_timestamp{{{labels}}} {epoch}")

            # Add per-user never-played counts
            for item_type, count in user_never_played_counts.items():
                all_metrics.append(f"jellyfin_never_played_items_by_user{{type=\"{item_type}\",user_id=\"{user_id}\",username=\"{username}\"}} {count}")

        # Add global never-played counts by type
        for item_type, count in global_never_played_counts.items():
            all_metrics.append(f"jellyfin_never_played_items_total{{type=\"{item_type}\"}} {count}")

        # Add export success metrics
        all_metrics.append(f"jellyfin_playcount_export_timestamp {int(time())}")
        all_metrics.append(f"jellyfin_playcount_export_metrics_total {len(all_metrics)}")

        metrics = all_metrics

        # Write metrics to temp file then rename (atomic update)
        with open(OUTPUT_TMP, "w") as f:
            f.write("# HELP jellyfin_item_play_count Number of times an item has been played\n")
            f.write("# TYPE jellyfin_item_play_count gauge\n")
            f.write("# HELP jellyfin_item_last_played_timestamp Unix timestamp when item was last played\n")
            f.write("# TYPE jellyfin_item_last_played_timestamp gauge\n")
            f.write("# HELP jellyfin_item_added_timestamp Unix timestamp when item was added to library\n")
            f.write("# TYPE jellyfin_item_added_timestamp gauge\n")
            f.write("# HELP jellyfin_never_played_items_total Count of items that have never been played\n")
            f.write("# TYPE jellyfin_never_played_items_total gauge\n")
            f.write("# HELP jellyfin_playcount_export_timestamp Unix timestamp of last successful export\n")
            f.write("# TYPE jellyfin_playcount_export_timestamp gauge\n")
            f.write("# HELP jellyfin_playcount_export_metrics_total Total metrics exported in last run\n")
            f.write("# TYPE jellyfin_playcount_export_metrics_total gauge\n")
            for metric in metrics:
                f.write(metric + "\n")

        os.rename(OUTPUT_TMP, OUTPUT_FILE)
        print(f"Exported {len(metrics)} metrics to {OUTPUT_FILE}")

    if __name__ == "__main__":
        main()
  '';
in
{
  options.systemFoundry.monitoringStack.jellyfinPlaycount = {
    enable = mkEnableOption "Jellyfin play count exporter (textfile collector)";

    jellyfinUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8096";
      description = "URL to Jellyfin server";
    };

    apiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Jellyfin API key";
    };

    monitorAllUsers = mkOption {
      type = types.bool;
      default = true;
      description = "Monitor all users (true) or specify a single user ID (false)";
    };

    userId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Jellyfin user ID to query play counts for (only used if monitorAllUsers = false)";
      example = "a1b2c3d4e5f6g7h8i9j0";
    };

    textfileDirectory = mkOption {
      type = types.str;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "Directory where node_exporter textfile collector reads from";
    };

    schedule = mkOption {
      type = types.str;
      default = "daily";
      description = "Systemd timer schedule (OnCalendar format)";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.jellyfin-playcount-exporter = {
      description = "Export Jellyfin play counts for Prometheus";
      after = [ "jellyfin.service" ];
      wants = [ "jellyfin.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${jellyfinPlaycountScript}/bin/jellyfin-playcount-exporter";
        User = "jellyfin-playcount";
        Group = "jellyfin-playcount";
      };
    };

    systemd.timers.jellyfin-playcount-exporter = {
      description = "Timer for Jellyfin play count export";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # Create user for the service
    users.users.jellyfin-playcount = {
      isSystemUser = true;
      group = "jellyfin-playcount";
      extraGroups = [ "node-exporter" ];
      description = "Jellyfin playcount exporter user";
    };

    users.groups.jellyfin-playcount = { };

    # Ensure textfile directory exists and is writable
    systemd.tmpfiles.rules = [
      "d ${cfg.textfileDirectory} 0775 node-exporter node-exporter -"
      "Z ${cfg.textfileDirectory} 0775 node-exporter node-exporter -"
      "f ${cfg.textfileDirectory}/jellyfin-playcounts.prom 0664 jellyfin-playcount node-exporter -"
    ];
  };
}

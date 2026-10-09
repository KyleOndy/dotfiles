# Lidarr keeps its settings in its own database, not in config.xml, so the
# NixOS module cannot reach them. This oneshot pushes them through the API on
# every deploy that changes them. What it manages it owns outright: a change
# made in the UI to any of it is reverted on the next run.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.lidarrSettings;

  # Quality IDs from Lidarr's Quality.cs. Order within a profile comes from the
  # template profile, so the last allowed ID is the best one.
  profiles = {
    # MP3-VBR-V0, AAC-VBR, MP3-320, OGG Vorbis Q9, AAC-320, OGG Vorbis Q10
    Lossy = [
      2
      12
      4
      15
      11
      14
    ];
    # 16-bit FLAC only. 24-bit is mostly vinyl rips and needle-drops that
    # import badly and cost three times the space for nothing audible.
    Lossless = [ 6 ];
  };

  # Types the Standard metadata profile shows. Showing a release only lists it;
  # nothing is grabbed unless it is monitored.
  primaryAlbumTypes = [
    "Album"
    "EP"
    "Single"
  ];
  secondaryAlbumTypes = [
    "Studio"
    "Soundtrack"
  ];

  settings = pkgs.writeText "lidarr-settings.json" (
    builtins.toJSON {
      inherit profiles primaryAlbumTypes secondaryAlbumTypes;
      inherit (cfg) spotifyPlaylists rejectTerms;
      losslessArtists = attrValues cfg.losslessArtists;
      excludedArtists = mapAttrsToList (name: mbid: {
        artistName = name;
        foreignId = mbid;
      }) cfg.excludedArtists;
    }
  );

  artistMap = mkOption {
    type = types.attrsOf types.str;
    default = { };
    description = "Artist name to MusicBrainz artist ID. The name is only a label.";
  };
in
{
  options.systemFoundry.lidarrSettings = {
    enable = mkEnableOption "declarative Lidarr profiles, import list and exclusions";

    url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8686";
    };

    apiKeyFile = mkOption {
      type = types.path;
    };

    spotifyPlaylists = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Spotify playlist IDs the existing Spotify Playlists import list
        watches. Empty turns the list's automatic add off. Each playlist adds
        only the albums its tracks are on, with no future releases monitored.
        The list itself, and its OAuth sign-in, are made in the UI.
      '';
    };

    losslessArtists = artistMap // {
      description = ''
        Artists on the Lossless profile. Every other artist is set to Lossy.
        The name is only a label; the MusicBrainz ID is what matches.
      '';
    };

    excludedArtists = artistMap // {
      description = ''
        The complete import list exclusion set: import lists never add these
        artists. Exclusions added in the UI that are not here are deleted.
        Excluding an artist already in the library does not remove it.
      '';
    };

    rejectTerms = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Release names containing any of these are never grabbed.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.lidarr-settings = {
      description = "Apply declarative Lidarr settings";
      after = [ "lidarr.service" ];
      wants = [ "lidarr.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.curl
        pkgs.jq
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [ "lidarr:${cfg.apiKeyFile}" ];

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };

      script = ''
        set -euo pipefail

        readonly URL="${cfg.url}/api/v1"
        readonly SETTINGS="${settings}"
        key=$(cat "$CREDENTIALS_DIRECTORY/lidarr")

        api() {
          local method="$1" path="$2"
          shift 2
          curl -sf --max-time 120 -X "$method" -H "X-Api-Key: $key" \
            -H 'Content-Type: application/json' "$URL/$path" "$@"
        }

        # Lidarr answers on its port well before its API is ready.
        for _ in $(seq 60); do
          api GET system/status >/dev/null 2>&1 && break
          sleep 5
        done
        api GET system/status >/dev/null

        # Groups are flattened so a single quality inside one can be allowed
        # alone. Any existing profile serves as the template: every profile
        # carries the full quality list.
        template=$(api GET qualityprofile | jq '.[0]')
        for name in $(jq -r '.profiles | keys[]' "$SETTINGS"); do
          body=$(jq -n --argjson t "$template" --arg name "$name" \
            --argjson ids "$(jq -c --arg n "$name" '.profiles[$n]' "$SETTINGS")" '
            [ $t.items[] | if (.items | length) > 0 then .items[] else . end ]
            | map({ quality, items: [], allowed: (.quality.id as $q | $ids | index($q) != null) })
            | {
                name: $name,
                upgradeAllowed: false,
                items: .,
                cutoff: ([ .[] | select(.allowed) | .quality.id ] | last),
                minFormatScore: 0,
                cutoffFormatScore: 0,
                formatItems: $t.formatItems
              }')
          id=$(api GET qualityprofile | jq --arg n "$name" '.[] | select(.name == $n) | .id')
          if [ -n "$id" ]; then
            api PUT "qualityprofile/$id" -d "$(jq --argjson id "$id" '. + {id: $id}' <<< "$body")" >/dev/null
          else
            api POST qualityprofile -d "$body" >/dev/null
          fi
        done
        profiles=$(api GET qualityprofile)
        lossy=$(jq '.[] | select(.name == "Lossy") | .id' <<< "$profiles")
        lossless=$(jq '.[] | select(.name == "Lossless") | .id' <<< "$profiles")

        artists=$(api GET artist)
        to_lossless=$(jq -c --slurpfile s "$SETTINGS" --argjson p "$lossless" '
          [ .[] | select(.foreignArtistId as $m | $s[0].losslessArtists | index($m))
                | select(.qualityProfileId != $p) | .id ]' <<< "$artists")
        to_lossy=$(jq -c --slurpfile s "$SETTINGS" --argjson p "$lossy" '
          [ .[] | select(.foreignArtistId as $m | $s[0].losslessArtists | index($m) | not)
                | select(.qualityProfileId != $p) | .id ]' <<< "$artists")
        for pair in "$lossless:$to_lossless" "$lossy:$to_lossy"; do
          ids="''${pair#*:}"
          [ "$ids" = "[]" ] && continue
          api PUT artist/editor -d "{\"artistIds\": $ids, \"qualityProfileId\": ''${pair%%:*}}" >/dev/null
        done

        while IFS= read -r root; do
          api PUT "rootfolder/$(jq .id <<< "$root")" -d "$(jq --argjson p "$lossy" '
            . + {defaultQualityProfileId: $p, defaultNewItemMonitorOption: "none"}' <<< "$root")" >/dev/null
        done < <(api GET rootfolder | jq -c '.[]')

        standard=$(api GET metadataprofile | jq -c '.[] | select(.name == "Standard")')
        api PUT "metadataprofile/$(jq .id <<< "$standard")" -d "$(jq --slurpfile s "$SETTINGS" '
          .primaryAlbumTypes |= map(.allowed = (.albumType.name as $n | $s[0].primaryAlbumTypes | index($n) != null))
          | .secondaryAlbumTypes |= map(.allowed = (.albumType.name as $n | $s[0].secondaryAlbumTypes | index($n) != null))' <<< "$standard")" >/dev/null

        # forceSave skips the connection test, which fails on an empty
        # playlist list.
        list=$(api GET importlist | jq -c '.[] | select(.implementation == "SpotifyPlaylist")')
        if [ -n "$list" ]; then
          api PUT "importlist/$(jq .id <<< "$list")?forceSave=true" -d "$(jq --slurpfile s "$SETTINGS" --argjson p "$lossy" '
            .enableAutomaticAdd = ($s[0].spotifyPlaylists | length > 0)
            | .shouldMonitor = "specificAlbum"
            | .monitorNewItems = "none"
            | .qualityProfileId = $p
            | .fields |= map(if .name == "playlistIds" then .value = $s[0].spotifyPlaylists else . end)' <<< "$list")" >/dev/null
        else
          echo "no Spotify Playlists import list; sign in to Spotify in the UI to create it"
        fi

        # Lidarr's release profiles have no name, so the first is ours and the
        # rest are removed.
        release=$(jq -c '{enabled: true, required: [], ignored: .rejectTerms, indexerId: 0, tags: []}' "$SETTINGS")
        existing=$(api GET releaseprofile | jq '[.[].id]')
        if [ "$(jq length <<< "$existing")" -gt 0 ]; then
          api PUT "releaseprofile/$(jq '.[0]' <<< "$existing")" \
            -d "$(jq --argjson id "$(jq '.[0]' <<< "$existing")" '. + {id: $id}' <<< "$release")" >/dev/null
        else
          api POST releaseprofile -d "$release" >/dev/null
        fi
        for id in $(jq '.[1:][]' <<< "$existing"); do
          api DELETE "releaseprofile/$id" >/dev/null
        done

        exclusions=$(api GET importlistexclusion)
        while IFS= read -r row; do
          api POST importlistexclusion -d "$row" >/dev/null
        done < <(jq -c --argjson have "$exclusions" '
            .excludedArtists[] | select(.foreignId as $m | $have | map(.foreignId) | index($m) | not)' "$SETTINGS")
        for id in $(jq --slurpfile s "$SETTINGS" '
            .[] | select(.foreignId as $m | $s[0].excludedArtists | map(.foreignId) | index($m) | not) | .id' <<< "$exclusions"); do
          api DELETE "importlistexclusion/$id" >/dev/null
        done

        # Profiles nothing references any more. Lidarr refuses to delete one
        # still in use, which leaves it for the next run.
        for id in $(jq '.[] | select(.name != "Lossy" and .name != "Lossless") | .id' <<< "$profiles"); do
          api DELETE "qualityprofile/$id" >/dev/null || echo "quality profile $id still in use, kept"
        done
      '';
    };
  };
}

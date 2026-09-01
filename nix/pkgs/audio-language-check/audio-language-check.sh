#!/usr/bin/env bash
# Verifies an imported file carries an English audio track, for Radarr and
# Sonarr "Custom Script" connections firing on the Download event.
#
# Container tags answer this for most files at no cost. Whisper is the
# fallback for the minority tagged "und" or carrying no tag at all, which is
# the only case a tag cannot settle.
set -euo pipefail

readonly WHISPER_MODEL="${WHISPER_MODEL:?WHISPER_MODEL must point at a ggml model}"
readonly ENFORCE="${AUDIO_LANG_ENFORCE:-0}"
readonly SAMPLES="${AUDIO_LANG_SAMPLES:-3}"
# Whisper reports a probability per sample; below this a vote is discarded
# rather than counted, because a sample landing on score or action returns a
# confident-looking guess from nothing.
readonly MIN_CONFIDENCE="${AUDIO_LANG_MIN_CONFIDENCE:-0.6}"
# Some releases carry a dozen dub tracks; examining every one costs more than
# the answer is worth once the first few have not turned up English.
readonly MAX_STREAMS="${AUDIO_LANG_MAX_STREAMS:-6}"

log() {
	logger -t audio-language-check -- "$*"
	echo "$*" >&2
}

api() {
	local base="$1" key="$2" path="$3"
	curl -sf -H "X-Api-Key: $key" "${base}${path}"
}

# Each service can read its own config.xml, so the key it already owns is the
# one credential this needs. The sops copies are 0440 root:exportarr and are
# not readable by the radarr and sonarr users that run this script.
read_api_key() {
	local override="$1" config="$2"
	if [ -n "$override" ]; then
		cat "$override"
		return
	fi
	grep -o '<ApiKey>[^<]*</ApiKey>' "$config" | sed 's/<[^>]*>//g'
}

# ISO 639-2/B "eng" and 639-1 "en" both appear in the wild; anything else,
# including the literal "默认" seen on some releases, is not a claim of English.
has_english_tag() {
	case ",$1," in
	*,eng,* | *,en,*) return 0 ;;
	*) return 1 ;;
	esac
}

# A tag settles the question only when it is actually a language code. ISO 639
# codes are two or three ASCII letters; releases in the wild also carry "und"
# and, from at least one encoder, the literal string "默认" (Chinese for
# "default"), which is a mislabelled track rather than a claim about audio.
# Anything unparseable goes to whisper instead of being failed on its face.
tags_are_unknown() {
	local langs="$1" tag
	local -a tags=()
	if [ "$langs" = "NONE" ] || [ -z "$langs" ]; then return 0; fi
	IFS=',' read -r -a tags <<<"$langs"
	for tag in "${tags[@]}"; do
		[ "$tag" = und ] && continue
		[[ $tag =~ ^[a-z]{2,3}$ ]] && return 1
	done
	return 0
}

audio_langs() {
	local f="$1" out
	out=$(ffprobe -v error -select_streams a -show_entries stream_tags=language \
		-of csv=p=0 "$f" 2>/dev/null | paste -sd, - || true)
	[ -z "$out" ] && out="NONE"
	printf '%s' "$out"
}

# Majority vote over samples spread across one audio stream. A single sample
# is not evidence: a multilingual film answers differently depending where it
# lands, and a music cue answers from noise.
whisper_stream() {
	local f="$1" stream="$2" dur i frac ss out lang conf work best bestn
	dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
	if [ -z "$dur" ] || ! [ "$dur" -ge 60 ] 2>/dev/null; then
		printf 'unknown'
		return
	fi

	work=$(mktemp -d)
	local -A votes=()
	for ((i = 0; i < SAMPLES; i++)); do
		frac=$((25 + i * 50 / (SAMPLES > 1 ? SAMPLES - 1 : 1)))
		ss=$((dur * frac / 100))
		ffmpeg -v error -y -ss "$ss" -t 30 -i "$f" -map "0:a:$stream" -ac 1 -ar 16000 \
			-c:a pcm_s16le "$work/s.wav" 2>/dev/null || continue
		out=$(whisper-cli -m "$WHISPER_MODEL" -f "$work/s.wav" --detect-language 2>&1 |
			grep -oP 'auto-detected language: \K.*' || true)
		lang=${out%% *}
		conf=$(printf '%s' "$out" | grep -oP 'p = \K[0-9.]+' || echo 0)
		[ -z "$lang" ] && continue
		# A sample landing on score or silence still returns a language; the
		# floor is what keeps that from counting as a vote.
		awk -v c="$conf" -v m="$MIN_CONFIDENCE" 'BEGIN { exit !(c >= m) }' || continue
		votes[$lang]=$((${votes[$lang]:-0} + 1))
	done
	rm -rf "$work"

	best=unknown
	bestn=0
	for lang in "${!votes[@]}"; do
		if [ "${votes[$lang]}" -gt "$bestn" ]; then
			best="$lang"
			bestn=${votes[$lang]}
		fi
	done
	printf '%s' "$best"
}

# Every stream is examined, not just the one ffmpeg would play by default.
# Untagged dual-audio releases exist where track 1 is another language and
# track 2 is English, and judging such a file by its first track alone would
# condemn one that is perfectly watchable.
whisper_language() {
	local f="$1" nstreams stream lang best=unknown
	nstreams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null | wc -l)
	[ "$nstreams" -gt "$MAX_STREAMS" ] && nstreams="$MAX_STREAMS"
	if [ "$nstreams" -lt 1 ]; then
		printf 'unknown'
		return
	fi

	for ((stream = 0; stream < nstreams; stream++)); do
		lang=$(whisper_stream "$f" "$stream")
		# English anywhere settles it; the remaining streams need no examining.
		if [ "$lang" = en ]; then
			printf 'en'
			return
		fi
		[ "$best" = unknown ] && best="$lang"
	done
	printf '%s' "$best"
}

# Blocklists the grab. autoRedownloadFailed then drives the replacement search,
# so this function deliberately does not trigger one itself.
reject() {
	local base="$1" key="$2" download_id="$3" title="$4"
	if [ -z "$download_id" ]; then
		log "REJECT-SKIPPED $title: no download id in environment"
		return
	fi
	local hid
	hid=$(api "$base" "$key" "/api/v3/history?pageSize=200" |
		jq -r --arg d "$download_id" \
			'first(.records[] | select(.downloadId == $d and .eventType == "grabbed") | .id) // empty')
	if [ -z "$hid" ]; then
		log "REJECT-SKIPPED $title: no grabbed history row for downloadId=$download_id"
		return
	fi
	curl -sf -X POST -H "X-Api-Key: $key" "${base}/api/v3/history/failed/${hid}" >/dev/null
	log "REJECTED $title: blocklisted historyId=$hid, replacement search will follow"
}

main() {
	local service base key_config key_override event title orig_lang download_id
	local -a files=()

	if [ -n "${radarr_eventtype:-}" ]; then
		service=radarr
		base="${RADARR_URL:-http://127.0.0.1:7878}"
		key_config="${RADARR_CONFIG:-/var/lib/radarr/.config/Radarr/config.xml}"
		key_override="${RADARR_API_KEY_FILE:-}"
		event="$radarr_eventtype"
		title="${radarr_movie_title:-unknown}"
		download_id="${radarr_download_id:-}"
		[ -n "${radarr_moviefile_path:-}" ] && files=("$radarr_moviefile_path")
	elif [ -n "${sonarr_eventtype:-}" ]; then
		service=sonarr
		base="${SONARR_URL:-http://127.0.0.1:8989}"
		key_config="${SONARR_CONFIG:-/var/lib/sonarr/.config/NzbDrone/config.xml}"
		key_override="${SONARR_API_KEY_FILE:-}"
		event="$sonarr_eventtype"
		title="${sonarr_series_title:-unknown} ${sonarr_episodefile_episodenumbers:-}"
		download_id="${sonarr_download_id:-}"
		if [ -n "${sonarr_episodefile_paths:-}" ]; then
			# Sonarr joins multiple paths with "|".
			IFS='|' read -r -a files <<<"$sonarr_episodefile_paths"
		elif [ -n "${sonarr_episodefile_path:-}" ]; then
			files=("$sonarr_episodefile_path")
		fi
	else
		log "no radarr_/sonarr_ environment found; nothing to do"
		exit 0
	fi

	local key
	key=$(read_api_key "$key_override" "$key_config")

	if [ "$event" = "Test" ]; then
		log "test event from $service: ffprobe=$(command -v ffprobe) whisper=$(command -v whisper-cli) model=$WHISPER_MODEL enforce=$ENFORCE"
		exit 0
	fi
	[ ${#files[@]} -eq 0 ] && {
		log "$service $event: no file path in environment"
		exit 0
	}

	# A title whose own language is not English has no business being held to an
	# English audio track.
	if [ "$service" = radarr ]; then
		orig_lang=$(api "$base" "$key" "/api/v3/movie/${radarr_movie_id:-0}" |
			jq -r '.originalLanguage.name // "Unknown"')
	else
		orig_lang=$(api "$base" "$key" "/api/v3/series/${sonarr_series_id:-0}" |
			jq -r '.originalLanguage.name // "Unknown"')
	fi
	if [ "$orig_lang" != "English" ] && [ "$orig_lang" != "Unknown" ]; then
		log "SKIP $title: originalLanguage=$orig_lang"
		exit 0
	fi

	local f langs verdict
	for f in "${files[@]}"; do
		[ -f "$f" ] || {
			log "SKIP $title: missing file $f"
			continue
		}
		langs=$(audio_langs "$f")

		if has_english_tag "$langs"; then
			log "OK $title: tagged [$langs]"
			continue
		fi

		if tags_are_unknown "$langs"; then
			verdict=$(whisper_language "$f")
			if [ "$verdict" = en ]; then
				log "OK $title: untagged [$langs], whisper says en"
				continue
			fi
			log "FAIL $title: untagged [$langs], whisper says ${verdict}"
		else
			log "FAIL $title: tagged [$langs], no English track"
		fi

		if [ "$ENFORCE" = 1 ]; then
			reject "$base" "$key" "$download_id" "$title"
		else
			log "REPORT-ONLY: would reject $title ($(basename "$f"))"
		fi
	done
}

main "$@"

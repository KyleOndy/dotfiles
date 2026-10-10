#!/usr/bin/env bash
# Verifies an imported file carries an English audio track, for Radarr and
# Sonarr "Custom Script" connections firing on the Download event.
#
# On import, whisper hears every audio track and each tag is checked against
# it, which catches English audio tagged as another language and a dub tagged
# as English. The nightly sweep reads tags and falls back to whisper only for
# tracks tagged "und" or not at all.
set -euo pipefail

readonly WHISPER_MODEL="${WHISPER_MODEL:?WHISPER_MODEL must point at a ggml model}"
readonly ENFORCE="${AUDIO_LANG_ENFORCE:-0}"
# Twenty rather than a token few: a rejected import is blocklisted, and a
# relabel accepts the file, so a track whose English share sits near
# OVERRIDE_PERCENT needs enough samples to land on the right side of it. Each
# sample costs about 0.6 s of wall time. Many more stop helping: on a
# 22-minute episode, past about 30 the 30-second windows overlap.
readonly SAMPLES="${AUDIO_LANG_SAMPLES:-20}"
# Whisper reports a probability per sample; below this a vote is discarded
# rather than counted, because a sample landing on score or action returns a
# confident-looking guess from nothing.
readonly MIN_CONFIDENCE="${AUDIO_LANG_MIN_CONFIDENCE:-0.6}"
# Share of all samples, in percent, that must hear English before whisper
# overrides a tag naming another language. Dubs keep songs and credits in
# English, so a dub wins English votes honestly: a Portuguese dub of a musical
# drew 3 of 7. English under a wrong tag drew 7 of 7.
readonly OVERRIDE_PERCENT="${AUDIO_LANG_OVERRIDE_PERCENT:-70}"
# Sixteen-track dub releases are common in this library, and English sits
# second in some and much later in others. The import hook hears every track
# up to this cap, about twelve seconds each; the sweep stops at the first
# English one.
readonly MAX_STREAMS="${AUDIO_LANG_MAX_STREAMS:-12}"
# Write what whisper heard into the file: relabel a track whose tag was
# missing or hid English, and make the first English track the default.
# Matroska only; see check_file.
readonly FIX="${AUDIO_LANG_FIX:-0}"
# An alert carrying no path sends you back to the library to find the file
# yourself. One series per offender puts the paths in the mail, and the cap is
# what keeps a pathological library from turning that into thousands of them.
readonly MAX_SERIES="${AUDIO_LANG_MAX_SERIES:-50}"

# The hook learns these from the event environment; the sweep has to ask for
# itself, so both live here rather than inside the event dispatch.
readonly RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
readonly SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
readonly RADARR_CONFIG="${RADARR_CONFIG:-/var/lib/radarr/.config/Radarr/config.xml}"
readonly SONARR_CONFIG="${SONARR_CONFIG:-/var/lib/sonarr/.config/NzbDrone/config.xml}"

log() {
	logger -t audio-language-check -- "$*"
	echo "$*" >&2
}

api() {
	local base="$1" key="$2" path="$3"
	curl -sf -H "X-Api-Key: $key" "${base}${path}"
}

# Each service can read its own config.xml, so the key it already owns is the
# one credential this needs. The sops copies are 0400 root and are not
# readable by the radarr and sonarr users that run this script.
read_api_key() {
	local override="$1" config="$2"
	if [ -n "$override" ]; then
		cat "$override"
		return
	fi
	grep -o '<ApiKey>[^<]*</ApiKey>' "$config" | sed 's/<[^>]*>//g'
}

# Prometheus label values escape backslash and double quote; a newline in a
# filename would otherwise split one series into two unparseable lines.
escape_label() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

LANG_INDEX=""

# Radarr and Sonarr each know the folder a title sits in and the language it
# was made in, so one call to each answers for every file the sweep flags. The
# hook asks about a single id it was handed; a sweep walking the filesystem has
# only paths, which is why this matches on the folder instead.
build_lang_index() {
	if [ -n "$LANG_INDEX" ]; then
		return 0
	fi
	LANG_INDEX=$(mktemp)
	local key
	if [ -r "$RADARR_CONFIG" ]; then
		key=$(read_api_key "" "$RADARR_CONFIG")
		api "$RADARR_URL" "$key" "/api/v3/movie" 2>/dev/null |
			jq -r '.[] | select(.path != null) | "\(.path)\t\(.originalLanguage.name // "Unknown")"' \
				>>"$LANG_INDEX" 2>/dev/null || true
	fi
	if [ -r "$SONARR_CONFIG" ]; then
		key=$(read_api_key "" "$SONARR_CONFIG")
		api "$SONARR_URL" "$key" "/api/v3/series" 2>/dev/null |
			jq -r '.[] | select(.path != null) | "\(.path)\t\(.originalLanguage.name // "Unknown")"' \
				>>"$LANG_INDEX" 2>/dev/null || true
	fi
}

# Longest matching folder wins, so a title nested under another resolves to
# itself. An unreachable *arr leaves the index empty and every file reads
# Unknown, which is checked rather than skipped: failing open would hide real
# problems behind an API outage.
title_language() {
	local f="$1"
	build_lang_index
	awk -F'\t' -v f="$f" '
		index(f, $1 "/") == 1 && length($1) > best { best = length($1); lang = $2 }
		END { print (lang == "" ? "Unknown" : lang) }
	' "$LANG_INDEX"
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
# lands, and a music cue answers from noise. Prints the winning language and
# how many samples heard English, which check_file weighs against a tag.
whisper_stream() {
	local f="$1" stream="$2" dur i frac ss out lang conf work best bestn
	dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
	if [ -z "$dur" ] || ! [ "$dur" -ge 60 ] 2>/dev/null; then
		printf 'unknown 0'
		return
	fi

	work=$(mktemp -d)
	local -A votes=()
	for ((i = 0; i < SAMPLES; i++)); do
		# Spread across 10% to 90% of runtime. The middle half alone misses
		# openings and closings, which on children's programming is often the
		# only stretch carrying speech rather than music.
		frac=$((10 + i * 80 / (SAMPLES > 1 ? SAMPLES - 1 : 1)))
		ss=$((dur * frac / 100))
		ffmpeg -nostdin -v error -y -ss "$ss" -t 30 -i "$f" -map "0:a:$stream" -ac 1 -ar 16000 \
			-c:a pcm_s16le "$work/s.wav" </dev/null 2>/dev/null || continue
		out=$(whisper-cli -m "$WHISPER_MODEL" -f "$work/s.wav" --detect-language </dev/null 2>&1 |
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
	printf '%s %s' "$best" "${votes[en]:-0}"
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
		read -r lang _ <<<"$(whisper_stream "$f" "$stream")"
		# English anywhere settles it; the remaining streams need no examining.
		if [ "$lang" = en ]; then
			printf 'en'
			return
		fi
		[ "$best" = unknown ] && best="$lang"
	done
	printf '%s' "$best"
}

join_comma() {
	local IFS=,
	printf '%s' "$*"
}

# Hears every audio track and checks each tag against what whisper heard.
#
# Whisper hearing English accepts the file and relabels the track, but over a
# tag naming another language only with OVERRIDE_PERCENT of the samples behind
# it. Short of that, or with whisper hearing another language or nothing it
# can place on a track tagged English, whisper alone does not decide: a reject
# blocklists the release, so the file is kept and logged as REVIEW, which
# MediaAudioNeedsReview mails. Only a file with no English by tag or by ear
# fails, returning 1 so the caller can reject it.
#
# With fix=1 the verdicts are written back (matroska only): relabels, and the
# first English track made default. mkvpropedit rewrites the header in place in
# milliseconds and leaves the file the same size. MP4 has no equivalent short
# of remuxing the whole container, so it is left alone.
check_file() {
	local f="$1" title="$2" fix="$3"
	local i n is_default tag heard en_votes eng="" summary
	local -a tags=() shown=() defaults=() heards=() relabel=() review=() args=()

	while IFS=$'\t' read -r is_default tag; do
		defaults+=("$is_default")
		tags+=("$tag")
		shown+=("${tag:-none}")
	done < <(ffprobe -v error -select_streams a -show_entries stream_disposition=default:stream_tags=language \
		-of json "$f" 2>/dev/null | jq -r '.streams[] | "\(.disposition.default // 0)\t\(.tags.language // "")"')
	n=${#tags[@]}
	[ "$n" -gt "$MAX_STREAMS" ] && n="$MAX_STREAMS"

	for ((i = 0; i < n; i++)); do
		tag=${tags[$i]}
		read -r heard en_votes <<<"$(whisper_stream "$f" "$i")"
		heards+=("$heard")
		relabel+=("")
		case "$heard" in
		en)
			if has_english_tag "$tag" || tags_are_unknown "$tag" ||
				[ $((en_votes * 100)) -ge $((SAMPLES * OVERRIDE_PERCENT)) ]; then
				[ -z "$eng" ] && eng=$i
				has_english_tag "$tag" || relabel[i]=eng
			else
				review+=("track $((i + 1)) tagged $tag, whisper hears en in $en_votes of $SAMPLES samples")
			fi
			;;
		unknown)
			has_english_tag "$tag" && review+=("track $((i + 1)) tagged $tag, whisper undecided")
			;;
		*)
			if has_english_tag "$tag"; then
				review+=("track $((i + 1)) tagged $tag, whisper hears $heard")
			elif tags_are_unknown "$tag"; then
				relabel[i]=$heard
			fi
			;;
		esac
	done

	summary="tagged [$(join_comma "${shown[@]}")], whisper hears [$(join_comma "${heards[@]}")]"
	if [ -n "$eng" ]; then
		log "OK $title: $summary"
	elif [ ${#review[@]} -gt 0 ]; then
		log "REVIEW $title: $summary; $(join_comma "${review[@]}") ($(basename "$f"))"
	else
		log "FAIL $title: $summary, no English track"
	fi

	if [ "$fix" = 1 ]; then
		for ((i = 0; i < ${#tags[@]}; i++)); do
			local -a sets=()
			[ -n "${relabel[i]:-}" ] && sets+=(--set "language=${relabel[i]}")
			if [ -n "$eng" ] && [ "${defaults[$eng]}" != 1 ]; then
				if [ "$i" -eq "$eng" ]; then
					sets+=(--set flag-default=1)
				elif [ "${defaults[i]}" = 1 ]; then
					sets+=(--set flag-default=0)
				fi
			fi
			# mkvpropedit numbers tracks of a kind from 1, ffmpeg from 0.
			[ ${#sets[@]} -gt 0 ] && args+=(--edit "track:a$((i + 1))" "${sets[@]}")
		done
		if [ ${#args[@]} -gt 0 ]; then
			case "$f" in
			*.mkv)
				if mkvpropedit "$f" "${args[@]}" >/dev/null 2>&1; then
					log "FIXED $(basename "$f"): ${args[*]}"
				else
					log "FIX-FAILED $(basename "$f"): mkvpropedit rejected ${args[*]}"
				fi
				;;
			*) log "FIX-SKIPPED $(basename "$f"): only matroska can be retagged without a remux" ;;
			esac
		fi
	fi

	[ -n "$eng" ] || [ ${#review[@]} -gt 0 ]
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

# Walks the library and reports what it finds as node_exporter textfile
# metrics. The import hook only ever sees new grabs, so a periodic pass is
# what surfaces a backlog that predates it, and what an alert can read.
sweep_library() {
	local out="${AUDIO_LANG_TEXTFILE:-/var/lib/prometheus-node-exporter-text-files/audio_language.prom}"
	local roots="${AUDIO_LANG_ROOTS:-/mnt/media/tv /mnt/media/movies}"
	local f langs library verdict total=0 unverified=0 lang
	local -A bad=()
	local -a bad_libs=() bad_paths=()

	local root
	for root in $roots; do
		library=$(basename "$root")
		bad[$library]=${bad[$library]:-0}
		while IFS= read -r -d '' f; do
			total=$((total + 1))
			langs=$(audio_langs "$f")
			has_english_tag "$langs" && continue
			if tags_are_unknown "$langs"; then
				verdict=$(whisper_language "$f")
				[ "$verdict" = en ] && continue
				# An indecisive vote is not evidence of a wrong language, so it
				# is counted apart from the files that are positively not English.
				if [ "$verdict" = unknown ]; then
					unverified=$((unverified + 1))
					continue
				fi
			fi
			# A title made in another language is not a file with the wrong
			# audio. The hook already skips these using the id it was handed;
			# without the same check here a Telugu film alerts forever.
			lang=$(title_language "$f")
			if [ "$lang" != English ] && [ "$lang" != Unknown ]; then
				continue
			fi
			bad[$library]=$((${bad[$library]} + 1))
			bad_libs+=("$library")
			bad_paths+=("$f")
			# A gauge can only carry a count. This is what turns that count
			# back into the list of files somebody has to go and replace.
			log "sweep: no English audio in $f"
		done < <(find "$root" -type f \( -name '*.mkv' -o -name '*.mp4' -o -name '*.avi' \) -print0)
	done

	{
		printf '# HELP media_audio_no_english_files Video files whose audio has no English track\n'
		printf '# TYPE media_audio_no_english_files gauge\n'
		for library in "${!bad[@]}"; do
			printf 'media_audio_no_english_files{library="%s"} %s\n' "$library" "${bad[$library]}"
		done
		printf '# HELP media_audio_no_english_file Video file whose audio has no English track\n'
		printf '# TYPE media_audio_no_english_file gauge\n'
		local i=0
		while [ "$i" -lt "${#bad_paths[@]}" ] && [ "$i" -lt "$MAX_SERIES" ]; do
			printf 'media_audio_no_english_file{library="%s",path="%s"} 1\n' \
				"${bad_libs[$i]}" "$(escape_label "${bad_paths[$i]}")"
			i=$((i + 1))
		done
		printf '# HELP media_audio_unverified_files Untagged files whose language whisper could not settle\n'
		printf '# TYPE media_audio_unverified_files gauge\n'
		printf 'media_audio_unverified_files %s\n' "$unverified"
		printf '# HELP media_audio_files_total Video files examined by the last sweep\n'
		printf '# TYPE media_audio_files_total gauge\n'
		printf 'media_audio_files_total %s\n' "$total"
		printf '# HELP media_audio_sweep_timestamp_seconds Unix time the last sweep finished\n'
		printf '# TYPE media_audio_sweep_timestamp_seconds gauge\n'
		printf 'media_audio_sweep_timestamp_seconds %s\n' "$(date +%s)"
	} >"$out.tmp"
	# node_exporter reads whatever it finds; a half-written file parses as
	# missing metrics rather than as zero.
	mv "$out.tmp" "$out"
	# Never let a cap read as "that was all of them".
	if [ "${#bad_paths[@]}" -gt "$MAX_SERIES" ]; then
		log "sweep: ${#bad_paths[@]} files with no English audio, only $MAX_SERIES named as series"
	fi
	if [ -n "$LANG_INDEX" ]; then
		rm -f "$LANG_INDEX"
	fi
	log "sweep: $total files, $(for k in "${!bad[@]}"; do printf '%s=%s ' "$k" "${bad[$k]}"; done)unverified=$unverified"
}

main() {
	case "${1:-}" in
	--sweep)
		sweep_library
		return
		;;
	--fix)
		shift
		[ $# -gt 0 ] || {
			log "--fix needs at least one file"
			return 1
		}
		local _f _lang
		for _f in "$@"; do
			# The hook reaches its fix only after the originalLanguage skip, so it
			# can never promote a dub over a film's own audio. Invoked by hand over
			# a list, this is the only thing between a Japanese film and an English
			# dub set as its default.
			_lang=$(title_language "$_f")
			if [ "$_lang" != English ] && [ "$_lang" != Unknown ]; then
				log "FIX-SKIPPED $(basename "$_f"): originalLanguage=$_lang"
				continue
			fi
			check_file "$_f" "$(basename "$_f")" 1 || true
		done
		return
		;;
	esac

	local service base key_config key_override event title orig_lang download_id _f
	local -a files=()

	if [ -n "${radarr_eventtype:-}" ]; then
		service=radarr
		base="$RADARR_URL"
		key_config="$RADARR_CONFIG"
		key_override="${RADARR_API_KEY_FILE:-}"
		event="$radarr_eventtype"
		title="${radarr_movie_title:-unknown}"
		download_id="${radarr_download_id:-}"
		[ -n "${radarr_moviefile_path:-}" ] && files=("$radarr_moviefile_path")
	elif [ -n "${sonarr_eventtype:-}" ]; then
		service=sonarr
		base="$SONARR_URL"
		key_config="$SONARR_CONFIG"
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

	local f
	for f in "${files[@]}"; do
		[ -f "$f" ] || {
			log "SKIP $title: missing file $f"
			continue
		}
		check_file "$f" "$title" "$FIX" && continue

		if [ "$ENFORCE" = 1 ]; then
			reject "$base" "$key" "$download_id" "$title"
		else
			log "REPORT-ONLY: would reject $title ($(basename "$f"))"
		fi
	done
}

main "$@"

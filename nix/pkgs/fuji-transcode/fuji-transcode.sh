# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/fuji-transcode/default.nix).
#
# Transcodes a directory of Fuji X-T5 clips into an editing intermediate,
# baking the F-Log2 -> Rec.709 LUT into clips shot in F-Log2 (detected via
# the camera's exiftool maker-note, not ffprobe's color tags, which read
# bt709 even on log footage) and leaving normal clips alone. See README.md
# for the recommended X-T5 capture settings and LUT download link.

readonly BAR_WIDTH=20
readonly DEFAULT_CODEC="dnxhr_lb"
readonly DEFAULT_OUT_NAME="transcoded"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS] <input-dir>

Transcode Fuji X-T5 clips in <input-dir> into <input-dir>/<out-name>/,
baking the F-Log2 LUT into F-Log2 clips and passing normal clips through
unLUTed. Classification uses exiftool's VideoRecordingMode, not ffprobe.

Options:
  --lut PATH        Fuji F-Log2 -> BT.709 .cube LUT (required if any
                     F-Log2 clips are found, unless --flat is given)
  --flog-lut PATH   .cube LUT for legacy F-Log (v1) clips, if any
  --flat            do not bake any LUT; keep F-Log/F-Log2 clips flat for
                     grading in Resolve instead (mutually exclusive with
                     --lut/--flog-lut)
  --codec CODEC     dnxhr_lb (default) | prores | h264 | h265
  --out-name NAME   output subdirectory name (default: $DEFAULT_OUT_NAME)
  --flog2-only      only process F-Log2 clips; skip normal clips entirely
  --copy-normal     copy normal clips as-is instead of re-encoding them
  --force           overwrite existing outputs
  -h, --help        show this help

Fuji's free F-Log2 LUTs: https://www.fujifilm-x.com/global/support/download/lut/
EOF
}

# Format a whole number of seconds as MM:SS.
fmt_secs() {
	local total_secs="$1"
	if [ "$total_secs" -lt 0 ]; then
		total_secs=0
	fi
	printf '%02d:%02d' $((total_secs / 60)) $((total_secs % 60))
}

# Redraw a single-line ASCII progress bar in place.
draw_bar() {
	local idx="$1" total="$2" label="$3" pct="$4" speed="$5" eta="$6"
	local filled=$((pct * BAR_WIDTH / 100))
	[ "$filled" -gt "$BAR_WIDTH" ] && filled="$BAR_WIDTH"
	[ "$filled" -lt 0 ] && filled=0
	local empty=$((BAR_WIDTH - filled))
	local bar_filled bar_empty
	bar_filled="$(printf '%*s' "$filled" '')"
	bar_filled="${bar_filled// /#}"
	bar_empty="$(printf '%*s' "$empty" '')"
	bar_empty="${bar_empty// /-}"
	printf '\r[%d/%d] %-40s [%s%s] %3d%%  %-6s  ETA %s' \
		"$idx" "$total" "$label" "$bar_filled" "$bar_empty" "$pct" "$speed" "$eta"
}

# Run ffmpeg on one clip, rendering a live progress bar (or, off a TTY, a
# plain start/done line) parsed from ffmpeg's own -progress stream.
run_ffmpeg_with_progress() {
	local idx="$1" total="$2" label="$3" duration_us="$4" infile="$5" outfile="$6"
	shift 6
	local -a extra_args=("$@")

	local -a cmd=(
		ffmpeg -hide_banner -loglevel error -nostats -y
		-progress pipe:1
		-i "$infile"
		"${extra_args[@]}"
		-c:a copy
		"$outfile"
	)

	if [ -t 1 ]; then
		local start_epoch cur_us pct speed eta elapsed remaining now
		start_epoch="$(date +%s)"
		cur_us=0
		speed="N/A"
		"${cmd[@]}" | while IFS='=' read -r key value; do
			value="${value%$'\r'}"
			case "$key" in
			out_time_us)
				[[ $value =~ ^[0-9]+$ ]] && cur_us="$value"
				;;
			speed)
				speed="$value"
				;;
			progress)
				if [ "$duration_us" -gt 0 ]; then
					pct=$((cur_us * 100 / duration_us))
					[ "$pct" -gt 100 ] && pct=100
				else
					pct=0
				fi
				now="$(date +%s)"
				elapsed=$((now - start_epoch))
				if [ "$cur_us" -gt 0 ] && [ "$duration_us" -gt "$cur_us" ]; then
					remaining=$((duration_us - cur_us))
					eta="$(fmt_secs $((elapsed * remaining / cur_us)))"
				else
					eta="--:--"
				fi
				draw_bar "$idx" "$total" "$label" "$pct" "$speed" "$eta"
				[ "$value" = "end" ] && printf '\n'
				;;
			esac
		done
	else
		echo "[$idx/$total] $label: transcoding..."
		"${cmd[@]}" >/dev/null
	fi
	echo "[$idx/$total] $label: OK"
}

# Transcode one clip, wiring up the codec args and (if given) the LUT filter.
transcode_one() {
	local infile="$1" outfile="$2" lut="$3" idx="$4" total="$5" label="$6"
	local duration_s duration_us
	duration_s="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$infile")"
	duration_s="${duration_s%%.*}"
	[ -z "$duration_s" ] && duration_s=0
	duration_us=$((duration_s * 1000000))

	local -a filter_args=()
	if [ -n "$lut" ]; then
		filter_args=(-vf "lut3d=file=${lut}")
	fi

	local -a codec_args
	case "$CODEC" in
	dnxhr_lb) codec_args=(-c:v dnxhd -profile:v dnxhr_lb -pix_fmt yuv422p) ;;
	prores) codec_args=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le) ;;
	h264) codec_args=(-c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p) ;;
	h265) codec_args=(-c:v libx265 -crf 20 -preset medium -pix_fmt yuv420p10le) ;;
	esac

	run_ffmpeg_with_progress "$idx" "$total" "$label" "$duration_us" \
		"$infile" "$outfile" "${filter_args[@]}" "${codec_args[@]}"
}

# --- argument parsing ---

INPUT_DIR=""
LUT=""
FLOG_LUT=""
FLAT=false
CODEC="$DEFAULT_CODEC"
OUT_NAME="$DEFAULT_OUT_NAME"
FLOG2_ONLY=false
COPY_NORMAL=false
FORCE=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--lut)
		LUT="$2"
		shift 2
		;;
	--flog-lut)
		FLOG_LUT="$2"
		shift 2
		;;
	--flat)
		FLAT=true
		shift
		;;
	--codec)
		CODEC="$2"
		shift 2
		;;
	--out-name)
		OUT_NAME="$2"
		shift 2
		;;
	--flog2-only)
		FLOG2_ONLY=true
		shift
		;;
	--copy-normal)
		COPY_NORMAL=true
		shift
		;;
	--force)
		FORCE=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		echo "Error: unknown option '$1'" >&2
		usage >&2
		exit 1
		;;
	*)
		if [ -n "$INPUT_DIR" ]; then
			echo "Error: unexpected extra argument '$1'" >&2
			usage >&2
			exit 1
		fi
		INPUT_DIR="$1"
		shift
		;;
	esac
done

if [ -z "$INPUT_DIR" ]; then
	echo "Error: <input-dir> is required" >&2
	usage >&2
	exit 1
fi
if [ ! -d "$INPUT_DIR" ]; then
	echo "Error: '$INPUT_DIR' is not a directory" >&2
	exit 1
fi

case "$CODEC" in
dnxhr_lb | prores | h264 | h265) ;;
*)
	echo "Error: invalid --codec '$CODEC' (expected: dnxhr_lb, prores, h264, h265)" >&2
	exit 1
	;;
esac

if [ -n "$LUT" ] && [ ! -f "$LUT" ]; then
	echo "Error: --lut '$LUT' does not exist" >&2
	exit 1
fi
if [ -n "$FLOG_LUT" ] && [ ! -f "$FLOG_LUT" ]; then
	echo "Error: --flog-lut '$FLOG_LUT' does not exist" >&2
	exit 1
fi
if [ "$FLAT" = true ] && { [ -n "$LUT" ] || [ -n "$FLOG_LUT" ]; }; then
	echo "Error: --flat cannot be combined with --lut/--flog-lut" >&2
	exit 1
fi

# --- discover and classify clips ---

shopt -s nullglob nocaseglob
CANDIDATES=("$INPUT_DIR"/*.mov "$INPUT_DIR"/*.mp4)
shopt -u nullglob nocaseglob

FILES=()
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
	mapfile -t FILES < <(printf '%s\n' "${CANDIDATES[@]}" | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
	echo "No .mov/.mp4 clips found directly in '$INPUT_DIR'"
	exit 0
fi

CLASSES=()
for f in "${FILES[@]}"; do
	mode="$(exiftool -s3 -VideoRecordingMode "$f" 2>/dev/null || true)"
	CLASSES+=("$mode")
done

need_lut=false
need_flog_lut=false
for c in "${CLASSES[@]}"; do
	case "$c" in
	"F-log2") need_lut=true ;;
	"F-log") need_flog_lut=true ;;
	esac
done

if [ "$FLAT" != true ] && [ "$need_lut" = true ] && [ -z "$LUT" ]; then
	echo "Error: F-Log2 clips found in '$INPUT_DIR' but --lut was not given." >&2
	echo "Download Fuji's free F-Log2 LUTs from https://www.fujifilm-x.com/global/support/download/lut/" >&2
	echo "Or pass --flat to keep the log curve intact for grading in Resolve instead." >&2
	exit 1
fi
if [ "$FLAT" != true ] && [ "$need_flog_lut" = true ] && [ -z "$FLOG_LUT" ]; then
	echo "Warning: F-Log (v1) clips found; no --flog-lut given, they will be skipped." >&2
fi

OUT_DIR="$INPUT_DIR/$OUT_NAME"
mkdir -p "$OUT_DIR"

# --- process clips ---

total="${#FILES[@]}"
count_transcoded=0
count_copied=0
count_skipped=0
idx=0
run_start="$(date +%s)"

for i in "${!FILES[@]}"; do
	idx=$((idx + 1))
	file="${FILES[$i]}"
	class="${CLASSES[$i]}"
	base="$(basename "$file")"
	name="${base%.*}"

	lut_arg=""
	action="transcode"
	label=""

	case "$class" in
	"F-log2")
		if [ "$FLAT" = true ]; then
			label="F-Log2 (flat)"
		else
			lut_arg="$LUT"
			label="F-Log2 -> $(basename "$LUT")"
		fi
		;;
	"F-log")
		if [ "$FLAT" = true ]; then
			label="F-Log (flat)"
		elif [ -z "$FLOG_LUT" ]; then
			echo "[$idx/$total] $base: F-Log clip, no --flog-lut given, skipping"
			count_skipped=$((count_skipped + 1))
			continue
		else
			lut_arg="$FLOG_LUT"
			label="F-Log -> $(basename "$FLOG_LUT")"
		fi
		;;
	*)
		label="normal"
		if [ "$FLOG2_ONLY" = true ]; then
			echo "[$idx/$total] $base: normal clip, --flog2-only set, skipping"
			count_skipped=$((count_skipped + 1))
			continue
		fi
		if [ "$COPY_NORMAL" = true ]; then
			action="copy"
		fi
		;;
	esac

	if [ "$action" = "copy" ]; then
		out="$OUT_DIR/$base"
	else
		out="$OUT_DIR/$name.mov"
	fi

	if [ -e "$out" ] && [ "$FORCE" != true ]; then
		echo "[$idx/$total] $base: output exists, skipping (use --force to overwrite)"
		count_skipped=$((count_skipped + 1))
		continue
	fi

	if [ "$action" = "copy" ]; then
		echo "[$idx/$total] $base: copying ($label)"
		cp -p "$file" "$out"
		count_copied=$((count_copied + 1))
	else
		transcode_one "$file" "$out" "$lut_arg" "$idx" "$total" "$base ($label)"
		count_transcoded=$((count_transcoded + 1))
	fi
done

elapsed="$(fmt_secs $(($(date +%s) - run_start)))"
echo
echo "Summary: $count_transcoded transcoded, $count_copied copied, $count_skipped skipped (of $total) in $elapsed"

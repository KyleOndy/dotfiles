# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/ask/default.nix).
#
# Local LLM one-off questions and chat. Currently shells out to mlx-lm
# (installed imperatively via `uv tool install mlx-lm` -- Metal-backed
# wheels don't package cleanly through nixpkgs on darwin, see
# nix/hosts/trex/home.nix sessionPath). The backend is an implementation
# detail behind this interface -- swap the mlx_lm.* calls below if it ever
# changes (e.g. Ollama, llama.cpp, MAX) without touching callers.
#
#   ask [--fast|--smart|--model ID] question words...
#   ask [--fast|--smart|--model ID]
#   ask --help

readonly FAST_MODEL="mlx-community/Qwen3-8B-4bit"
readonly SMART_MODEL="mlx-community/gpt-oss-20b-MXFP4-Q4"

# mlx-lm's own CLI defaults (100 for generate, 256 for chat) are tuned for
# non-reasoning models. Both models here emit a <think> block before the
# answer, which can eat the whole budget and truncate before ever reaching
# the answer -- raise it well past what thinking + answer typically needs.
readonly MAX_TOKENS=2048

usage() {
	cat >&2 <<EOF
Usage:
  ask [--fast|--smart|--model ID] question words...
  ask [--fast|--smart|--model ID]                  interactive chat
  ask --help

  --fast     $FAST_MODEL (default) -- ~4.7GB, ~30 tok/s
  --smart    $SMART_MODEL -- MoE, more capable, ~11GB, ~55 tok/s
  --model    any mlx-lm model id, e.g. mlx-community/Qwen3.6-27B-4bit
  --help     this message

Anything not already in ~/.cache/huggingface is downloaded on first use.
EOF
	exit "${1:-1}"
}

if ! command -v mlx_lm.generate >/dev/null 2>&1; then
	echo "mlx_lm not found on PATH. Install with: uv tool install mlx-lm" >&2
	exit 1
fi

model="$FAST_MODEL"

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage 0
		;;
	--fast)
		model="$FAST_MODEL"
		shift
		;;
	--smart)
		model="$SMART_MODEL"
		shift
		;;
	--model)
		# Guarded because set -u would abort on $2 before usage could print.
		[ $# -ge 2 ] || usage
		model="$2"
		shift 2
		;;
	*)
		break
		;;
	esac
done

# mlx_lm.chat loads the model before it reads any stdin, so without a
# terminal to chat with, that is 5-11GB of load spent to reach EOF.
if [ $# -eq 0 ] && [ -t 0 ]; then
	exec mlx_lm.chat --model "$model" --max-tokens "$MAX_TOKENS"
fi

[ $# -ge 1 ] || usage
exec mlx_lm.generate --model "$model" --prompt "$*" --max-tokens "$MAX_TOKENS"

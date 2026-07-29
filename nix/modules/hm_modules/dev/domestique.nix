# domestique: voice-driven pi for Zone 2 trainer rides.
#
# This module is the audio-out half. `domestique-speak` runs OUTSIDE pi's
# sandbox and owns playback, because inside strict mode the CoreAudio mach
# lookup is denied and srt's settings schema (nix/pkgs/pi-wrapper/wrapper.sh)
# has no mach knob. The pi-side half is extensions/domestique.ts, which writes
# one file per utterance into ~/.pi/domestique/spool and the control files
# beside it, and never touches the audio device.
#
# Speech is Kokoro, not macOS `say`; domestique-tts.py explains why, and it is
# the reason `lexicon` can exist.
#
# Usage: `domestique` starts the watchers and pi together, in a dated
# directory under `rideDir` that is the only place the agent can write.
# `domestique-review` reopens the newest one afterwards, without speech.
# `domestique-speak` alone is the two-pane form, and prints the matching pi
# invocation.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.hmFoundry.dev.domestique;

  ridePromptFile = pkgs.writeText "domestique-ride-prompt.md" cfg.ridePrompt;

  lexiconFile = pkgs.writeText "domestique-lexicon.json" (builtins.toJSON cfg.lexicon);

  # misaki[en] minus spacy-curated-transformers. That extra serves only the
  # transformer POS tagger (G2P trf=True), which this never uses, and it pulls
  # torch: 493MB of a 1.1GB tree.
  #
  # numba arrives under parakeet-mlx via librosa and caps numpy at <2.5, so an
  # unfloored resolve keeps numpy 2.5 and drops numba to 0.53.1, which predates
  # cp312 wheels and fails building llvmlite from source. 0.59.0 is the first
  # release supporting Python 3.12:
  # https://numba.readthedocs.io/en/stable/release/0.59.0-notes.html
  requirementsFile = pkgs.writeText "domestique-requirements.txt" ''
    mlx-audio
    misaki
    espeakng-loader
    num2words
    phonemizer-fork
    spacy
    soundfile
    parakeet-mlx
    numba>=0.59
    en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl
  '';

  # Refs, not working trees. Every repo here is a bare checkout with one
  # worktree per branch, several holding uncommitted work, so fetching into
  # .bare freshens what the agent can reason about without touching anything
  # the user has in progress.
  domestique-fetch = pkgs.writeShellApplication {
    name = "domestique-fetch";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
    ];
    text = ''
      readonly REPOS=(${lib.escapeShellArgs cfg.repos})

      if [ "''${#REPOS[@]}" -eq 0 ]; then
        echo "domestique-fetch: no repos configured (hmFoundry.dev.domestique.repos)" >&2
        exit 0
      fi

      failed=0
      for repo in "''${REPOS[@]}"; do
        gitdir="$repo"
        [ -d "$repo/.bare" ] && gitdir="$repo/.bare"
        if [ ! -e "$gitdir/HEAD" ] && [ ! -e "$repo/.git" ]; then
          printf 'domestique-fetch: %-40s skipped, not a repo\n' "$repo"
          continue
        fi
        # Ride time is not fetch time; a hung remote must not hold up the start.
        if err=$(timeout "${toString cfg.fetchTimeoutSeconds}" \
          git -C "$gitdir" fetch --all --prune --quiet 2>&1); then
          printf 'domestique-fetch: %-40s ok\n' "$repo"
        else
          # An expired key, an unknown host and a timeout all print FAILED, and
          # the reason is gone for good once the run ends.
          status=$?
          reason=$(printf '%s' "$err" | tail -n 1)
          [ -n "$reason" ] || reason="exit $status"
          printf 'domestique-fetch: %-40s FAILED  %s\n' "$repo" "$reason"
          failed=$((failed + 1))
        fi
      done

      # Stale refs still make for a usable ride, so this reports rather than
      # aborts.
      [ "$failed" -eq 0 ] || printf 'domestique-fetch: %d of %d failed\n' \
        "$failed" "''${#REPOS[@]}" >&2
    '';
  };

  # Settings reach the generated scripts inside double quotes, where $, a
  # backtick and a backslash are all still live. escapeShellArg is no use for
  # most of them, which sit inside a ''${VAR:-default} expansion where its
  # single quotes would land in the value.
  dq = lib.escape [
    "\\"
    "\""
    "$"
    "`"
  ];

  allowReadFlags = lib.concatMapStrings (r: " --allow-read ${lib.escapeShellArg r}") cfg.repos;

  allowBundleFlags = lib.concatMapStrings (b: " --allow-${b}") cfg.allowBundles;

  piFlags = allowReadFlags + allowBundleFlags;

  # Kokoro and misaki are not packaged for darwin in nixpkgs:
  # python3Packages.kokoro depends on dlinfo, which carries
  # `broken = stdenv.hostPlatform.isDarwin`. So the wheels live in a venv built
  # on first run, keyed on the requirements store path so a change to the list
  # rebuilds it. Needs network once.
  ensureVenv = ''
    readonly VENV="$ROOT/venv"
    readonly STAMP="$VENV/.requirements"

    if [ ! -x "$VENV/bin/python" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "${requirementsFile}" ]; then
      # Every domestique command shares this venv, so an older binary still on
      # some shell's PATH rebuilds it to that binary's requirements, deleting
      # it under whatever is already running from it.
      for holder in "$ROOT/watcher.pid" "$ROOT/listen.pid"; do
        held=$(cat "$holder" 2>/dev/null) || continue
        if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then
          printf 'domestique: venv needs rebuilding, but pid %s is using it. Stop it first.\n' \
            "$held" >&2
          exit 1
        fi
      done

      printf 'domestique: building the speech venv, this runs once\n' >&2
      rm -rf "$VENV"
      uv venv --python "${pkgs.python312}/bin/python3.12" "$VENV" >&2
      VIRTUAL_ENV="$VENV" uv pip install --quiet -r "${requirementsFile}" >&2
      printf '%s\n' "${requirementsFile}" > "$STAMP"
    fi

    # A leaked PYTHONPATH shadows the venv, and a mismatched minor version then
    # fails on native extensions built for another ABI.
    unset PYTHONPATH

    export DOMESTIQUE_ESPEAK="${pkgs.espeak-ng}"
    export DOMESTIQUE_LEXICON="${lexiconFile}"
    export PYTHONUNBUFFERED=1
  '';

  # Reports what a term resolves to, so a lexicon entry can be checked before
  # it is committed and, more often, shown to be unnecessary.
  domestique-phonemes = pkgs.writeShellApplication {
    name = "domestique-phonemes";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.uv
    ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      mkdir -p "$ROOT"
      ${ensureVenv}
      # The report has to match the watcher, so the tool loads the watcher's
      # normalizer and lexicon install rather than its own copy.
      export DOMESTIQUE_TTS="${./domestique-tts.py}"
      exec "$VENV/bin/python" ${./domestique-phonemes.py} "$@"
    '';
  };

  # Reports what the recognizer hears, so the lexicon corrector can be built
  # against real transcripts rather than guesses about them.
  domestique-transcribe = pkgs.writeShellApplication {
    name = "domestique-transcribe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.uv
      # parakeet_mlx.audio decodes by execing ffmpeg, not through a library.
      pkgs.ffmpeg
    ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      mkdir -p "$ROOT"
      ${ensureVenv}
      export DOMESTIQUE_STT_MODEL="${dq cfg.sttModel}"
      exec "$VENV/bin/python" ${./domestique-stt.py} "$@"
    '';
  };

  domestique-listen = pkgs.writeShellApplication {
    name = "domestique-listen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.uv
    ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      mkdir -p "$ROOT"
      ${ensureVenv}
      export DOMESTIQUE_ROOT="$ROOT"
      export DOMESTIQUE_STT_MODEL="${dq cfg.sttModel}"
      export DOMESTIQUE_INPUT_DEVICE="''${DOMESTIQUE_INPUT_DEVICE:-${dq cfg.inputDevice}}"
      export DOMESTIQUE_POLL_SECONDS="${dq cfg.pollSeconds}"
      exec "$VENV/bin/python" ${./domestique-listen.py} "$@"
    '';
  };

  domestique-speak = pkgs.writeShellApplication {
    name = "domestique-speak";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.uv
    ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      readonly PROMPT="$ROOT/ride-prompt.md"

      mkdir -p "$ROOT"

      # srt's read allowlist is checked against the path as written, so a
      # home-manager symlink under ~/.pi resolves outside the allowlist and pi
      # reports the prompt as missing. Copy it in as a regular file.
      install -m 0644 "${ridePromptFile}" "$PROMPT"

      ${ensureVenv}

      printf 'domestique: run pi with\n  pi%s --domestique --append-system-prompt %s\n' \
        "${piFlags}" "$PROMPT"

      export DOMESTIQUE_ROOT="$ROOT"
      export DOMESTIQUE_VOICE="''${DOMESTIQUE_VOICE:-${dq cfg.voice}}"
      export DOMESTIQUE_MODEL="${dq cfg.model}"
      export DOMESTIQUE_SPEED="''${DOMESTIQUE_SPEED:-${dq cfg.speed}}"
      export DOMESTIQUE_NARRATE_THINKING="''${DOMESTIQUE_NARRATE_THINKING:-${
        if cfg.narrateThinking then "1" else "0"
      }}"
      export DOMESTIQUE_CUE_SOUND="''${DOMESTIQUE_CUE_SOUND:-${dq cfg.cueSound}}"
      export DOMESTIQUE_CUE_PATTERN="''${DOMESTIQUE_CUE_PATTERN:-${dq cfg.cuePattern}}"
      export DOMESTIQUE_LISTEN_CUE_SOUND="${dq cfg.listenCueSound}"
      export DOMESTIQUE_LISTEN_BACKGROUND="${dq cfg.listenBackground}"
      export DOMESTIQUE_ALACRITTY="${
        lib.optionalString (
          config.programs.alacritty.enable && config.programs.alacritty.package != null
        ) "${config.programs.alacritty.package}/bin/alacritty"
      }"
      export DOMESTIQUE_CUE_GAIN="${dq cfg.cueGain}"
      export DOMESTIQUE_CUE_LEAD="${dq cfg.cueLead}"
      export DOMESTIQUE_WAKE_PAD_MS="${toString cfg.wakePadMs}"
      export DOMESTIQUE_WAKE_GAP_SECONDS="${toString cfg.wakeGapSeconds}"
      export DOMESTIQUE_POLL_SECONDS="${dq cfg.pollSeconds}"

      exec "$VENV/bin/python" ${./domestique-tts.py} "$@"
    '';
  };

  # The --allow-read flags are the reason this exists. Every configured repo is
  # a bare checkout whose worktrees carry a .git file pointing at a sibling
  # .bare, so granting pi the worktree alone leaves git unable to reach its own
  # object store, and every history command fails on the gitdir instead.
  domestique = pkgs.writeShellApplication {
    name = "domestique";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      readonly SPOOL="$ROOT/spool"
      readonly SPEAKING="$ROOT/watcher.speaking"
      readonly RESTART="$ROOT/restart"
      readonly TOPIC="$ROOT/topic"
      readonly LOCK="$ROOT/ride.lock"
      RIDE="${dq cfg.rideDir}/$(date +%Y-%m-%d)"
      readonly RIDE

      # Read by the clone_repo tool in extensions/domestique.ts, which needs the
      # paths themselves rather than the --allow-read flags built from them. The
      # names are private to the work config, so they arrive at runtime instead
      # of being baked into the extension.
      #
      # Joined here rather than by printf in the shell: `repos` defaults to
      # empty, and a format string with no arguments is SC2183, which fails the
      # writeShellApplication build on any host that has not set it.
      export DOMESTIQUE_REPOS=${lib.escapeShellArg (lib.concatStringsSep "\n" cfg.repos)}

      # Held apart from "$@" because the loop below clears the arguments after
      # the first topic: an opening prompt is one topic's, a model is the ride's.
      model=()
      rest=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --model)
            if [ "$#" -lt 2 ]; then
              echo "domestique: --model needs a value" >&2
              exit 1
            fi
            model=(--model "$2")
            shift 2
            ;;
          --model=*)
            model=(--model "''${1#--model=}")
            shift
            ;;
          *)
            rest+=("$1")
            shift
            ;;
        esac
      done
      set -- "''${rest[@]}"

      shopt -s nullglob
      mkdir -p "$ROOT"

      # A ride is a singleton, and now says so. There is one rider, one
      # microphone, one pair of headphones, and one push-to-talk key writing one
      # hardcoded path (desktop/input/karabiner.nix), so a key press cannot name
      # a session and two rides cannot both be answered. Nothing under $ROOT
      # carries a session either: one spool, one speed, one restart flag.
      #
      # Unenforced, a second ride adopted the first's watchers and inherited its
      # terminal, so its tint landed on the first ride's window; and whichever
      # ride started the watchers killed them on exit, muting the other.
      where="terminal"
      if [ -n "''${TMUX_PANE:-}" ]; then
        where="tmux pane $TMUX_PANE"
      fi
      if [ -n "''${ALACRITTY_WINDOW_ID:-}" ]; then
        where="alacritty window $ALACRITTY_WINDOW_ID"
      fi

      # noclobber makes the redirection itself the test, so two rides starting
      # in the same millisecond cannot both come away holding the lock.
      claim() {
        (
          set -o noclobber
          {
            printf '%s\n' "$$"
            printf '  pid %s, started %s, %s\n' "$$" "$(date +%H:%M)" "$where"
          } >"$LOCK"
        ) 2>/dev/null
      }

      if ! claim; then
        held=$(head -n 1 "$LOCK" 2>/dev/null) || held=""
        if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then
          printf 'domestique: a ride is already running\n' >&2
          tail -n +2 "$LOCK" >&2
          printf '  stop it with:  kill %s\n' "$held" >&2
          printf '  or review it:  domestique-review\n' >&2
          exit 1
        fi
        # The pid is gone, so a ride died without releasing. Its watchers may
        # still be running; launch() replaces them.
        rm -f "$LOCK"
        if ! claim; then
          printf 'domestique: could not take the ride lock at %s\n' "$LOCK" >&2
          exit 1
        fi
      fi
      trap 'rm -f "$LOCK"' EXIT

      mkdir -p "$RIDE/.sessions"

      # pi's sandbox allows writes to $PWD and ~/.pi and nowhere else
      # (nix/pkgs/pi-wrapper/wrapper.sh, write_paths), so the launch directory
      # is the whole of what the agent can take notes in. Left to the caller it
      # is wherever the terminal happened to be.
      cd "$RIDE"

      # A clone_repo checkout runs to hundreds of megabytes and is reproducible
      # from .bare in under a minute, where the notes beside it are neither. Only
      # the clones go, and only from rides that are over. Their git directories
      # live under ~/.pi keyed by the same date, and are useless without the
      # worktree, so the two are dropped together.
      for old in "${dq cfg.rideDir}"/*/repos; do
        [ "$old" = "$RIDE/repos" ] && continue
        printf 'domestique: reclaiming %s\n' "$old"
        rm -rf "$old"
      done
      for old in "$ROOT"/gitdirs/*; do
        [ "$old" = "$ROOT/gitdirs/$(basename "$RIDE")" ] && continue
        rm -rf "$old"
      done

      started=()

      alive() {
        [ -e "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null
      }

      stop_watchers() {
        [ "''${#started[@]}" -gt 0 ] || return 0
        local pidfile
        for pidfile in "''${started[@]}"; do
          kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
          # A watcher still loading its model has no cleanup to run yet, and a
          # pid left behind reads as live once the number comes round again.
          rm -f "$pidfile"
        done
        started=()
      }

      launch() {
        local name="$1" bin="$2" pidfile="$3" ready="$4" log="$5"
        # The ride owns its watchers. Reaching here means we hold the lock, so a
        # live watcher belongs to no ride: either a crash left it behind, or
        # domestique-speak was started by hand. Either way it carries another
        # terminal's identity and would tint a window nobody is riding in, so it
        # is replaced rather than reused. Replacing costs the model load, but
        # only on that path, since a ride exiting normally kills its own.
        if alive "$pidfile"; then
          printf 'domestique: replacing an orphaned %s watcher\n' "$name"
          local orphan settle=0
          orphan=$(cat "$pidfile")
          kill "$orphan" 2>/dev/null || true
          # The watcher refuses to start while another pid holds the spool, and
          # the one just signalled takes as long as its current utterance to
          # unwind, so the replacement waits it out rather than racing it.
          while [ "$settle" -lt 50 ] && kill -0 "$orphan" 2>/dev/null; do
            sleep 0.1
            settle=$((settle + 1))
          done
          rm -f "$pidfile"
        fi
        rm -f "$ready"
        "$bin" >>"$log" 2>&1 &
        local child=$!
        started+=("$pidfile")
        # The first run of all builds a venv and downloads a model, so this
        # waits in minutes rather than seconds. Steady state is a few. A watcher
        # that dies at startup never writes the file, so the pid bounds the wait
        # that the file alone would leave at ten silent minutes.
        local waited=0
        while [ "$waited" -lt 3000 ] && [ ! -e "$ready" ] && kill -0 "$child" 2>/dev/null; do
          sleep 0.2
          waited=$((waited + 1))
        done
        if [ ! -e "$ready" ]; then
          printf 'domestique: %s did not come up, see %s\n' "$name" "$log" >&2
          tail -n 5 "$log" >&2 2>/dev/null || true
          kill "$child" 2>/dev/null || true
          stop_watchers
          exit 1
        fi
        printf 'domestique: %s ready, logging to %s\n' "$name" "$log"
      }

      launch speech "${domestique-speak}/bin/domestique-speak" \
        "$ROOT/watcher.pid" "$ROOT/watcher.ready" "$ROOT/speak.log"
      launch listening "${domestique-listen}/bin/domestique-listen" \
        "$ROOT/listen.pid" "$ROOT/listen.ready" "$ROOT/listen.log"

      # --allow-read and --allow-<bundle> belong to the pi wrapper, --domestique
      # to pi, and the wrapper's arg loop breaks at the first flag it does not
      # own (nix/pkgs/pi-wrapper/wrapper.sh). Anything after --domestique reaches
      # pi verbatim, which rejects --allow-read outright, so wrapper flags go
      # first.
      #
      # A spoken "new topic" leaves RESTART behind and ends the session, so a
      # ride is one pi process per topic. The watchers outlive all of them,
      # which is what keeps the model loaded and the speech continuous across
      # the gap.
      # The topic outlives the restart flag it travels with: a pi that dies
      # before session_start consumes neither, and the next ride would open
      # itself on a subject from whenever that was.
      rm -f "$RESTART" "$TOPIC"
      while true; do
        pi${piFlags} --domestique \
          --session-dir "$RIDE/.sessions" \
          --append-system-prompt "$ROOT/ride-prompt.md" \
          "''${model[@]}" "$@" || true
        [ -e "$RESTART" ] || break
        rm -f "$RESTART"
        # An opening prompt belongs to the first launch only.
        set --
      done

      # A pi exit drops the thinking channel but leaves the response queued, so
      # the watcher has to outlive it by however long the answer takes. What is
      # bounded here is silence, not the answer: speech playing or a shrinking
      # queue starts the count over, so only a watcher that has stopped making
      # progress runs it out. The outer bound is the one that survives a watcher
      # wedged mid-utterance, which no amount of waiting would resolve.
      idle=0
      total=0
      left=-1
      while [ "$total" -lt 1500 ] && [ "$idle" -lt 150 ]; do
        queue=("$SPOOL"/*-speak.txt)
        if [ "''${#queue[@]}" -eq 0 ] && [ ! -e "$SPEAKING" ]; then
          break
        fi
        if [ "''${#queue[@]}" -ne "$left" ] || [ -e "$SPEAKING" ]; then
          left="''${#queue[@]}"
          idle=0
        fi
        sleep 0.2
        idle=$((idle + 1))
        total=$((total + 1))
      done
      stop_watchers

      # rmdir refuses a non-empty directory, so a ride that wrote something
      # keeps it and one that died before pi started leaves nothing behind.
      rmdir "$RIDE/.sessions" "$RIDE" 2>/dev/null || true
    '';
  };

  # A ride writes into its own directory and reads the repos, so the pass that
  # turns it into actions is an ordinary pi session with the same read grants,
  # started where the ride left its notes.
  domestique-review = pkgs.writeShellApplication {
    name = "domestique-review";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      shopt -s nullglob
      readonly RIDES="${dq cfg.rideDir}"

      ride=""
      if [ "$#" -gt 0 ]; then
        if [ -d "$1" ]; then
          ride="$1"
          shift
        elif [ -d "$RIDES/$1" ]; then
          # Rides are named by date, so the date on its own is what gets typed.
          ride="$RIDES/$1"
          shift
        else
          # Anything else is a message for pi, except a date, which can only
          # have been meant as a ride and would otherwise open the newest one
          # and reach pi as a stray word.
          case "$1" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
              printf 'domestique-review: no ride on %s under %s\n' "$1" "$RIDES" >&2
              exit 1
              ;;
          esac
        fi
      fi

      if [ -z "$ride" ]; then
        dirs=("$RIDES"/*/)
        if [ "''${#dirs[@]}" -eq 0 ]; then
          printf 'domestique-review: nothing under %s yet\n' "$RIDES" >&2
          exit 1
        fi
        # Glob order is lexical and the directories are ISO dates.
        ride="''${dirs[-1]}"
      fi

      printf 'domestique-review: %s\n' "$ride"
      cd "$ride"
      exec pi${piFlags} "$@"
    '';
  };

  zoomConfig = (pkgs.formats.toml { }).generate "domestique-alacritty.toml" {
    general.import = [ "~/.config/alacritty/alacritty.toml" ];
    font.size = cfg.zoom.fontSize;
    # Fullscreen gives the window its own Space, which a notification or a
    # Mission Control gesture can then swap away mid-ride.
    window.startup_mode = "SimpleFullscreen";
  };

  domestique-zoom = pkgs.writeShellApplication {
    name = "domestique-zoom";
    text = ''
      exec ${config.programs.alacritty.package}/bin/alacritty \
        --config-file "$HOME/.config/alacritty/domestique.toml" \
        -e ${domestique}/bin/domestique "$@"
    '';
  };
in
{
  options.hmFoundry.dev.domestique = {
    enable = lib.mkEnableOption "domestique ride-mode speech for pi";

    voice = lib.mkOption {
      type = lib.types.str;
      default = "af_heart";
      description = ''
        Kokoro voice, used for both channels. Responses are marked by the cue
        rather than by a second voice.

        af_heart is the only voice Kokoro grades A, with af_bella at A-;
        everything else drops to B- and below, and no American male voice
        exceeds C+. Grades are published in the model card's VOICES.md.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "mlx-community/Kokoro-82M-bf16";
      description = ''
        Hugging Face repo for the MLX Kokoro weights. Fetched on first run into
        the shared HF cache.
      '';
    };

    sttModel = lib.mkOption {
      type = lib.types.str;
      default = "mlx-community/parakeet-tdt-0.6b-v3";
      description = ''
        Hugging Face repo for the recognizer weights, used by
        `domestique-transcribe`. 2.4GB, fetched on first run into the shared HF
        cache.

        Parakeet rather than Whisper because a trainer supplies a running fan,
        elevated breathing and long pauses mid-sentence, which is where
        Whisper's autoregressive decoder invents fluent text. A transducer emits
        a blank per frame instead, so silence produces nothing. Nobody is
        reading the screen to catch the difference.
      '';
    };

    speed = lib.mkOption {
      type = lib.types.str;
      default = "1.0";
      description = ''
        Kokoro speech rate multiplier, and the rate every ride starts at.
        Distinct from `say -r`: this stretches the generated audio rather than
        selecting words per minute.

        `/speed 1.3` moves it mid-ride and `/speed +` nudges it by 0.1, clamped
        to 0.5 through 2.0. The watcher forgets that on restart, so a rate worth
        keeping belongs here. Either way it applies to the next utterance, not
        the one already playing.
      '';
    };

    narrateThinking = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Speak the model's thinking while it streams, ahead of the answer.

        It fills the wait on a slow turn, at the cost of hearing the model talk
        itself toward something it then says again. Thinking also shares the one
        voice with the answer, so only the cue distinguishes them.

        pi spools thinking either way; the watcher drops it unread when this is
        off. `DOMESTIQUE_NARRATE_THINKING=1 domestique` turns it back on for one
        ride without a rebuild.
      '';
    };

    lexicon = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {
        SIGTERM = "sˈɪɡtɜɹm";
        SIGKILL = "sˈɪɡkˌɪl";
        YAML = "jˈæmᵊl";
        k8s = "kˈAts";
        systemd = "sˈɪstəm dˈi";
        PostgreSQL = "pˈOstɡɹɛs kjˌuˈɛl";
        NixOS = "nˈɪksOˌɛs";
        ArgoCD = "ˈɑɹɡO sˌidˈi";
        AWS = "ˈA dˈʌbᵊlju ˈɛs";
        Clojure = "klˈOʒəɹ";
        nixfmt = "nˈɪks fˈɔɹmˌæt";
        sabnzbd = "sˈæb ˈɛn zˈi bˈi dˈi";
        ODROID = "ˈɑd ɹˈYd";
        NaN = "nˈæn";
        GEMM = "ʤˈɛm";
        SIMD = "sˈɪmdˌi";
        TFLOPS = "tˈɛɹəflˌɑps";
        SMEM = "ˈɛs mˈɛm";
        TMEM = "tˈi mˈɛm";
        MoE = "ˈɛm ˈO ˈi";
        CuTe = "kjˈut";
        RoPE = "ɹˈOp";
        comptime = "kˈɑmp tˈIm";
        # Qwen takes its q from pinyin Qianwen, and NVIDIA spells NCCL nickel:
        # https://github.com/NVIDIA/nccl/blob/v2.28.3-1/README.md
        Qwen = "ʧwˈɛn";
        NCCL = "nˈɪkᵊl";
        RoCE = "ɹˈɑki";
      };
      example = {
        kubectl = "kjˈubkəntɹOl";
      };
      description = ''
        Term to phonemes, for words the default grapheme-to-phoneme gets wrong.
        This is the whole reason speech is Kokoro rather than `say`, which
        cannot be taught a pronunciation at any price.

        Phonemes are misaki's IPA variant, where capitals are diphthongs: A is
        /eɪ/, I is /aɪ/, O is /oʊ/, W is /aʊ/, Y is /ɔɪ/. Stress marks are
        ˈprimary and ˌsecondary. To see what a term currently resolves to,
        `domestique-phonemes SIGTERM`.

        Only add terms that are actually wrong. The default dictionary already
        handles nginx as "engine X", ZFS and vmagent as initialisms, tmux,
        OAuth, PromQL and Grafana, and reads aarch64 as "arch sixty four",
        ROCm as "rock em" and CUTLASS as a word. Its failures are acronyms it
        spells out letter by letter, and acronyms it runs together into a word
        when the letters were meant.

        Each entry is registered under both its own casing and lowercase,
        because misaki resolves an all-caps token through its acronym path and
        a mixed-case one through its proper-noun path.
      '';
    };

    inputDevice = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "MacBook Pro Microphone";
      description = ''
        Microphone for push to talk, as a sounddevice name or index. Empty
        takes the system default.

        Worth pinning to the built-in microphone when the answers play through
        AirPods. macOS routes an open input on a Bluetooth headset over HFP,
        which drops that headset's output to telephone quality for as long as
        the stream is open. `domestique-listen` opens the microphone only while
        the key is held for the same reason.
      '';
    };

    cueSound = lib.mkOption {
      type = lib.types.str;
      default = "Glass";
      description = ''
        Name of a sound under /System/Library/Sounds, rung when a reply starts.
        It tells a rider who is not looking at the screen that the answer has
        begun, and under narrateThinking it is the only thing separating the
        answer from the thinking, both channels sharing one voice.

        Submarine is the warmer alternative and works on the same pattern. Both
        it and Glass run past a second, so under a three-strike pattern the
        strikes overlap into one gesture; Tink is short enough that they stay
        audibly separate.

        Rung once per reply, on entry into answer mode rather than per
        sentence. Its onset also covers the Bluetooth wake, so a cued utterance
        skips wakePadMs.
      '';
    };

    cuePattern = lib.mkOption {
      type = lib.types.str;
      default = "0:0,0.15:4,0.30:7";
      example = "0:0,0.16:4";
      description = ''
        Comma-separated `onset:semitones` pairs: when each strike lands, in
        seconds from the start, and how far it is pitch-shifted. A rising
        interval reads as finished where a flat repeat reads as merely
        repeated.

        The default is a three-strike major triad. `0:0,0.16:4` is the
        two-strike major third and `0:0` a single strike, both of which start
        the reply sooner: speech begins cueLead after the *last* onset, so each
        extra strike delays the answer by its own onset.
      '';
    };

    listenCueSound = lib.mkOption {
      type = lib.types.str;
      default = "Tink";
      description = ''
        Sound under /System/Library/Sounds marking the microphone opening and
        closing, pitched down on the way in and up on the way out. Without it a
        rider who is not looking at the screen has no way to know the key
        registered.

        Short on purpose. These two land far more often than the answer bell,
        and the closing one sits between the question and the reply. Glass and
        Submarine both run past a second, which is why the answer keeps them
        and this does not.

        Shares cueGain with the answer bell, so setting that to 0 silences
        every cue.
      '';
    };

    cueGain = lib.mkOption {
      type = lib.types.str;
      default = "0.30";
      description = ''
        Cue amplitude, 0 to 1. System sounds are mastered far louder than
        synthesized speech, so unattenuated they startle.
      '';
    };

    cueLead = lib.mkOption {
      type = lib.types.str;
      default = "0.25";
      description = ''
        Seconds between the last cue strike and the first syllable. Speech
        overlaps the decay rather than waiting it out; trimming the decay
        instead turns a bell into a click.
      '';
    };

    wakePadMs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 350;
      description = ''
        Milliseconds of leading silence prepended to an uncued utterance that
        follows a gap. Bluetooth output (AirPods) leaves low-power state on the
        first sample and swallows the opening syllable. Set to 0 on wired
        output or speakers.
      '';
    };

    wakeGapSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Silence, in seconds, after which the next utterance gets wakePadMs.
        Consecutive sentences inside one turn do not need the pad, and paying
        it every sentence is constant dead air.
      '';
    };

    pollSeconds = lib.mkOption {
      type = lib.types.str;
      default = "0.1";
      description = ''
        Spool poll interval. Also the worst-case lag on `/hush` and on a
        response preempting thinking, so keep it well under a syllable.
      '';
    };

    rideDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/work/rides";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/work/rides"'';
      description = ''
        Parent of the per-ride working directories. A ride runs in
        `<rideDir>/<YYYY-MM-DD>`, which becomes pi's $PWD and is therefore the
        only place outside ~/.pi the sandbox lets the agent write
        (`nix/pkgs/pi-wrapper/wrapper.sh`, write_paths). Notes taken during a
        ride land there, `transcript.md` records everything said aloud, and
        `.sessions` holds one session file per topic.

        One directory per day rather than per ride. A second ride appends to
        the same transcript, under its own timestamped headings, and the whole
        day reads as one document.

        `domestique-review` opens the newest of these in an ordinary pi
        session with the same `--allow-read` grants and no speech, which is
        the pass that turns a ride into actions.
      '';
    };

    repos = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "/Users/me/src/org/infra" ];
      description = ''
        Repositories the ride session may read, and that `domestique-fetch`
        freshens before a ride. Absolute paths; a `.bare` subdirectory is
        detected and fetched into.

        Read-only is deliberate and sufficient. `git log`, `git diff` and
        `git status` all work against a repo the sandbox can only read, so the
        agent needs no write access to reason about code. Granting writes so it
        could pull itself would reopen the `.git/hooks` persistence trap the
        wrapper closes for $PWD (see nix/pkgs/pi-wrapper/wrapper.sh), across
        every repo listed here, and a pull into a worktree holding uncommitted
        work is destructive on its own.

        These become `--allow-read` arguments, not
        `pi-coding-agent.sandbox.allowedReadPaths`, so ordinary pi sessions
        keep the narrower default-deny posture and only a ride widens it.

        Host-specific by nature: set this where the paths belong rather than in
        a shared profile.
      '';
    };

    allowBundles = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "linear" ];
      description = ''
        Network bundles opened for every ride, passed as the pi wrapper's
        `--allow-<name>` flags. Each name must exist in
        `pi-coding-agent.sandbox.networkBundles`, since the wrapper hard-fails
        on an unknown bundle rather than ignoring it.

        This is how a ride reaches a vendor API that ordinary pi sessions
        cannot. `linear` is the case it was built for: the credential arrives
        through the wrapper's envFromCommands and is therefore present in every
        session on the host, so egress is the only control left that a single
        session can hold. Without the domain the key is inert.

        Empty by default, and it has to stay that way here. domestique is
        enabled on every darwin host, while the bundles it wants are defined
        beside the credentials they serve.
      '';
    };

    fetchTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Per-repo timeout for `domestique-fetch`. Fetch cost tracks new objects
        rather than repo size, so a warm multi-gigabyte repo lands in about a
        second and this only bounds a stalled remote.
      '';
    };

    listenBackground = lib.mkOption {
      type = lib.types.str;
      default = "#0f3d0f";
      example = "";
      description = ''
        Background the ride window takes while the push-to-talk key is held,
        applied with `alacritty msg config` and dropped again on release. Empty
        turns it off, and anything but Alacritty ignores it.

        tmux ignores it too, which is not obvious because nothing fails: the
        message is delivered and Alacritty does change its background, but tmux
        paints every cell from its own `window-style`, so the terminal
        background never shows through. A ride started inside tmux is therefore
        never green. Use `domestique-zoom`, which is a bare Alacritty window
        with no multiplexer in the way.

        This is the cues' signal in the other sense, for a glance rather than
        an ear, and it is the whole window rather than a status line because
        peripheral vision at 200 watts does not read text.

        Dark on purpose. The window is fullscreen at 24pt, and a saturated
        green behind gruvbox foreground is both unreadable and unpleasant for
        the hour a ride lasts.
      '';
    };

    zoom = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.programs.alacritty.enable && config.programs.alacritty.package != null;
        defaultText = lib.literalExpression "config.programs.alacritty.enable && config.programs.alacritty.package != null";
        description = ''
          Write ~/.config/alacritty/domestique.toml, and `domestique-zoom`,
          which opens a ride in a window using it.

          That file is an overlay rather than a second config. Alacritty loads
          imports in order with the importing file last, and a field already
          set by an import is replaced, so importing alacritty.toml and setting
          two fields inherits the colors and the font family and keeps them in
          step with the desk config (man 5 alacritty, general.import).
        '';
      };

      fontSize = lib.mkOption {
        type = lib.types.number;
        default = 24;
        description = ''
          Point size in the ride window, against 13 at the desk. Chosen to be
          readable from the bars at arm's length, and untested until a ride
          says otherwise.
        '';
      };
    };

    ridePrompt = lib.mkOption {
      type = lib.types.lines;
      default = ''
        Your replies are spoken aloud through headphones. The user is riding a
        stationary bike, cannot see the screen, and cannot read code.

        Write two to four sentences of plain prose. No lists, no code blocks,
        no file paths, no line numbers, no URLs, no version numbers.

        Lead with the conclusion. Support it in one sentence, or not at all.

        If the answer only makes sense written down, say that it is on screen
        and move on. Do not read it out.

        Ask at most one question per reply, and make it answerable in a
        sentence. Stacked questions cannot be held in working memory at 200
        watts.

        Write technical names normally. Pronunciation is handled downstream, so
        respelling them here only makes the text harder to read back.
      '';
      description = ''
        Text appended to pi's system prompt in ride mode, via
        `--append-system-prompt`. Written to ~/.pi/domestique/ride-prompt.md
        by the watcher.

        This is what keeps responses short enough to stream. Compressing a
        long response after the fact is not an option: streaming means there
        is nothing to compress until generation has already finished.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = ''
          hmFoundry.dev.domestique reads its cue from /System/Library/Sounds and
          assumes CoreAudio; there is no Linux path yet.
        '';
      }
      {
        assertion = lib.all (
          b: builtins.hasAttr b config.hmFoundry.dev.pi-coding-agent.sandbox.networkBundles
        ) cfg.allowBundles;
        message =
          let
            unknown = lib.filter (
              b: !builtins.hasAttr b config.hmFoundry.dev.pi-coding-agent.sandbox.networkBundles
            ) cfg.allowBundles;
          in
          ''
            hmFoundry.dev.domestique.allowBundles names ${lib.concatStringsSep ", " unknown},
            which pi-coding-agent.sandbox.networkBundles does not define. The
            wrapper exits on an unknown bundle, so this would otherwise surface
            at the start of a ride, after the venv and model load.
          '';
      }
      {
        assertion =
          !cfg.zoom.enable || (config.programs.alacritty.enable && config.programs.alacritty.package != null);
        message = ''
          hmFoundry.dev.domestique.zoom.enable needs programs.alacritty enabled
          with a package: domestique-zoom execs the terminal itself.
        '';
      }
    ];

    warnings = lib.optional (!config.programs.git.enable) ''
      hmFoundry.dev.domestique: programs.git.enable is false, so the
      core.hooksPath include below is never written. A hook the agent leaves in
      a ride clone under ~/.pi/domestique/gitdirs would then run under the
      rider's own git.
    '';

    xdg.configFile."alacritty/domestique.toml" = lib.mkIf cfg.zoom.enable {
      source = zoomConfig;
    };

    # A clone_repo checkout keeps its git directory under ~/.pi so that `config`
    # sits outside any path ending .git/config, which srt refuses to write at any
    # depth. The cost is that `hooks` lands outside the matching .git/hooks deny
    # and becomes writable. The agent's own git ignores hooks via GIT_CONFIG
    # core.hooksPath; this covers the rider's git against the same directory
    # afterwards, which is the only place one would run unsandboxed. The trailing
    # slash is what makes git append `**` (git-config(1), Conditional includes).
    programs.git.includes = [
      {
        condition = "gitdir:${config.home.homeDirectory}/.pi/domestique/gitdirs/";
        contents.core.hooksPath = "/dev/null";
      }
    ];

    home.packages = [
      domestique
      domestique-speak
      domestique-listen
      domestique-fetch
      domestique-phonemes
      domestique-transcribe
      domestique-review
    ]
    ++ lib.optional cfg.zoom.enable domestique-zoom;
  };
}

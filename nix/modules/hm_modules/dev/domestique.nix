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
# Usage: `domestique` starts the watcher and pi together. `domestique-speak`
# alone is the two-pane form, and prints the matching pi invocation.
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
        if timeout "${toString cfg.fetchTimeoutSeconds}" \
          git -C "$gitdir" fetch --all --prune --quiet 2>/dev/null; then
          printf 'domestique-fetch: %-40s ok\n' "$repo"
        else
          printf 'domestique-fetch: %-40s FAILED\n' "$repo"
          failed=$((failed + 1))
        fi
      done

      # Stale refs still make for a usable ride, so this reports rather than
      # aborts.
      [ "$failed" -eq 0 ] || printf 'domestique-fetch: %d of %d failed\n' \
        "$failed" "''${#REPOS[@]}" >&2
    '';
  };

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
      export DOMESTIQUE_STT_MODEL="${cfg.sttModel}"
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
      export DOMESTIQUE_STT_MODEL="${cfg.sttModel}"
      export DOMESTIQUE_INPUT_DEVICE="''${DOMESTIQUE_INPUT_DEVICE:-${cfg.inputDevice}}"
      export DOMESTIQUE_POLL_SECONDS="${cfg.pollSeconds}"
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
      export DOMESTIQUE_VOICE="''${DOMESTIQUE_VOICE:-${cfg.voice}}"
      export DOMESTIQUE_MODEL="${cfg.model}"
      export DOMESTIQUE_SPEED="''${DOMESTIQUE_SPEED:-${cfg.speed}}"
      export DOMESTIQUE_NARRATE_THINKING="''${DOMESTIQUE_NARRATE_THINKING:-${
        if cfg.narrateThinking then "1" else "0"
      }}"
      export DOMESTIQUE_CUE_SOUND="''${DOMESTIQUE_CUE_SOUND:-${cfg.cueSound}}"
      export DOMESTIQUE_CUE_PATTERN="''${DOMESTIQUE_CUE_PATTERN:-${cfg.cuePattern}}"
      export DOMESTIQUE_LISTEN_CUE_SOUND="${cfg.listenCueSound}"
      export DOMESTIQUE_CUE_GAIN="${cfg.cueGain}"
      export DOMESTIQUE_CUE_LEAD="${cfg.cueLead}"
      export DOMESTIQUE_WAKE_PAD_MS="${toString cfg.wakePadMs}"
      export DOMESTIQUE_WAKE_GAP_SECONDS="${toString cfg.wakeGapSeconds}"
      export DOMESTIQUE_POLL_SECONDS="${toString cfg.pollSeconds}"

      exec "$VENV/bin/python" ${./domestique-tts.py} "$@"
    '';
  };

  # The --allow-read flags are the reason this exists. Every configured repo is
  # a bare checkout whose worktrees carry a .git file pointing at a sibling
  # .bare, so granting pi the worktree alone leaves git unable to reach its own
  # object store, and every history command fails on the gitdir instead.
  domestique = pkgs.writeShellApplication {
    name = "domestique";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      readonly ROOT="$HOME/.pi/domestique"
      readonly SPOOL="$ROOT/spool"
      readonly SPEAKING="$ROOT/watcher.speaking"

      shopt -s nullglob
      mkdir -p "$ROOT"

      started=()

      alive() {
        [ -e "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null
      }

      launch() {
        local name="$1" bin="$2" pidfile="$3" ready="$4" log="$5"
        if [ -e "$ready" ] && alive "$pidfile"; then
          return
        fi
        "$bin" >>"$log" 2>&1 &
        started+=("$pidfile")
        # The first run of all builds a venv and downloads a model, so this
        # waits in minutes rather than seconds. Steady state is a few.
        local waited=0
        while [ "$waited" -lt 3000 ] && [ ! -e "$ready" ]; do
          sleep 0.2
          waited=$((waited + 1))
        done
        if [ ! -e "$ready" ]; then
          printf 'domestique: %s did not come up, see %s\n' "$name" "$log" >&2
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
      pi${piFlags} --domestique \
        --append-system-prompt "$ROOT/ride-prompt.md" "$@" || true

      if [ "''${#started[@]}" -gt 0 ]; then
        # A pi exit drops the thinking channel but leaves the response queued,
        # so the watcher has to outlive it by however long the answer takes.
        waited=0
        while [ "$waited" -lt 300 ]; do
          queue=("$SPOOL"/*-speak.txt)
          if [ "''${#queue[@]}" -eq 0 ] && [ ! -e "$SPEAKING" ]; then
            break
          fi
          sleep 0.2
          waited=$((waited + 1))
        done
        for pidfile in "''${started[@]}"; do
          kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
        done
      fi
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
    ];

    home.packages = [
      domestique
      domestique-speak
      domestique-listen
      domestique-fetch
      domestique-phonemes
      domestique-transcribe
    ];
  };
}

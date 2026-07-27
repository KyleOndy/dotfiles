# domestique: voice-driven pi for Zone 2 trainer rides.
#
# This module is the audio-out half. `domestique-speak` runs OUTSIDE pi's
# sandbox and owns playback, because inside strict mode the CoreAudio mach
# lookup is denied and srt's settings schema (nix/pkgs/pi-wrapper/wrapper.sh)
# has no mach knob. The pi-side half is extensions/domestique.ts, which writes
# one file per utterance into ~/.pi/domestique/spool and nothing else.
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
  requirementsFile = pkgs.writeText "domestique-requirements.txt" ''
    mlx-audio
    misaki
    espeakng-loader
    num2words
    phonemizer-fork
    spacy
    soundfile
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
        "${allowReadFlags}" "$PROMPT"

      export DOMESTIQUE_ROOT="$ROOT"
      export DOMESTIQUE_VOICE="''${DOMESTIQUE_VOICE:-${cfg.voice}}"
      export DOMESTIQUE_MODEL="${cfg.model}"
      export DOMESTIQUE_SPEED="''${DOMESTIQUE_SPEED:-${cfg.speed}}"
      export DOMESTIQUE_CUE_SOUND="''${DOMESTIQUE_CUE_SOUND:-${cfg.cueSound}}"
      export DOMESTIQUE_CUE_PATTERN="''${DOMESTIQUE_CUE_PATTERN:-${cfg.cuePattern}}"
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
      readonly PIDFILE="$ROOT/watcher.pid"
      readonly READY="$ROOT/watcher.ready"
      readonly SPEAKING="$ROOT/watcher.speaking"
      readonly LOG="$ROOT/speak.log"

      shopt -s nullglob
      mkdir -p "$ROOT"

      watcher_alive() {
        [ -e "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
      }

      started=0
      if [ ! -e "$READY" ] || ! watcher_alive; then
        ${domestique-speak}/bin/domestique-speak >>"$LOG" 2>&1 &
        started=1
        # The first run of all builds a venv and downloads the voice model, so
        # this waits in minutes rather than seconds. Steady state is ~3s.
        waited=0
        while [ "$waited" -lt 3000 ] && [ ! -e "$READY" ]; do
          sleep 0.2
          waited=$((waited + 1))
        done
        if [ ! -e "$READY" ]; then
          printf 'domestique: watcher did not come up, see %s\n' "$LOG" >&2
          exit 1
        fi
        printf 'domestique: watcher ready, logging to %s\n' "$LOG"
      fi

      # --allow-read belongs to the pi wrapper, --domestique to pi, and the
      # wrapper's arg loop breaks at the first flag it does not own
      # (nix/pkgs/pi-wrapper/wrapper.sh). Anything after --domestique reaches pi
      # verbatim, which rejects --allow-read outright, so wrapper flags go first.
      pi${allowReadFlags} --domestique \
        --append-system-prompt "$ROOT/ride-prompt.md" "$@" || true

      if [ "$started" -eq 1 ]; then
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
        kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
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

    speed = lib.mkOption {
      type = lib.types.str;
      default = "1.0";
      description = ''
        Kokoro speech rate multiplier. Distinct from `say -r`: this stretches
        the generated audio rather than selecting words per minute.
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
        OAuth, PromQL and Grafana. Its failures are acronyms it spells out
        letter by letter.

        Each entry is registered under both its own casing and lowercase,
        because misaki resolves an all-caps token through its acronym path and
        a mixed-case one through its proper-noun path.
      '';
    };

    cueSound = lib.mkOption {
      type = lib.types.str;
      default = "Glass";
      description = ''
        Name of a sound under /System/Library/Sounds, rung when a reply starts.
        This is what separates an answer from thinking, both channels sharing
        one voice.

        Rung once per reply, on entry into answer mode rather than per
        sentence. Its onset also covers the Bluetooth wake, so a cued utterance
        skips wakePadMs.
      '';
    };

    cuePattern = lib.mkOption {
      type = lib.types.str;
      default = "0:0,0.16:4";
      example = "0:0,0.15:4,0.30:7";
      description = ''
        Comma-separated `onset:semitones` pairs: when each strike lands, in
        seconds from the start, and how far it is pitch-shifted. A rising
        interval reads as finished where a flat repeat reads as merely
        repeated.

        The default is a two-strike major third. `0:0,0.15:4,0.30:7` is the
        three-strike major triad; a single strike is `0:0`. Speech begins
        cueLead after the *last* onset, so more strikes delay the reply.
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
      domestique-fetch
      domestique-phonemes
    ];
  };
}

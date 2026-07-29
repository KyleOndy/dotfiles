#!/usr/bin/env python3
"""Speak pi's spooled utterances with Kokoro.

macOS `say` cannot be taught a pronunciation. Every one of its voices shares a
single text front end, and its phoneme escape [[inpt PHON]] is spoken literally
rather than interpreted, so a mangled technical term has no fix at all. Kokoro
accepts phonemes, so a term only needs a lexicon entry.

Grapheme-to-phoneme runs here rather than inside Kokoro's pipeline: the lexicon
is ours, and handing the model a finished phoneme string means a future rename
inside mlx-audio breaks startup loudly instead of silently degrading
pronunciation back to the defaults.

The spool protocol is the pi extension's (extensions/domestique.ts): one file
per utterance, named `<zero-padded-seq>-<channel>.txt`, published by rename.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

SR = 24000

# KokoroPipeline.generate_from_tokens raises above this.
PHONEME_LIMIT = 510


def log(msg: str) -> None:
    print(f"domestique: {msg}", flush=True)


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def number(name: str, default: str, floor: float) -> float:
    """Read a setting that arrives as an unvalidated string from nix.

    Parsed at import, which is before the ready file exists, so a raise here
    reads to the launcher as a watcher that is merely slow to start. The floor
    is what keeps a poll interval of 0 from spinning a core for the ride.
    """
    try:
        value = float(env(name, default))
    except ValueError:
        value = float(default)
        log(f"{name} is not a number, using {value}")
    return max(floor, value)


ROOT = Path(env("DOMESTIQUE_ROOT", str(Path.home() / ".pi/domestique")))
SPOOL = ROOT / "spool"
STOP = ROOT / "stop"
STOP_THINK = ROOT / "stop-think"
PIDFILE = ROOT / "watcher.pid"
READY = ROOT / "watcher.ready"

# Rate for the next utterance, written by /speed. State rather than an event, so
# unlike `stop` it survives being read. The utterance already playing was
# synthesized as one buffer and keeps the rate it was made at.
SPEED_FILE = ROOT / "speed"

# An empty spool is not silence: an utterance leaves the spool when synthesis
# starts, not when playback ends. `domestique` waits on this to know a reply has
# finished before it takes the watcher down.
SPEAKING = ROOT / "watcher.speaking"

# Written by Karabiner while the push-to-talk key is held
# (nix/modules/hm_modules/desktop/input/karabiner.nix). Read here as well as by
# the recorder, because the answer has to get out of the rider's way and the
# device that says so is this one.
LISTENING = ROOT / "listening"

VOICE = env("DOMESTIQUE_VOICE", "af_heart")
MODEL = env("DOMESTIQUE_MODEL", "mlx-community/Kokoro-82M-bf16")
SPEED = number("DOMESTIQUE_SPEED", "1.0", 0.1)
NARRATE_THINKING = env("DOMESTIQUE_NARRATE_THINKING", "0") == "1"
ESPEAK = env("DOMESTIQUE_ESPEAK", "")
LEXICON_PATH = env("DOMESTIQUE_LEXICON", "")
CUE_SOUND = env("DOMESTIQUE_CUE_SOUND", "Glass")
CUE_PATTERN = env("DOMESTIQUE_CUE_PATTERN", "0:0,0.15:4,0.30:7")
CUE_GAIN = number("DOMESTIQUE_CUE_GAIN", "0.30", 0.0)
CUE_LEAD = number("DOMESTIQUE_CUE_LEAD", "0.25", 0.0)

# Cues for the microphone rather than the answer, and the only sign a rider who
# is not looking at the screen has that the key registered. A short sound, since
# these two land far more often than the answer bell and the second of them
# stands between the question and the reply.
LISTEN_CUE_SOUND = env("DOMESTIQUE_LISTEN_CUE_SOUND", "Tink")
LISTEN_OPEN_PATTERN = "0:-3"
LISTEN_CLOSE_PATTERN = "0:4"

# The same signal as the cues, for eyes rather than ears. Socket and window come
# from the terminal that started this watcher, which `domestique` makes the ride
# window; both are empty anywhere but Alacritty, and the tint is then skipped.
LISTEN_BACKGROUND = env("DOMESTIQUE_LISTEN_BACKGROUND", "#0f3d0f")
ALACRITTY = env("DOMESTIQUE_ALACRITTY", "")
ALACRITTY_SOCKET = env("ALACRITTY_SOCKET", "")
ALACRITTY_WINDOW = env("ALACRITTY_WINDOW_ID", "")

WAKE_PAD_MS = int(env("DOMESTIQUE_WAKE_PAD_MS", "350"))
WAKE_GAP_SECONDS = float(env("DOMESTIQUE_WAKE_GAP_SECONDS", "3"))
POLL_SECONDS = number("DOMESTIQUE_POLL_SECONDS", "0.1", 0.01)

# Bounds on /speed. A fat-fingered 12 instead of 1.2 would otherwise cost the
# rest of the ride, and there is no way to see what you typed from the bike.
SPEED_MIN = 0.5
SPEED_MAX = 2.0


# --- espeak ------------------------------------------------------------------


def wire_espeak() -> None:
    """Point misaki at a real espeak-ng.

    The espeakng-loader wheel bakes its build machine's data path into the
    dylib it ships, so out of the box it looks for phontab under a
    /Users/runner/work path that exists only on the CI box that built it. The
    loader's getters are read at misaki.espeak import time, so overriding them
    first is enough and the installed venv stays untouched.
    """
    if not ESPEAK:
        return
    import espeakng_loader

    espeakng_loader.get_library_path = lambda: f"{ESPEAK}/lib/libespeak-ng.dylib"
    espeakng_loader.get_data_path = lambda: f"{ESPEAK}/share/espeak-ng-data"


# --- lexicon -----------------------------------------------------------------


def load_lexicon() -> dict[str, str]:
    if not LEXICON_PATH or not Path(LEXICON_PATH).is_file():
        return {}
    return json.loads(Path(LEXICON_PATH).read_text())


def install_lexicon(g2p, lexicon: dict[str, str]) -> int:
    """Add each term under both its own casing and lowercase.

    Lowercase alone is not enough. misaki resolves an all-caps token through
    its acronym path and a mixed-case one through its proper-noun path, so
    K8S and NixOS both miss a key stored as k8s or nixos.
    """
    golds = g2p.lexicon.golds
    for term, phonemes in lexicon.items():
        golds[term] = phonemes
        golds[term.lower()] = phonemes
    return len(lexicon)


# --- cue ---------------------------------------------------------------------


def resample_mono(audio, src_sr: int):
    import numpy as np

    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if src_sr == SR:
        return audio.astype(np.float32)
    n = int(len(audio) * SR / src_sr)
    idx = np.arange(n) * (src_sr / SR)
    return np.interp(idx, np.arange(len(audio)), audio).astype(np.float32)


def pitch_shift(audio, semitones: float):
    """Resample to shift pitch. Fine for a bell, wrong for speech."""
    import numpy as np

    if semitones == 0:
        return audio
    ratio = 2.0 ** (semitones / 12.0)
    n = int(len(audio) / ratio)
    idx = np.arange(n) * ratio
    return np.interp(idx, np.arange(len(audio)), audio).astype(np.float32)


def build_cue(sound: str = CUE_SOUND, pattern: str = CUE_PATTERN):
    """Pre-mix the bell stack once; per-utterance cost is then a copy.

    Returns (buffer, lead_samples), where lead_samples is where speech starts:
    CUE_LEAD after the *last* bell onset, so the bells stay a single gesture
    and speech lands over the final decay rather than after it. Trimming the
    decay instead turns a bell into a click.
    """
    import numpy as np
    import soundfile as sf

    path = Path(f"/System/Library/Sounds/{sound}.aiff")
    if not path.is_file():
        log(f"cue sound {sound} not found, running without a cue")
        return None, 0

    raw, src_sr = sf.read(str(path), dtype="float32")
    bell = resample_mono(raw, src_sr)

    hits = []
    for spec in pattern.split(","):
        if not spec.strip():
            continue
        onset, _, semis = spec.partition(":")
        try:
            hits.append((float(onset), float(semis or 0)))
        except ValueError:
            log(f"cue strike {spec!r} is not onset:semitones, ignoring it")
    if not hits:
        log(f"cue pattern {pattern!r} has no usable strikes, running without one")
        return None, 0

    # Speech lands after the last bell, which is the largest onset rather than
    # the one written last.
    lead = int((max(onset for onset, _ in hits) + CUE_LEAD) * SR)
    shifted = [(int(o * SR), pitch_shift(bell, s)) for o, s in hits]
    length = max(lead, max(p + len(b) for p, b in shifted))
    buf = np.zeros(length, dtype=np.float32)
    for pos, b in shifted:
        buf[pos : pos + len(b)] += b * CUE_GAIN
    return buf, lead


def with_cue(cue, lead, speech):
    import numpy as np

    if cue is None:
        return speech
    n = max(len(cue), lead + len(speech))
    buf = np.zeros(n, dtype=np.float32)
    buf[: len(cue)] += cue
    buf[lead : lead + len(speech)] += speech
    return np.clip(buf, -1.0, 1.0)


def with_pad(speech, millis: int):
    import numpy as np

    if millis <= 0:
        return speech
    return np.concatenate([np.zeros(int(millis / 1000 * SR), dtype=np.float32), speech])


# --- window ------------------------------------------------------------------


def tint(on: bool) -> None:
    if not (ALACRITTY and ALACRITTY_SOCKET and ALACRITTY_WINDOW and LISTEN_BACKGROUND):
        return
    cmd = [ALACRITTY, "msg", "-s", ALACRITTY_SOCKET, "config", "-w", ALACRITTY_WINDOW]
    # -r drops every runtime override, which is the whole of this one. The ride
    # window's own font and fullscreen come from domestique.toml, not from here.
    cmd += [f'colors.primary.background="{LISTEN_BACKGROUND}"'] if on else ["-r"]
    try:
        subprocess.run(
            cmd, timeout=1, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except Exception as exc:
        log(f"tint failed: {exc}")


# --- synthesis ---------------------------------------------------------------


def speakable(text: str) -> str:
    """Turn code punctuation into word boundaries.

    Kokoro is handed phonemes, so what misaki makes of punctuation is final.
    Its vocabulary carries `.` and `:`, which land as a pause inside a name,
    and lacks `-`, `_` and `/` entirely, so the words those join fuse into one:
    read-only phonemizes to ɹˈidˌOnli.

    Backticks mark text known to be code, so inside them a slash, a scope
    operator and call parens are word boundaries too. camelCase splits only
    there, and only before a lowercase letter, an uppercase run being an
    acronym rather than a boundary. Lexicon lookup is an exact match on a whole
    token, and PostgreSQL split in two reads "postgur sequel".
    """

    def expand(m: re.Match) -> str:
        code = re.sub(r"::|[/()]", " ", m.group(1))
        return re.sub(r"(?<=[a-z])(?=[A-Z][a-z])", " ", code)

    text = re.sub(r"`([^`]+)`", expand, text)
    # A span straddling a sentence boundary leaves one tick behind, and misaki
    # reads a lone tick as an open quote.
    text = text.replace("`", " ")
    text = text.replace("_", " ")
    text = re.sub(r"(?<=\w)-(?=\w)", " ", text)
    # A dot after a digit is a decimal, and one before a space or the end of
    # the utterance ends a sentence. Anything else joins two names.
    text = re.sub(r"(?<![\d\s])\.(?=[^\W\d])", " ", text)
    # A span ending in a separator, `listUsers()` most of all, leaves the
    # sentence punctuation behind it detached and misaki keeps it a token.
    text = re.sub(r"\s+(?=[.,!?;:])", "", text)
    return re.sub(r"\s+", " ", text).strip()


def chunk_phonemes(phonemes: str) -> list[str]:
    """Split an over-long phoneme string on word boundaries."""
    if len(phonemes) <= PHONEME_LIMIT:
        return [phonemes]
    chunks, current = [], ""
    for word in phonemes.split(" "):
        candidate = f"{current} {word}".strip()
        if len(candidate) > PHONEME_LIMIT and current:
            chunks.append(current)
            current = word
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


def read_speed() -> float:
    try:
        wanted = float(SPEED_FILE.read_text().strip())
    except (OSError, ValueError):
        return SPEED
    return min(SPEED_MAX, max(SPEED_MIN, wanted))


def synth(pipe, g2p, text: str, speed: float):
    import numpy as np

    text = speakable(text)
    # An utterance that was nothing but a straddling backtick has no words left.
    if not text:
        return None
    phonemes, _ = g2p(text)
    parts = []
    for chunk in chunk_phonemes(phonemes):
        for result in pipe.generate_from_tokens(chunk, voice=VOICE, speed=speed):
            if result.audio is not None:
                parts.append(np.asarray(result.audio).reshape(-1))
    if not parts:
        return None
    return np.concatenate(parts)


# --- spool -------------------------------------------------------------------

SEQ = re.compile(r"^(\d+)-")


def seq_of(path: Path) -> str:
    """Sequence as a string. It is zero-padded, so a numeric compare would
    read it as octal in some shells and as a different width here; lexical
    order over equal-width digits is the intended order anyway."""
    m = SEQ.match(path.name)
    return m.group(1) if m else ""


def queue(channel: str) -> list[Path]:
    return sorted(SPOOL.glob(f"*-{channel}.txt"))


def unlink(paths) -> None:
    for p in paths:
        try:
            p.unlink()
        except OSError:
            pass


def main() -> int:
    ROOT.mkdir(parents=True, exist_ok=True)
    SPOOL.mkdir(parents=True, exist_ok=True)

    # A ride ends by SIGTERMing its watchers (dev/domestique.nix). Python's
    # default disposition tears the process down without unwinding, which skips
    # every bit of cleanup below, the window tint most of all: a watcher killed
    # while the push-to-talk key is held would leave the ride window green with
    # nothing left running to put it back.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Two watchers on one spool each consume half the utterances and neither
    # sees the other's kills, so preemption stops working.
    if PIDFILE.exists():
        try:
            os.kill(int(PIDFILE.read_text().strip()), 0)
        except (OSError, ValueError):
            pass
        else:
            print(
                f"domestique-tts: already running as pid {PIDFILE.read_text().strip()}",
                file=sys.stderr,
            )
            return 1
    PIDFILE.write_text(f"{os.getpid()}\n")
    READY.unlink(missing_ok=True)
    SPEAKING.unlink(missing_ok=True)

    # Utterances from an interrupted session would speak the moment the watcher
    # came up, out of context and minutes late. Half-written ones are swept
    # here and nowhere else: pi publishes by rename, so unlinking a .tmp while
    # pi is running throws inside its stream handler.
    unlink(SPOOL.glob("*.txt"))
    unlink(SPOOL.glob("*.tmp"))
    STOP.unlink(missing_ok=True)
    STOP_THINK.unlink(missing_ok=True)
    # A ride starts at the configured rate, and publishing it is what lets
    # /speed step relative to something.
    SPEED_FILE.write_text(f"{SPEED}\n")

    wire_espeak()

    import sounddevice as sd
    from misaki import en, espeak
    from mlx_audio.tts.utils import load_model

    started = time.monotonic()
    g2p = en.G2P(
        trf=False, british=False, fallback=espeak.EspeakFallback(british=False)
    )
    count = install_lexicon(g2p, load_lexicon())
    model = load_model(MODEL)
    pipe = model._get_pipeline("a")
    cue, cue_lead = build_cue()
    open_cue, _ = build_cue(LISTEN_CUE_SOUND, LISTEN_OPEN_PATTERN)
    close_cue, _ = build_cue(LISTEN_CUE_SOUND, LISTEN_CLOSE_PATTERN)

    # First synthesis builds the graph; paying that here rather than on the
    # first thing the rider says keeps the opening reply from arriving late.
    synth(pipe, g2p, "Ready.", SPEED)
    log(
        f"{VOICE} ready in {time.monotonic() - started:.1f}s, "
        f"{count} lexicon terms, cue {CUE_SOUND} [{CUE_PATTERN}], "
        f"{SPEED:.2f}x, thinking {'narrated' if NARRATE_THINKING else 'silent'}"
    )
    READY.write_text("ready\n")

    playing_channel: str | None = None
    last_channel: str | None = None
    last_finished = 0.0

    def active() -> bool:
        try:
            stream = sd.get_stream()
        except Exception:
            return False
        return stream is not None and stream.active

    def hush() -> None:
        nonlocal playing_channel, last_finished
        sd.stop()
        if playing_channel is not None:
            playing_channel = None
            last_finished = time.monotonic()

    def ring(buf) -> None:
        if buf is not None:
            sd.play(buf, SR)

    def start(channel: str, path: Path) -> None:
        nonlocal playing_channel, last_channel, last_finished
        # Synthesis runs between the unlink below and the first sample, and
        # `domestique` takes the watcher down the moment the spool is empty and
        # this file is absent. Claiming it up front is what keeps the last reply
        # of a ride from being killed while it is still being made.
        SPEAKING.touch(exist_ok=True)
        try:
            body = path.read_text()
        except OSError:
            # /hush and a pi shutdown both purge the spool, so an utterance can
            # vanish between the glob and this read.
            return
        unlink([path])
        if not body.strip():
            return

        text = body.strip()
        # This process is unsupervised, so an escaping exception costs the ride
        # its voice while pi goes on spooling into nothing. The utterance is
        # the unit of loss.
        try:
            speed = read_speed()
            audio = synth(pipe, g2p, text, speed)
            if audio is None:
                return

            # The cue marks entry into answer mode, not each sentence of the
            # answer; ringing it between every sentence is unbearable.
            cued = channel == "speak" and last_channel != "speak"
            if cued:
                audio = with_cue(cue, cue_lead, audio)
            elif time.monotonic() - last_finished >= WAKE_GAP_SECONDS:
                # Bluetooth output leaves low-power state on the first sample
                # and swallows the opening syllable. A cue covers that gap.
                audio = with_pad(audio, WAKE_PAD_MS)

            log(
                f"{channel:5} {len(audio) / SR:5.2f}s {speed:.2f}x "
                f"{'cue' if cued else '   '} {text[:60]}"
            )
            sd.play(audio, SR)
        except Exception as exc:
            log(f"dropped {text[:40]!r}: {exc}")
            return
        playing_channel = channel
        last_channel = channel

    listening = False

    try:
        while True:
            if LISTENING.exists() != listening:
                listening = not listening
                if listening:
                    # A rider who has started talking has stopped listening,
                    # and the answer would be recorded along with the question.
                    hush()
                    unlink(SPOOL.glob("*.txt"))
                    # A question is what makes the next utterance an entry into
                    # answer mode. With thinking silent nothing else ever takes
                    # the slot back, so without this the bell rings once a ride.
                    last_channel = None
                tint(listening)
                ring(open_cue if listening else close_cue)

            if STOP.exists():
                STOP.unlink(missing_ok=True)
                hush()
                unlink(SPOOL.glob("*.txt"))

            if STOP_THINK.exists():
                STOP_THINK.unlink(missing_ok=True)
                # pi has gone away. A half-finished thought is noise, but a
                # queued response is the answer that was asked for.
                if playing_channel == "think":
                    hush()
                unlink(queue("think"))

            # pi spools thinking either way. Dropping it here rather than at the
            # source keeps every drop policy in one place.
            if not NARRATE_THINKING:
                unlink(queue("think"))

            speak_queue = queue("speak")

            busy = active()
            if busy:
                SPEAKING.touch(exist_ok=True)
            else:
                SPEAKING.unlink(missing_ok=True)

            if busy:
                # Finishing the thought would leave us a sentence behind for
                # the rest of the turn, and the response is the part worth
                # hearing.
                if playing_channel == "think" and speak_queue:
                    hush()
                else:
                    time.sleep(POLL_SECONDS)
                    continue
            elif playing_channel is not None:
                playing_channel = None
                last_finished = time.monotonic()

            if listening:
                time.sleep(POLL_SECONDS)
                continue

            if speak_queue:
                # Thinking queued before this sentence was narrating the wait
                # for it, and the wait is over.
                cutoff = seq_of(speak_queue[0])
                unlink(p for p in queue("think") if seq_of(p) < cutoff)
                start("speak", speak_queue[0])
                continue

            think_queue = queue("think")
            if think_queue:
                # Thinking outruns speech by roughly 5x, so anything behind the
                # newest sentence describes a place the model has already left.
                unlink(think_queue[:-1])
                start("think", think_queue[-1])
                continue

            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        return 0
    finally:
        sd.stop()
        # A watcher that dies mid-utterance leaves the window green otherwise,
        # and nothing else will ever put it back.
        tint(False)
        PIDFILE.unlink(missing_ok=True)
        READY.unlink(missing_ok=True)
        SPEAKING.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())

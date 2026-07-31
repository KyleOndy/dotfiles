#!/usr/bin/env python3
"""Record while a push-to-talk key is held, transcribe, route by which key.

The microphone is denied inside pi's strict sandbox for the same reason the
speaker is, so this runs beside the speech watcher rather than inside pi, and
the two halves meet in ~/.pi/domestique. Karabiner creates a file on key down
and removes it on key up (nix/modules/hm_modules/desktop/input/karabiner.nix);
everything between those two edges becomes one utterance.

Two channels, told apart by which file exists:

  listening   goes to the pi session, as a message the agent answers.
  outofband   never reaches pi's context. It lands in notes.md in the ride
              directory, and a classifier then decides whether it was also a
              request to change topic.

Writing the note before classifying is what makes a cheap fast classifier safe
here. The two verdicts have wildly different costs: a topic change read as a
note costs a repeat, where a note read as a topic change costs the session. So
the note is on disk before the question is even asked, and note is what every
failure falls back to.

This process also owns key interpretation for the third signal, the replay tap.
Karabiner appends one byte per press and this drains the count; the speech
watcher owns the audio and is told how many replies to repeat. One owner per
file, so the two watchers never race over the same one.

Parakeet rather than Whisper. A transducer emits a blank frame where there is
no speech, and an autoregressive decoder invents fluent text through the pauses
a trainer ride is full of. Nobody is watching the screen to catch the
difference, and a hallucinated instruction reaching the agent is the worst
outcome this design has.

The stream is opened on key down rather than held open for the ride. A Mac
routes an open input to a Bluetooth headset over HFP, which drops the same
headset's output to telephone quality, so an always-listening microphone would
cost every spoken answer for the whole hour.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


def log(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {message}", flush=True)


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def seconds(name: str, default: str, floor: float) -> float:
    """Read a duration that arrives as an unvalidated string from nix.

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

# Written by Karabiner while a key is held. Presence is the whole protocol;
# nothing writes into either.
LISTENING = ROOT / "listening"
OUTOFBAND = ROOT / "outofband"

# One byte per replay tap, appended by Karabiner. A touch would not do: the poll
# below runs at 0.1s and a tap lands entirely between two of them, so what has
# to accumulate is the count rather than the file's existence.
REPLAY = ROOT / "replay"

# The count this hands to the speech watcher once the tapping has stopped.
REPLAY_REQUEST = ROOT / "replay-request"

# Out-of-band speech. The spool belongs to pi's stream and is numbered by the
# extension, so an announcement from here goes through its own door.
SAY = ROOT / "say"

# Read by the wrapper's relaunch loop and by the next session, exactly as the
# extension writes them (extensions/domestique.ts).
TOPIC = ROOT / "topic"
RESTART = ROOT / "restart"

# Finished transcripts, one file per utterance, drained by the pi extension.
HEARD = ROOT / "heard"

PIDFILE = ROOT / "listen.pid"
READY = ROOT / "listen.ready"

# Where a note goes. The ride directory is the launcher's to name, so it
# arrives in the environment (dev/domestique.nix). Falling back to ROOT keeps a
# hand-started listener from dropping notes on the floor.
RIDE = Path(env("DOMESTIQUE_RIDE", "") or ROOT)
NOTES = RIDE / "notes.md"

MODEL = env("DOMESTIQUE_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
INPUT_DEVICE = env("DOMESTIQUE_INPUT_DEVICE", "")
POLL_SECONDS = seconds("DOMESTIQUE_POLL_SECONDS", "0.1", 0.01)

CLASSIFY_MODEL = env("DOMESTIQUE_CLASSIFY_MODEL", "")
CLASSIFY_PROMPT = env("DOMESTIQUE_CLASSIFY_PROMPT", "")
CLASSIFY_TIMEOUT = seconds("DOMESTIQUE_CLASSIFY_TIMEOUT", "20", 1.0)
CANCEL_SECONDS = seconds("DOMESTIQUE_CANCEL_SECONDS", "3", 0.0)

# A tap while reaching for something else is not an utterance.
MIN_SECONDS = seconds("DOMESTIQUE_MIN_UTTERANCE_SECONDS", "0.4", 0.0)

# A key can stick, and a jersey pocket can hold one down. The recording is cut
# here and still transcribed, because the alternative is unbounded memory and
# nothing to show for it.
MAX_SECONDS = seconds("DOMESTIQUE_MAX_UTTERANCE_SECONDS", "120", 1.0)

# Quiet after the last tap before the count is taken as final. Below roughly
# this a deliberate double tap reads as two separate single taps.
REPLAY_QUIET = 0.4

# Cosmetic only. The classifier decides whether an utterance changes topic; this
# just keeps the words that asked for it out of the session name, so a false
# match here costs nothing but a slightly longer title.
TOPIC_PREFIX = re.compile(
    r"^\s*(?:new|next) (?:topic|session|chat|conversation)[\s,.:;-]*", re.I
)


def device() -> int | str | None:
    if not INPUT_DEVICE:
        return None
    return int(INPUT_DEVICE) if INPUT_DEVICE.isdigit() else INPUT_DEVICE


def publish(text: str, suffix: str = "") -> None:
    """Hand one transcript to the extension, named so they stay in order."""
    name = f"{int(time.time() * 1000):013d}"
    tmp = HEARD / f"{name}.tmp"
    tmp.write_text(f"{text}\n")
    # The extension globs *.txt, so the rename is what publishes the utterance
    # and it never reads a half-written file.
    tmp.rename(HEARD / f"{name}{suffix}.txt")


def say(text: str) -> None:
    """Speak something the rider needs now, ahead of anything pi has queued."""
    tmp = ROOT / "say.tmp"
    try:
        tmp.write_text(f"{text}\n")
        tmp.rename(SAY)
    except OSError as exc:
        log(f"could not say {text!r}: {exc}")


def note(text: str) -> None:
    """Append one thought, before anything has decided what it was.

    Unconditional on purpose. This runs ahead of the classifier so that every
    way the classifier can fail, including not answering at all, still leaves
    the thought written down.
    """
    try:
        NOTES.parent.mkdir(parents=True, exist_ok=True)
        with NOTES.open("a") as handle:
            handle.write(f"- {text}\n")
    except OSError as exc:
        log(f"could not write {NOTES}: {exc}")


def classify(text: str) -> str:
    """Sort an out-of-band utterance into note or new_topic.

    A one-shot pi with no tools and no session, so it can act on nothing and
    the provider credential stays with the wrapper rather than reaching here.
    Every failure returns note, which is the verdict that cannot destroy
    anything.
    """
    if not (CLASSIFY_MODEL and CLASSIFY_PROMPT):
        return "note"
    try:
        prompt = Path(CLASSIFY_PROMPT).read_text()
        done = subprocess.run(
            [
                "pi",
                "--print",
                "--no-session",
                "--no-tools",
                "--thinking",
                "off",
                "--model",
                CLASSIFY_MODEL,
                "--system-prompt",
                prompt,
                text,
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=CLASSIFY_TIMEOUT,
        )
    except Exception as exc:
        log(f"classifier unavailable, treating as a note: {exc}")
        return "note"

    lines = [line.strip() for line in done.stdout.splitlines() if line.strip()]
    verdict = lines[-1].lower() if lines else ""
    # Exact match only. A model that answers with a sentence has not answered,
    # and the safe reading of an unrecognized reply is the default one.
    return "new_topic" if verdict == "new_topic" else "note"


def main() -> int:
    import mlx.core as mx
    import numpy as np
    import sounddevice as sd
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel

    HEARD.mkdir(parents=True, exist_ok=True)

    # A ride ends by SIGTERMing its watchers (dev/domestique.nix). Python's
    # default disposition tears the process down without unwinding, leaving the
    # input stream open and a pid on disk that a later ride reads as live.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Two listeners on one key both record and both publish, so pi hears every
    # utterance twice and one topic change fires twice.
    if PIDFILE.exists():
        try:
            os.kill(int(PIDFILE.read_text().strip()), 0)
        except (OSError, ValueError):
            pass
        else:
            print(
                f"domestique-listen: already running as pid "
                f"{PIDFILE.read_text().strip()}",
                file=sys.stderr,
            )
            return 1
    PIDFILE.write_text(f"{os.getpid()}\n")
    READY.unlink(missing_ok=True)

    # A transcript stranded by an interrupted ride reaches the next ride's
    # first session, days late, and a stranded topic change restarts it there.
    for stale in [*HEARD.glob("*.txt"), *HEARD.glob("*.tmp")]:
        stale.unlink(missing_ok=True)
    # Taps held over from a previous ride would replay the moment this came up.
    REPLAY.unlink(missing_ok=True)
    REPLAY_REQUEST.unlink(missing_ok=True)

    started = time.monotonic()
    model = from_pretrained(MODEL)
    rate = model.preprocessor_config.sample_rate

    def transcribe(samples: np.ndarray) -> str:
        mel = get_logmel(mx.array(samples), model.preprocessor_config)
        return model.generate(mel)[0].text.strip()

    # First call builds the graph. Paying that here rather than on the first
    # thing the rider says keeps the opening question from arriving late.
    transcribe(np.zeros(rate // 2, dtype=np.float32))

    name = sd.query_devices(device(), "input")["name"]
    log(f"{MODEL} ready in {time.monotonic() - started:.1f}s, mic {name}")
    log(f"notes to {NOTES}, classifier {CLASSIFY_MODEL or 'off'}")

    READY.write_text("ready\n")

    blocks: list[np.ndarray] = []
    stream: sd.InputStream | None = None
    opened = 0.0
    channel = ""

    # Set while a topic change is announced and waiting to be carried out. The
    # replay key means cancel for as long as it is set, which is why the count
    # is drained in one place: the resolver never touches REPLAY itself.
    cancel_window = threading.Event()
    cancelled = threading.Event()
    resolving = threading.Lock()

    def flag(which: str) -> Path:
        return LISTENING if which == "agent" else OUTOFBAND

    def capture(indata, _frames, _time, status) -> None:
        if status:
            log(f"input {status}")
        blocks.append(indata.copy().reshape(-1))

    def start(which: str) -> None:
        nonlocal stream, opened, channel
        blocks.clear()
        stream = sd.InputStream(
            samplerate=rate,
            channels=1,
            dtype="float32",
            device=device(),
            callback=capture,
        )
        stream.start()
        opened = time.monotonic()
        channel = which

    def resolve(text: str) -> None:
        """Decide, off the poll loop, whether a note also changed the subject.

        Threaded because the classifier can take twenty seconds and the
        microphone has to stay answerable throughout. Nothing waits on the
        outcome: the note is already written.

        One at a time. Two of these would share one cancel window and one
        cancelled flag, so a tap meant for the first would clear the second;
        a thought spoken over a pending verdict stays the note it already is.
        """
        if not resolving.acquire(blocking=False):
            log(f"verdict already pending, kept as a note: {text[:40]}")
            return
        try:
            decide(text)
        finally:
            resolving.release()

    def decide(text: str) -> None:
        if classify(text) != "new_topic":
            return

        if CANCEL_SECONDS > 0:
            cancelled.clear()
            say("New topic. Tap to cancel.")
            # The window is the rider's to use, so it starts when the speech
            # watcher takes the announcement up rather than when it was queued.
            # That watcher holds it back while a key is down, which can be a
            # while, and a window spent in silence is not one.
            spoken = time.monotonic() + 5.0
            while SAY.exists() and time.monotonic() < spoken:
                time.sleep(0.05)
            cancel_window.set()
            deadline = time.monotonic() + CANCEL_SECONDS
            while time.monotonic() < deadline and not cancelled.is_set():
                time.sleep(0.05)
            cancel_window.clear()
            if cancelled.is_set():
                log(f"topic change cancelled: {text[:60]}")
                say("Cancelled.")
                return

        topic = TOPIC_PREFIX.sub("", text).strip()
        TOPIC.write_text(f"{topic}\n")
        RESTART.write_text("")
        # The extension is what can actually end the session, so the verdict
        # travels the same road an utterance does and keeps its place in line.
        publish(topic, ".newtopic")
        log(f"topic change: {topic[:60]}")

    def finish() -> None:
        nonlocal stream
        if stream is None:
            return
        stream.stop()
        stream.close()
        stream = None

        held = time.monotonic() - opened
        if held < MIN_SECONDS or not blocks:
            log(f"dropped, {held:.2f}s held")
            return

        audio = np.concatenate(blocks)
        begun = time.monotonic()
        text = transcribe(audio)
        elapsed = time.monotonic() - begun
        if not text:
            log(f"nothing heard in {len(audio) / rate:.1f}s")
            return
        log(f"{channel:9} {len(audio) / rate:5.1f}s heard in {elapsed:.2f}s  {text}")

        if channel == "agent":
            publish(text)
            return

        note(text)
        threading.Thread(target=resolve, args=(text,), daemon=True).start()

    def drain_replay() -> int:
        """Take the taps accumulated so far and reset the counter."""
        try:
            taps = REPLAY.stat().st_size
        except OSError:
            return 0
        if taps:
            REPLAY.unlink(missing_ok=True)
        return taps

    taps = 0
    last_tap = 0.0

    try:
        while True:
            try:
                arrived = drain_replay()
                if arrived:
                    if cancel_window.is_set():
                        cancelled.set()
                        arrived = 0
                    else:
                        taps += arrived
                        last_tap = time.monotonic()
                if taps and time.monotonic() - last_tap >= REPLAY_QUIET:
                    REPLAY_REQUEST.write_text(f"{taps}\n")
                    taps = 0

                if stream is None:
                    # Both files at once should not happen, the chord being one
                    # keycode rather than two. First one seen still wins, so a
                    # keyboard that disagrees cannot open two streams.
                    if LISTENING.exists():
                        start("agent")
                    elif OUTOFBAND.exists():
                        start("outofband")
                elif not flag(channel).exists():
                    finish()
                elif time.monotonic() - opened >= MAX_SECONDS:
                    log(f"cut at {MAX_SECONDS:.0f}s, key still down")
                    held = flag(channel)
                    finish()
                    # Waiting for the release keeps a stuck key from recording
                    # the same rider on a loop.
                    while held.exists():
                        time.sleep(POLL_SECONDS)
            except Exception as exc:
                # The cues and the window tint are rung by the speech watcher
                # off these files alone, so an exit here leaves every later key
                # press fully confirmed and silently unheard. A vanished
                # Bluetooth microphone is the case that reaches this.
                log(f"recovered: {exc}")
                if stream is not None:
                    try:
                        stream.stop()
                        stream.close()
                    except Exception:
                        pass
                    stream = None
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        return 0
    finally:
        if stream is not None:
            stream.stop()
            stream.close()
        PIDFILE.unlink(missing_ok=True)
        READY.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())

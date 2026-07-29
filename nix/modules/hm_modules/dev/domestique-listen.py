#!/usr/bin/env python3
"""Record while the push-to-talk key is held, transcribe, hand the text to pi.

The microphone is denied inside pi's strict sandbox for the same reason the
speaker is, so this runs beside the speech watcher rather than inside pi, and
the two halves meet in ~/.pi/domestique. Karabiner creates the listening file
on key down and removes it on key up (nix/modules/hm_modules/desktop/input/
karabiner.nix); everything between those two edges becomes one utterance.

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
import signal
import sys
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

# Written by Karabiner while the key is down. Its presence is the whole
# protocol; nothing writes into it.
LISTENING = ROOT / "listening"

# Finished transcripts, one file per utterance, drained by the pi extension.
HEARD = ROOT / "heard"

PIDFILE = ROOT / "listen.pid"
READY = ROOT / "listen.ready"

MODEL = env("DOMESTIQUE_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
INPUT_DEVICE = env("DOMESTIQUE_INPUT_DEVICE", "")
POLL_SECONDS = seconds("DOMESTIQUE_POLL_SECONDS", "0.1", 0.01)

# A tap while reaching for something else is not an utterance.
MIN_SECONDS = seconds("DOMESTIQUE_MIN_UTTERANCE_SECONDS", "0.4", 0.0)

# A key can stick, and a jersey pocket can hold one down. The recording is cut
# here and still transcribed, because the alternative is unbounded memory and
# nothing to show for it.
MAX_SECONDS = seconds("DOMESTIQUE_MAX_UTTERANCE_SECONDS", "120", 1.0)


def device() -> int | str | None:
    if not INPUT_DEVICE:
        return None
    return int(INPUT_DEVICE) if INPUT_DEVICE.isdigit() else INPUT_DEVICE


def publish(text: str) -> None:
    """Hand one transcript to the extension, named so they stay in order."""
    name = f"{int(time.time() * 1000):013d}"
    tmp = HEARD / f"{name}.tmp"
    tmp.write_text(f"{text}\n")
    # The extension globs *.txt, so the rename is what publishes the utterance
    # and it never reads a half-written file.
    tmp.rename(HEARD / f"{name}.txt")


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
    # utterance twice and a spoken "new topic" fires twice.
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
    # first session, days late, and a stranded "new topic" restarts it there.
    for stale in [*HEARD.glob("*.txt"), *HEARD.glob("*.tmp")]:
        stale.unlink(missing_ok=True)

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

    READY.write_text("ready\n")

    blocks: list[np.ndarray] = []
    stream: sd.InputStream | None = None
    opened = 0.0

    def capture(indata, _frames, _time, status) -> None:
        if status:
            log(f"input {status}")
        blocks.append(indata.copy().reshape(-1))

    def start() -> None:
        nonlocal stream, opened
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
        publish(text)
        log(f"{len(audio) / rate:5.1f}s heard in {elapsed:.2f}s  {text}")

    try:
        while True:
            try:
                if stream is None:
                    if LISTENING.exists():
                        start()
                elif not LISTENING.exists():
                    finish()
                elif time.monotonic() - opened >= MAX_SECONDS:
                    log(f"cut at {MAX_SECONDS:.0f}s, key still down")
                    finish()
                    # Waiting for the release keeps a stuck key from recording
                    # the same rider on a loop.
                    while LISTENING.exists():
                        time.sleep(POLL_SECONDS)
            except Exception as exc:
                # The cues and the window tint are rung by the speech watcher
                # off the listening file alone, so an exit here leaves every
                # later key press fully confirmed and silently unheard. A
                # vanished Bluetooth microphone is the case that reaches this.
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

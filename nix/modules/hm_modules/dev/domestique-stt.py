#!/usr/bin/env python3
"""Transcribe audio files with Parakeet, reporting what it heard and how fast.

The bench half of recognition: it proves the weights load and shows which of
our nouns survive, without a microphone or the ride loop. Every term it mangles
is one the downstream corrector has to know about.

    domestique-transcribe ~/ride.wav
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

MODEL = os.environ.get("DOMESTIQUE_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")


def main() -> int:
    paths = [Path(a) for a in sys.argv[1:]]
    if not paths:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    missing = [p for p in paths if not p.is_file()]
    for path in missing:
        print(f"domestique-transcribe: {path}: no such file", file=sys.stderr)
    if missing:
        return 1

    from parakeet_mlx import from_pretrained

    started = time.monotonic()
    model = from_pretrained(MODEL)
    print(f"{MODEL} loaded in {time.monotonic() - started:.2f}s", file=sys.stderr)

    for path in paths:
        started = time.monotonic()
        result = model.transcribe(path)
        elapsed = time.monotonic() - started
        # Speech duration over inference time. A ride needs this comfortably
        # above 1, or the recognizer falls behind the rider.
        spoken = result.sentences[-1].end if result.sentences else 0.0
        ratio = f"{spoken / elapsed:.0f}x" if elapsed > 0 else "n/a"
        print(f"{path.name}  {elapsed:.2f}s  {ratio:>5}  {result.text.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

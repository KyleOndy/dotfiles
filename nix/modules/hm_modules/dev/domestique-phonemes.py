#!/usr/bin/env python3
"""Show what grapheme-to-phoneme makes of a term, with and without the lexicon.

Most technical vocabulary needs no lexicon entry: the default dictionary already
says nginx as "engine X" and reads ZFS and vmagent as initialisms. Its actual
failures are acronyms it spells out letter by letter. Checking first is how a
lexicon stays short enough to trust.

A term is reported as the watcher normalizes it, so a backticked span or a
dotted name is shown under the words it becomes.

    domestique-phonemes SIGTERM kubectl 'the pod ignored SIGTERM'
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

# The watcher's own module, so this reports what the rider hears rather than
# what was typed. Nix gives each script its own store path, so the location
# arrives in the environment; the sibling is the checkout's copy.
TTS = os.environ.get(
    "DOMESTIQUE_TTS", str(Path(__file__).with_name("domestique-tts.py"))
)


def load_tts():
    spec = importlib.util.spec_from_file_location("domestique_tts", TTS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    terms = sys.argv[1:]
    if not terms:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    tts = load_tts()
    tts.wire_espeak()

    from misaki import en, espeak

    def build():
        return en.G2P(
            trf=False, british=False, fallback=espeak.EspeakFallback(british=False)
        )

    bare = build()
    tuned = build()
    tts.install_lexicon(tuned, tts.load_lexicon())

    spoken = [tts.speakable(t) for t in terms]
    labels = [t if s == t else f"{t} -> {s}" for t, s in zip(terms, spoken)]

    width = max(len(label) for label in labels)
    print(f"{'term'.ljust(width)}  {'default':38}  configured")
    print(f"{'-' * width}  {'-' * 38}  {'-' * 38}")
    for label, text in zip(labels, spoken):
        before = bare(text)[0]
        after = tuned(text)[0]
        mark = "" if before == after else "  <- lexicon"
        print(f"{label.ljust(width)}  {before:38}  {after:38}{mark}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Show what grapheme-to-phoneme makes of a term, with and without the lexicon.

Most technical vocabulary needs no lexicon entry: the default dictionary already
says nginx as "engine X" and reads ZFS and vmagent as initialisms. Its actual
failures are acronyms it spells out letter by letter. Checking first is how a
lexicon stays short enough to trust.

    domestique-phonemes SIGTERM kubectl 'the pod ignored SIGTERM'
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ESPEAK = os.environ.get("DOMESTIQUE_ESPEAK", "")
LEXICON_PATH = os.environ.get("DOMESTIQUE_LEXICON", "")


def main() -> int:
    terms = sys.argv[1:]
    if not terms:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    if ESPEAK:
        # The espeakng-loader wheel bakes its build machine's data path into the
        # dylib it ships, so its getters have to be replaced before
        # misaki.espeak reads them.
        import espeakng_loader

        espeakng_loader.get_library_path = lambda: f"{ESPEAK}/lib/libespeak-ng.dylib"
        espeakng_loader.get_data_path = lambda: f"{ESPEAK}/share/espeak-ng-data"

    from misaki import en, espeak

    def build():
        return en.G2P(
            trf=False, british=False, fallback=espeak.EspeakFallback(british=False)
        )

    bare = build()
    tuned = build()

    lexicon = {}
    if LEXICON_PATH and Path(LEXICON_PATH).is_file():
        lexicon = json.loads(Path(LEXICON_PATH).read_text())
    for term, phonemes in lexicon.items():
        tuned.lexicon.golds[term] = phonemes
        tuned.lexicon.golds[term.lower()] = phonemes

    width = max(len(t) for t in terms)
    print(f"{'term'.ljust(width)}  {'default':38}  configured")
    print(f"{'-' * width}  {'-' * 38}  {'-' * 38}")
    for term in terms:
        before = bare(term)[0]
        after = tuned(term)[0]
        mark = "" if before == after else "  <- lexicon"
        print(f"{term.ljust(width)}  {before:38}  {after:38}{mark}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

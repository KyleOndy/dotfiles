#!/usr/bin/env python3
"""Record trainer takes and score raw transcripts against spectrally gated ones.

    domestique-mic-bench record DIR [--device NAME] [--noise-seconds 30] [--take-seconds 6]
    domestique-mic-bench compare DIR [DIR ...] [--strengths 0.5,0.8,1.0]

One DIR per setup (placement, MVX2U denoiser on or off). compare also writes
each gated take under DIR/gate-<strength>/ for listening.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

MODEL = os.environ.get("DOMESTIQUE_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")

# Parakeet's preprocessor rate. compare checks it against the loaded model.
RATE = 16000

# No digits: Parakeet writes "three" as "3" often enough to score a correct
# take as wrong.
PHRASES = [
    "What changed in the dotfiles repo since yesterday?",
    "Deploy tiger after the flake update finishes.",
    "Summarize the latest commits on main.",
    "New topic. Why did the UPS alert fire on tiger last night?",
    "Open a Linear ticket to raise the Loki quota.",
    "Read me the bird detections from cogsworth this morning.",
    "Check whether pika finished its backup overnight.",
    "Remind me to measure the bar diameter with a paper strip.",
    "Is the alamode session still waiting on my approval?",
    "Play that answer again, slower this time.",
]

# STFT at 16 kHz: 32 ms windows, 8 ms hop.
N_FFT = 512
HOP = 128


def record(args: argparse.Namespace) -> int:
    import numpy as np
    import sounddevice as sd
    from scipy.io import wavfile

    out = Path(args.dir).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    device = int(args.device) if args.device.isdigit() else (args.device or None)
    print(f"mic: {sd.query_devices(device, 'input')['name']}")

    def take(name: str, seconds: float, prompt: str) -> None:
        print(f"\n{prompt}")
        for n in (3, 2, 1):
            print(f"  {n}...", flush=True)
            time.sleep(1)
        print("  recording", flush=True)
        audio = sd.rec(
            int(seconds * RATE),
            samplerate=RATE,
            channels=1,
            dtype="float32",
            device=device,
        )
        sd.wait()
        audio = audio.reshape(-1)
        wavfile.write(out / name, RATE, audio)
        peak = 20 * np.log10(max(float(np.abs(audio).max()), 1e-9))
        # Wind on the capsule shows up here first: gating cannot undo a clip.
        warn = "  CLIPPED, lower the gain or move out of the air" if peak > -1 else ""
        print(f"  {name}: peak {peak:.1f} dBFS{warn}")

    take(
        "noise.wav",
        args.noise_seconds,
        f"Noise: fan at riding speed, keep pedaling, say nothing ({args.noise_seconds:.0f} s).",
    )
    for i, phrase in enumerate(PHRASES, 1):
        take(f"take-{i:02d}.wav", args.take_seconds, f"Say: {phrase}")
    print(f"\ndone: {out}")
    return 0


def load(path: Path):
    import numpy as np
    from scipy.io import wavfile

    rate, audio = wavfile.read(path)
    if rate != RATE:
        sys.exit(f"mic-bench: {path} is {rate} Hz, expected {RATE}")
    if audio.dtype == np.int16:
        audio = audio / 32768.0
    return audio.astype(np.float32).reshape(-1)


def threshold(noise):
    """Per-frequency gate in dB: the noise's mean plus 1.5 standard deviations.

    The same statistic as noisereduce's stationary mode (n_std_thresh 1.5).
    """
    import librosa
    import numpy as np

    db = librosa.amplitude_to_db(
        np.abs(librosa.stft(noise, n_fft=N_FFT, hop_length=HOP)), top_db=None
    )
    return db.mean(axis=1) + 1.5 * db.std(axis=1)


def gate(audio, limit, strength: float):
    """Attenuate every bin under limit by strength (1.0 removes it outright)."""
    import librosa
    import numpy as np
    from scipy.ndimage import uniform_filter

    spec = librosa.stft(audio, n_fft=N_FFT, hop_length=HOP)
    db = librosa.amplitude_to_db(np.abs(spec), top_db=None)
    keep = (db > limit[:, None]).astype(np.float32)
    # 500 Hz by 50 ms, noisereduce's default smoothing. An unsmoothed mask
    # flickers bin by bin, and that flicker is the "musical noise" artifact.
    bins = max(1, round(500 / (RATE / N_FFT)))
    frames = max(1, round(0.05 * RATE / HOP))
    keep = uniform_filter(keep, size=(bins, frames))
    gain = 1 - strength * (1 - keep)
    return librosa.istft(spec * gain, hop_length=HOP, length=len(audio)).astype(
        np.float32
    )


def words(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower()).split()


def errors(ref: str, hyp: str) -> tuple[int, int]:
    """Word-level edit distance from ref to hyp, and ref's word count."""
    r, h = words(ref), words(hyp)
    row = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        diag, row[0] = row[0], i
        for j, hw in enumerate(h, 1):
            diag, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, diag + (rw != hw))
    return row[-1], len(r)


def compare(args: argparse.Namespace) -> int:
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel
    from scipy.io import wavfile

    model = from_pretrained(MODEL)
    if model.preprocessor_config.sample_rate != RATE:
        sys.exit(f"mic-bench: {MODEL} wants {model.preprocessor_config.sample_rate} Hz")

    def transcribe(audio) -> str:
        mel = get_logmel(mx.array(audio), model.preprocessor_config)
        return model.generate(mel)[0].text.strip()

    strengths = [float(s) for s in args.strengths.split(",")]
    results: list[tuple[str, str, int, int]] = []
    for d in (Path(p).expanduser() for p in args.dirs):
        takes = sorted(d.glob("take-*.wav"))
        if not takes or not (d / "noise.wav").is_file():
            print(f"mic-bench: {d}: needs noise.wav and take-NN.wav", file=sys.stderr)
            continue
        limit = threshold(load(d / "noise.wav"))

        for strength in [None, *strengths]:
            label = "raw" if strength is None else f"gate {strength:g}"
            if strength is not None:
                (d / f"gate-{strength:g}").mkdir(exist_ok=True)
            wrong = total = 0
            for path in takes:
                ref = PHRASES[int(path.stem.split("-")[1]) - 1]
                audio = load(path)
                if strength is not None:
                    audio = gate(audio, limit, strength)
                    wavfile.write(d / f"gate-{strength:g}" / path.name, RATE, audio)
                hyp = transcribe(audio)
                e, n = errors(ref, hyp)
                wrong, total = wrong + e, total + n
                if e:
                    print(f"{d.name:>16}  {label:<9} {path.stem}  {e} off: {hyp}")
            results.append((d.name, label, wrong, total))

    print(f"\n{'setup':>16}  {'variant':<9} {'WER':>6}  errors")
    for name, label, wrong, total in results:
        print(f"{name:>16}  {label:<9} {100 * wrong / total:5.1f}%  {wrong}/{total}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    rec = sub.add_parser("record", help="record noise.wav and one take per phrase")
    rec.add_argument("dir")
    rec.add_argument(
        "--device",
        default=os.environ.get("DOMESTIQUE_INPUT_DEVICE", ""),
        help="sounddevice name or index, by default the one domestique-listen opens",
    )
    rec.add_argument("--noise-seconds", type=float, default=30)
    rec.add_argument("--take-seconds", type=float, default=6)
    rec.set_defaults(run=record)

    cmp = sub.add_parser("compare", help="score raw and gated transcripts")
    cmp.add_argument("dirs", nargs="+")
    cmp.add_argument("--strengths", default="0.5,0.8,1.0")
    cmp.set_defaults(run=compare)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())

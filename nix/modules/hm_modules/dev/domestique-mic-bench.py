#!/usr/bin/env python3
"""Record trainer takes and score raw transcripts against spectrally gated ones.

    domestique-mic-bench record DIR [--device NAME] [--noise-seconds 30] [--take-seconds 6]
    domestique-mic-bench compare DIR [DIR ...] [--strengths 0.5,0.8,1.0]
    domestique-mic-bench tune [--thorough] [--dir DIR] [--gain DB] [--device NAME]
    domestique-mic-bench tune --rescore DIR

One DIR per setup (placement, MVX2U denoiser on or off). compare also writes
each gated take under DIR/gate-<strength>/ for listening.

tune sets the MVX2U through shurectl, so it runs where shurectl is installed.
It keeps the winner in shurectl's preset slot 4.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import subprocess
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

# A short tune reads the first 15, a thorough one all 30.
TUNE_PHRASES = PHRASES + [
    "Did the nightly backup on tiger finish without errors?",
    "Show me the open pull requests that need a review.",
    "Pause that for now and pick it up after the ride.",
    "Which tests failed in the last build?",
    "Restart the Jellyfin service and tell me when it is back.",
    "How much disk space is left on the storage pool?",
    "Add a note that the left pedal clicked on the climb.",
    "What did we decide about the camera mount yesterday?",
    "Skip the details and give me the short version.",
    "Merge the branch if the checks have passed.",
    "Send me a reminder to order more chain lube.",
    "Were there any alerts while I was riding?",
    "Open the dashboard for the media server.",
    "Cancel the last request, I asked the wrong question.",
    "Explain why the build took longer than usual.",
    "Write that down as a task for this weekend.",
    "Is the weather clear enough to ride outside later?",
    "Stop reading and wait for my next question.",
    "Compare the two options and pick the safer one.",
    "Tell me what changed since the last time I asked.",
]

# shurectl preset fields (src/presets.rs in shurectl 2.14.2). Every candidate
# starts from the riding setup in docs/domestique-microphone.md and changes one
# thing. A field left out keeps the device's value.
BASELINE = {
    "mode": '"manual"',
    "phantom_power": "true",
    "limiter_enabled": "true",
    "compressor": '"off"',
    "hpf": '"off"',
    "denoiser_enabled": "true",
    "popper_stopper_enabled": "false",
    # A Monitor Mix of the other kind is skipped on load, and a Playback Level
    # of 0 means not saved, so the headphone mix stays as it is.
    "monitor_mix": "0",
    "monitor_mix_is_mic_level": "false",
    "playback_mix": "0",
}
# EQ gains in tenths of a dB at 100 Hz, 250 Hz, 1 kHz, 4 kHz and 10 kHz.
FLAT = (0, 0, 0, 0, 0)
CANDIDATES = {
    "baseline": ({}, FLAT),
    "denoiser-off": ({"denoiser_enabled": "false"}, FLAT),
    "presence-eq": ({}, (-40, -40, 0, 40, 0)),
    "compressor-light": ({"compressor": '"light"'}, FLAT),
    "compressor-medium": ({"compressor": '"medium"'}, FLAT),
    # The Gen 2 has no EQ or dynamics in Auto Level, so those stay unwritten.
    "auto-level": (
        {"mode": '"auto"', "tone": "0", "limiter_enabled": None, "compressor": None},
        None,
    ),
}
SHORT = ["baseline", "denoiser-off", "presence-eq"]

# Speech peaks the gain check aims for, and how far off it may land.
TARGET_DBFS = -12.0
TARGET_SLACK_DB = 3.0

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
        print(f"\n{prompt}", flush=True)
        count_in(1.0)
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


def count_in(gap: float) -> None:
    """Three dings gap seconds apart on the default output, the last one higher.

    Speech starts on the high one. Returns once it has played, so the
    recording that follows never hears it.
    """
    import numpy as np
    import sounddevice as sd

    rate = 48000
    t = np.arange(int(0.12 * rate)) / rate
    decay = np.exp(-30 * t)
    rest = np.zeros(int((gap - 0.12) * rate))
    buf = np.concatenate(
        [np.sin(2 * np.pi * 880 * t) * decay, rest] * 2
        + [np.sin(2 * np.pi * 1320 * t) * decay]
    )
    sd.play((0.3 * buf).astype(np.float32), rate)
    sd.wait()


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


def preset_toml(name: str, gain_db: float) -> str:
    fields, eq = CANDIDATES[name]
    merged = {**BASELINE, **fields}
    lines = [f'name = "{name}"', f"gain_db = {gain_db:.1f}"]
    lines += [f"{k} = {v}" for k, v in merged.items() if v is not None]
    if eq is not None:
        lines += [f"\n[[eq_bands]]\ngain_db = {g}" for g in eq]
    return "\n".join(lines) + "\n"


def shurectl_load(home: Path, name: str, gain_db: float) -> None:
    """Load a candidate onto the device through shurectl's preset slot 4.

    shurectl keeps presets under $HOME, so a scratch HOME holds the candidates
    and the rider's own slots stay untouched.
    """
    presets = home / "Library" / "Application Support" / "shurectl" / "presets"
    presets.mkdir(parents=True, exist_ok=True)
    (presets / "preset_4.toml").write_text(preset_toml(name, gain_db))
    done = subprocess.run(
        ["shurectl", "--preset", "4"],
        env={**os.environ, "HOME": str(home)},
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        sys.exit(f"mic-bench: shurectl --preset 4 ({name}): {done.stderr.strip()}")


def seconds_for(phrase: str) -> float:
    return 1.5 + 0.45 * len(phrase.split())


def tokenize(model, text: str) -> list[int]:
    """SentencePiece BPE, replayed from vocabulary order.

    The converted model ships its vocabulary but no tokenizer. Lower ids were
    merged earlier, so merging the lowest-id pair first rebuilds the split the
    model was trained on; it matched the model's own split on every transcript
    of the 2026-10-29 bench. Any other split of the same text scores far worse.
    """
    piece_id = {p: i for i, p in enumerate(model.vocabulary)}
    ids = []
    for word in text.split():
        parts = list("▁" + word)
        while True:
            best = None
            for i in range(len(parts) - 1):
                merged = piece_id.get(parts[i] + parts[i + 1])
                if merged is not None and (best is None or merged < best[0]):
                    best = (merged, i)
            if best is None:
                break
            i = best[1]
            parts[i : i + 2] = [parts[i] + parts[i + 1]]
        ids += [piece_id[p] for p in parts]
    return ids


def script_loss(model, audio, text: str) -> float:
    """Negative log-likelihood of text given audio, in nats per token.

    The TDT transducer's own training loss: every alignment of the script's
    tokens to the encoder frames, summed. Unlike word error rate, it moves
    when the model gets every word right but less surely.
    """
    import mlx.core as mx
    import numpy as np
    from parakeet_mlx.audio import get_logmel

    y = tokenize(model, text)
    U, V, durations = len(y), len(model.vocabulary), list(model.durations)
    mel = get_logmel(mx.array(audio), model.preprocessor_config)
    features, _ = model.encoder(mel if mel.ndim == 3 else mx.expand_dims(mel, 0))
    out, state = model.decoder(None, None)
    outs = [out]
    # One token per call: the prediction network's LSTM takes its batch and
    # time axes the wrong way round for a longer sequence.
    for token in y:
        out, state = model.decoder(mx.array([[token]]), state)
        outs.append(out)
    joint = model.joint(features, mx.concatenate(outs, axis=1).astype(features.dtype))
    joint = joint.astype(mx.float32)[0]
    tokens = joint[..., : V + 1]
    tokens = tokens - mx.logsumexp(tokens, axis=-1, keepdims=True)
    dur = joint[..., V + 1 :]
    dur = np.array(dur - mx.logsumexp(dur, axis=-1, keepdims=True))
    blank = np.array(tokens[..., V])
    index = mx.array(y)[None, :, None]
    emit = np.array(mx.take_along_axis(tokens[:, :U, :], index, axis=-1)[..., 0])

    T = blank.shape[0]
    alpha = np.full((T + 1, U + 1), -np.inf)
    alpha[0, 0] = 0.0
    end = -np.inf
    for t in range(T):
        for u in range(U + 1):
            a = alpha[t, u]
            if a == -np.inf:
                continue
            for k, d in enumerate(durations):
                if u < U:
                    nt = min(t + d, T)
                    alpha[nt, u + 1] = np.logaddexp(
                        alpha[nt, u + 1], a + emit[t, u] + dur[t, u, k]
                    )
                if d == 0:
                    continue
                step = a + blank[t, u] + dur[t, u, k]
                if t + d >= T:
                    if u == U:
                        end = np.logaddexp(end, step)
                else:
                    alpha[t + d, u] = np.logaddexp(alpha[t + d, u], step)
    return -float(np.logaddexp(end, alpha[T, U])) / U


def tune(args: argparse.Namespace) -> int:
    if args.rescore:
        return score_tune(Path(args.rescore).expanduser(), apply=False)
    if shutil.which("shurectl") is None:
        sys.exit("mic-bench: tune needs shurectl on PATH")

    import numpy as np
    import sounddevice as sd
    from scipy.io import wavfile

    names = list(CANDIDATES) if args.thorough else SHORT
    phrases = TUNE_PHRASES[: 30 if args.thorough else 15]
    stamp = time.strftime("%Y%m%d-%H%M")
    out = Path(args.dir or f"~/mic-bench/tune-{stamp}").expanduser()
    out.mkdir(parents=True, exist_ok=True)
    home = out / "shurectl-home"
    device = int(args.device) if args.device.isdigit() else (args.device or None)
    print(f"mic: {sd.query_devices(device, 'input')['name']}")

    def take(path: Path, phrase: str, cue: str) -> float:
        print(f"\n{cue}  {phrase}", flush=True)
        # Also the settling time after shurectl switches the setup.
        count_in(0.4)
        print("  now", flush=True)
        audio = sd.rec(
            int(seconds_for(phrase) * RATE),
            samplerate=RATE,
            channels=1,
            dtype="float32",
            device=device,
        )
        sd.wait()
        audio = audio.reshape(-1)
        path.parent.mkdir(parents=True, exist_ok=True)
        wavfile.write(path, RATE, audio)
        return 20 * np.log10(max(float(np.abs(audio).max()), 1e-9))

    gain = args.gain
    print("\nGain check: fan at riding speed, read each line as it appears.")
    for attempt in range(1, 4):
        shurectl_load(home, "baseline", gain)
        peak = max(
            take(out / "gain" / f"{attempt}-{i}.wav", p, "gain")
            for i, p in enumerate(PHRASES[:2])
        )
        print(f"  gain {gain:.1f} dB: peak {peak:.1f} dBFS")
        if abs(peak - TARGET_DBFS) <= TARGET_SLACK_DB:
            break
        gain = min(60.0, max(0.0, round(2 * (gain + TARGET_DBFS - peak)) / 2))
    (out / "gain.txt").write_text(f"{gain}\n")

    total = len(phrases) * len(names)
    minutes = sum(seconds_for(p) + 2 for p in phrases) * len(names) / 60
    print(
        f"\n{len(names)} setups x {len(phrases)} phrases, about {minutes:.0f} minutes."
        " Each phrase repeats once per setup; Ctrl-C stops and scores what is done."
    )
    n = 0
    try:
        for k, phrase in enumerate(phrases, 1):
            # Shuffled within each phrase: every setup hears the same line, and
            # none always goes first or last.
            for name in random.sample(names, len(names)):
                n += 1
                shurectl_load(home, name, gain)
                take(out / name / f"phrase-{k:02d}.wav", phrase, f"[{n}/{total}]")
    except KeyboardInterrupt:
        print("\nstopped, scoring the phrases every setup heard")
    return score_tune(out, apply=True)


def score_tune(out: Path, apply: bool) -> int:
    import mlx.core as mx
    import numpy as np
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel

    names = [n for n in CANDIDATES if (out / n).is_dir()]
    if "baseline" not in names:
        sys.exit(f"mic-bench: {out} has no baseline takes")
    heard = [{p.stem for p in (out / n).glob("phrase-*.wav")} for n in names]
    stems = sorted(set.intersection(*heard))
    if len(stems) < 2:
        sys.exit(f"mic-bench: {out}: fewer than two phrases every setup heard")

    model = from_pretrained(MODEL)
    losses: dict[str, np.ndarray] = {}
    wrong: dict[str, tuple[int, int]] = {}
    for name in names:
        row, e_sum, n_sum = [], 0, 0
        for stem in stems:
            audio = load(out / name / f"{stem}.wav")
            ref = TUNE_PHRASES[int(stem.split("-")[1]) - 1]
            row.append(script_loss(model, audio, ref))
            mel = get_logmel(mx.array(audio), model.preprocessor_config)
            e, n = errors(ref, model.generate(mel)[0].text)
            e_sum, n_sum = e_sum + e, n_sum + n
        losses[name] = np.array(row)
        wrong[name] = (e_sum, n_sum)

    # A setup wins only by beating the baseline phrase for phrase by more than
    # two standard errors of those differences; anything less is reading noise.
    print(f"\n{len(stems)} phrases per setup. Loss is nats per token, lower is better.")
    print(f"{'setup':>18}  {'loss':>6}  {'vs baseline':>15}  {'t':>5}  errors")
    winner, best = "baseline", float(losses["baseline"].mean())
    for name in names:
        e, n = wrong[name]
        line = f"{name:>18}  {losses[name].mean():6.3f}"
        if name == "baseline":
            print(f"{line}  {'':>15}  {'':>5}  {e}/{n}")
            continue
        diff = losses[name] - losses["baseline"]
        se = float(diff.std(ddof=1) / np.sqrt(len(diff)))
        t = float(diff.mean()) / se if se else 0.0
        print(f"{line}  {diff.mean():+7.3f} +/- {se:.3f}  {t:+5.1f}  {e}/{n}")
        if t < -2 and losses[name].mean() < best:
            winner, best = name, float(losses[name].mean())

    gain = float((out / "gain.txt").read_text())
    print(f"\nwinner: {winner} at {gain:.1f} dB")
    if apply:
        shurectl_load(Path.home(), winner, gain)
        print("loaded onto the MVX2U and kept as shurectl preset 4")
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

    tun = sub.add_parser(
        "tune", help="read phrases while shurectl switches setups, keep the best"
    )
    tun.add_argument("--thorough", action="store_true", help="6 setups x 30 phrases")
    tun.add_argument(
        "--dir", help="session directory, by default ~/mic-bench/tune-<time>"
    )
    tun.add_argument("--gain", type=float, default=42.0, help="first gain to try, dB")
    tun.add_argument(
        "--device",
        default=os.environ.get("DOMESTIQUE_INPUT_DEVICE", ""),
        help="sounddevice name or index, by default the one domestique-listen opens",
    )
    tun.add_argument(
        "--rescore", metavar="DIR", help="score a session without recording"
    )
    tun.set_defaults(run=tune)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())

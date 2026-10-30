# domestique microphone

Opening the AirPods' microphone moves them from A2DP to HFP, which drops
playback to call quality and loses noise cancelling for as long as it stays
open. `inputDevice` already pins another microphone, but the MacBook Air's own
sits on the wall, too far away to hear the rider over the fan. So we put a
dedicated microphone on the trainer desk.

## The chain

Senal MC24-EL in its Auray DUSM-1 shockmount, on a 3/8" double-male stud, on a
Manfrotto 244N Magic Arm, in a 035RL Super Clamp on the RAD desk. A 6' XLR
runs to a Shure MVX2U Gen 2, which plugs into one of the UGREEN Revodok Pro's
USB-C data ports.

- **Shotgun, not lav**: nothing clipped on to forget and yank, and the mic can
  sit out of the fan's air. A body-worn mic sits right in it.
- **Shotgun, not dynamic**: an SM7B-style mic only rejects the room within
  5-10 cm of the mouth. From the desk it would hear the fan like anything else.
- **The MC24-EL**: hypercardioid, 48V phantom or one AA, 180 Hz high-pass
  switch. The high-pass takes most of the fan's rumble for free.
- **MVX2U Gen 2, not the Rode AI-1**: 60 dB of gain against about 45, and it is
  still sold. It draws phantom power from USB, 160 mA by one retailer's figure,
  well inside a USB 3 port's 900 mA.
- **Stud, not cold shoe**: the DUSM-1's shoe foot has a 3/8"-16 female thread
  in it, and so does one end of the 244N. A double-male stud joins them with
  nothing to wobble, and the arm's ball joint sets the aim, so where the thread
  stops turning does not matter. A cold shoe (SHAPE HSF, 1/4"-20 male) on the
  arm's 1/4" end also works, for three times the price and some play.

## Setup

1. Pull the AA out of the Senal and leave the high-pass on.
2. Clamp the 244N's 1/4" end in the Super Clamp, so the 3/8" end takes the
   stud. A camera's 1/4" tripod screw tells the ends apart: it bites in the
   1/4" end and spins loose in the 3/8".
3. Aim at the mouth in the Zone 2 position, out of the fan's air. At 50 cm
   (20") speech sits 12-14 dB above the fan. Put the fan 110-130 degrees off
   the mic's axis, where hypercardioid rejection is deepest. Straight behind is
   worse: hypercardioids have a rear lobe.
4. Plug the MVX2U into a 10 Gbps USB-C data port on the dock.
5. Set it up in [MOTIV Mix](https://www.shure.com/en-us/products/software/motiv-mix),
   Shure's desktop app. Nothing packages it: nixpkgs has no Shure app, and
   Homebrew's `shureplus-motiv` is MOTIV Desktop, the first MVX2U's app. The
   interface keeps its settings, so the app only runs to change one.
   - **Phantom Power**: on.
   - **Manual**, not Auto-level, with Mic Gain set so speech peaks around
     -12 dBFS.
   - **Real-time Denoiser** and **Limiter**: on.
   - **Compressor**, **Popper Stopper** and **High Pass Filter**: off, EQ flat.
6. sounddevice calls it `Shure MVX2U GEN 2`. `MOTIV Mix Virtual` is the app's
   mixed output, not the mic.
   `~/.local/state/domestique/venv/bin/python -I -m sounddevice` lists them.

## Bench

```sh
# MOTIV Mix: denoiser off
domestique-mic-bench record ~/mic-bench/senal-50cm --device "Shure MVX2U GEN 2"
# MOTIV Mix: denoiser on
domestique-mic-bench record ~/mic-bench/senal-50cm-denoiser --device "Shure MVX2U GEN 2"
domestique-mic-bench compare ~/mic-bench/*/
```

Turn the Limiter off for a bench. It holds peaks under full scale, so too much
gain comes through squashed and never shows as `CLIPPED`. Leave the Compressor
off too: it turns the fan up between words, so the noise under speech stops
matching the noise take the gate profiles.

`record` takes 30 s of noise first: fan at riding speed, keep pedaling, say
nothing. Then ten phrases, 6 s each, after a 3-2-1 count. It prints each
take's peak. Set the gain so speech peaks around -12 dBFS. `CLIPPED` means
wind or too much gain, and no gate undoes a clip.

`compare` transcribes every take raw and gated at 0.5, 0.8 and 1.0, prints
each miss, then a word error rate per setup and variant. Gated takes land in
`DIR/gate-<strength>/` for listening.

Reading it:

- **Vocabulary**: dotfiles comes back as "dot files" and alamode as "a la mode"
  or "all-remote", 4-5 words in every variant. That is not noise, so compare
  variants rather than absolute WER.
- **Synthetic run**: `say` speech over synthetic fan noise. At 0 dB SNR, raw
  scored 16.5%, gate 0.5 and 0.8 14.1%, gate 1.0 20.0%. At 5 dB: 11.8%,
  8.2%, 8.2%, 9.4%. Full removal hurt at the worse SNR, which matches
  Iwamoto et al. A real room will differ.
- **Decision**: the gate goes into domestique-listen only if it beats raw by
  more than a couple of words out of 85. If the MVX2U's denoiser wins, leave it
  on and write nothing.

## Result

Benched 2026-10-29 at 50 cm. Errors out of 85 words:

| setup        | raw | gate 0.5 | gate 0.8 | gate 1.0 |
| ------------ | --- | -------- | -------- | -------- |
| denoiser off | 10  | 9        | 10       | 7        |
| denoiser on  | 9   | 9        | 11       | 10       |

The gate stays out of domestique-listen. Gate 1.0's three words came from
single words flipping (quota as "quote up", main as "Maine"), gate 0.8 tied
raw, and with the denoiser on gate 1.0 lost.

The denoiser took about 15 dB off the fan (noise RMS -41.8 to -57 dBFS) and
left speech level and WER alone. It stays on, since it runs on the interface
for free.

[trex's home.nix](../nix/hosts/trex/home.nix) pins `inputDevice` to the MVX2U,
so the AirPods stay on A2DP with noise cancelling.

## Sources

- [Senal MC24-EL manual](https://www.manualslib.com/manual/1346833/Senal-Mc24-El.html)
- [Shure MVX2U Gen 2](https://www.bhphotovideo.com/c/product/1947101-REG/shure_mvx2ug2_mvx2u_gen_2_xlr.html),
  [CAMVATE C0924 double 3/8"-16 male stud](https://www.bhphotovideo.com/c/product/1453845-REG/camvate_c0924_double_male_thread_adapter.html)
- [MVX2U spec sheet](https://www.fullcompass.com/common/files/87077-MVX2USpecSheet.pdf),
  [Gen 2 changes](https://www.gearnews.com/?p=245814),
  [160 mA draw](https://www.klundertmusic.nl/en/shure-mvx2u-gen-2)
- [Rode AI-1 gain](https://www.kirstein.de/fr/Live-Studio/Studio/Interfaces-Audio/Rode-AI-1-USB-Audio-Interface.html)
- [Manfrotto 244N](https://www.bhphotovideo.com/c/product/803467775-USE/manfrotto_244n_variable_friction_magic.html),
  [Auray DUSM-1](https://www.abelcine.com/buy/audio/audio-accessories/auray-dusm-1-universal-shock-mount-for-camera-shoes-and-boompoles)
- [USB 3.2 specification](https://www.usb.org/document-library/usb-32-revision-11-june-2022)
- [noisereduce v3.0.3, stationary mode](https://github.com/timsainb/noisereduce/blob/v3.0.3/README.md?plain=1#L32-L47)
- [Iwamoto et al., "How Bad Are Artifacts?"](https://arxiv.org/abs/2201.06685)

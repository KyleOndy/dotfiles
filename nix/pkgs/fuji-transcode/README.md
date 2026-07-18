# fuji-transcode

Transcodes a directory of Fuji X-T5 clips into an editing intermediate,
detecting F-Log2 clips (via the camera's own metadata, not container color
tags) and baking Fuji's official F-Log2 -> Rec.709 LUT into them. Normal
clips are transcoded alongside them with no LUT applied, so the output
directory is one consistent, ready-to-edit set.

## Why detection uses exiftool, not ffprobe

`ffprobe`'s `color_transfer`/`color_primaries` tags read `bt709` on Fuji X-T5
clips even when they are genuinely F-Log2 - the container's color atom does
not reflect the picture profile. The camera's maker-note does: the
authoritative field is

```
exiftool -s3 -VideoRecordingMode clip.MOV
```

which returns `F-log2`, `F-log`, or `Normal`. This tool uses that field to
classify every clip.

## The ideal X-T5 recording format

The single most important rule: **on the X-T5, H.264 is 8-bit 4:2:0 only.**
10-bit (and 4:2:2) exist _only_ in H.265/HEVC. The camera lets you record
F-Log2 into 8-bit H.264 without complaint - it does not enforce HEVC + 10-bit
alongside F-Log2 - and that wastes the log curve: F-Log2 is a flat profile
meant to be stretched back out in the color page, and 8-bit's 256
levels/channel band visibly when stretched that hard. **Whenever you select
F-Log2, also explicitly select HEVC and 10-bit.**

Source: Fujifilm's official X-T5 specifications
(https://www.fujifilm-x.com/global/products/cameras/x-t5/specifications/).

**F-Log2 (grade in post, max dynamic range):**

| Setting              | Value                                                                   | Why                                                                    |
| -------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Movie mode / profile | F-Log2 (13+ stops)                                                      | flat curve, most grading latitude                                      |
| Codec                | H.265 / HEVC                                                            | required for 10-bit; H.264 is 8-bit only                               |
| Bit depth            | 10-bit                                                                  | log needs 1024 levels/channel or it bands when stretched               |
| Chroma               | 4:2:0 now; 4:2:2 once on RTX 50 / Apple Silicon                         | 4:2:0 hardware-decodes everywhere                                      |
| Resolution / fps     | 4K UHD 3840x2160, up to 30p (60p if needed)                             | fits free DaVinci Resolve's 4K/60p export cap; 6.2K only for reframing |
| Compression          | Long GOP default; All-Intra 360Mbps for heavy grades / easier scrubbing |                                                                        |
| Bitrate              | 200Mbps (Long GOP) or 360Mbps (All-Intra)                               |                                                                        |

**Normal (film-sim look, little/no grading):**

| Setting                        | Value                                                                                | Why                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Movie mode                     | a Film Simulation (Eterna for video, or Provia/Classic Chrome)                       | look baked in-camera                                              |
| Codec / bit depth              | H.265/HEVC 10-bit preferred; H.264 8-bit only for max compatibility / smallest files | 10-bit keeps skies/gradients smooth and leaves minor grading room |
| Chroma                         | 4:2:0                                                                                | delivery standard                                                 |
| Resolution / fps / compression | same as F-Log2 above                                                                 |                                                                   |

## Getting the LUT

Fuji's F-Log2 -> Rec.709 3D LUTs are free but not redistributable, so this
tool takes one as a `--lut` argument rather than bundling it. Download from:

https://www.fujifilm-x.com/global/support/download/lut/

The current pack (as of late 2025) is 12 `.cube` files, all targeting BT.709:
10 film-simulation looks (Eterna, Provia, Velvia, Astia, Classic Chrome,
Reala Ace, Pro Neg.std, Classic Neg., Eterna Bleach Bypass, Acros) plus 2
utility conversions (neutral - 0 black level, and natural - offset black
level). Eterna is the standard video-look choice; the neutral/natural
utility LUTs are better starting points if you plan to grade further in
Resolve.

## Usage

```
fuji-transcode --lut Eterna.cube /path/to/clips
```

Produces `/path/to/clips/transcoded/` with one `.mov` per source clip:
F-Log2 clips get the LUT baked in via ffmpeg's `lut3d` filter, normal clips
are transcoded with no LUT. Default codec is DNxHR LB (intra-frame, edits
smoothly even on weak GPUs); see `--help` for the full flag list, including
`--codec prores|h264|h265`, `--flog2-only`, `--copy-normal`, and `--force`.

### Baking the LUT vs. keeping the log curve

Baking the LUT (the default, with `--lut`) produces a finished Rec.709 look -
good for cutting and review, but there is no log left to grade afterward. To
practice real node-based grading instead, use `--flat`, which transcodes
F-Log2/F-Log clips to the same intermediate codec but leaves the log curve
intact (no `--lut`/`--flog-lut` needed or allowed in this mode):

```
fuji-transcode --flat /path/to/clips
```

Then apply the LUT as a node in Resolve's color page, or set Resolve's Color
Management input color space to F-Log2, and grade from there. `--lut` and
`--flat` are mutually exclusive - pick baked-and-done or flat-for-grading per
run.

### Correctness notes

- `lut3d` maps code values directly, which is the standard way to apply
  Fuji's LUT. If the baked result's levels look off, that is a full/limited
  range mismatch - fix it in the filter chain rather than in this script's
  defaults.
- Source footage from the X-T5 in 8-bit H.264 mode stays 8-bit through this
  pipeline; requesting a 10-bit output codec (`--codec prores` or `--codec
h265`) does not recover precision that was never captured. DNxHR LB
  (8-bit) is the correct default for 8-bit sources.

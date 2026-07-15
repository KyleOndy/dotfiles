"""Focus sharpness scoring for photo culling.

Provides a relative, resolution-independent "how in-focus is this photo"
score computed with pure Pillow - no numpy, no OpenCV. See sharpness_score
for the algorithm and why it deliberately does not produce an absolute
"blurry" verdict.
"""

from PIL import Image, ImageFilter, ImageStat

# 3x3 discrete Laplacian (2nd-derivative / edge-response) kernel. scale=1
# leaves the raw response unscaled, so variance is directly comparable
# across images processed at the same work_size.
_LAPLACIAN = ImageFilter.Kernel((3, 3), [0, 1, 0, 1, -4, 1, 0, 1, 0], scale=1)

DEFAULT_WORK_SIZE = 1024
DEFAULT_GRID = 4


def sharpness_score(
    img: Image.Image, *, work_size: int = DEFAULT_WORK_SIZE, grid: int = DEFAULT_GRID
) -> float:
    """Score how in-focus img is. Higher means sharper.

    Uses variance of the Laplacian, a standard blur metric: a blurry image
    has few edges and low high-frequency variance, while a sharp image has
    many (https://pyimagesearch.com/2015/09/07/blur-detection-with-opencv/).

    Two choices make the raw metric usable for culling instead of just a
    noisy single number:

    - Resolution-normalized: img is downscaled to fit within a
      work_size x work_size box before scoring, so the same scene shot at
      different camera resolutions scores comparably.
    - Tile-max, not global: img is scored per-tile over a grid x grid grid
      and the *maximum* tile variance is returned rather than a global
      variance. A shallow-depth-of-field shot (sharp subject, blurred
      background) is sharp in at least one tile and is not penalized for
      the soft background - a global score would rate it as blurry even
      though the subject is in perfect focus.

    There is deliberately no fixed "blurry" threshold here: the score is
    only meaningful relative to other photos scored the same way (see
    Session.sharpness / Session.sharpness_bucket). An absolute cutoff does
    not transfer between scenes, lenses, or resolutions.

    Args:
        img: Decoded, EXIF-oriented image to score.
        work_size: Images are downscaled to fit within work_size x
            work_size before scoring, so cost and output are independent
            of the original resolution.
        grid: Number of tiles per axis (grid x grid tiles total).

    Returns:
        The maximum per-tile Laplacian variance, in arbitrary units.
        Meaningful only relative to other scores computed with the same
        work_size/grid.
    """
    gray = img.convert("L")
    gray.thumbnail((work_size, work_size), Image.Resampling.LANCZOS)
    laplacian = gray.filter(_LAPLACIAN)

    # Pillow's Kernel convolution zero-pads outside the image, so the
    # outermost 1px ring of a 3x3 kernel's output reflects that padding,
    # not the image - a flat photo edge (sky, wall) can register a false
    # response there. Crop it off before scoring so it can never be picked
    # up as the sharpest tile.
    width, height = laplacian.size
    if width > 2 and height > 2:
        laplacian = laplacian.crop((1, 1, width - 1, height - 1))

    width, height = laplacian.size
    tile_w, tile_h = width // grid, height // grid
    if tile_w == 0 or tile_h == 0:
        # Image too small to tile meaningfully at this grid - score it whole.
        return ImageStat.Stat(laplacian).var[0]

    best = 0.0
    for row in range(grid):
        for col in range(grid):
            box = (
                col * tile_w,
                row * tile_h,
                width if col == grid - 1 else (col + 1) * tile_w,
                height if row == grid - 1 else (row + 1) * tile_h,
            )
            variance = ImageStat.Stat(laplacian.crop(box)).var[0]
            best = max(best, variance)
    return best

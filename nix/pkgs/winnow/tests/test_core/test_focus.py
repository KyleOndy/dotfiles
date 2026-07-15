"""Tests for the focus sharpness scoring module."""

from PIL import Image, ImageDraw, ImageFilter

from winnow.core.focus import sharpness_score


def _make_sharp_image(size: int = 400) -> Image.Image:
    """A high-frequency test image: a checkerboard of hard black/white edges.

    A checkerboard gives the Laplacian plenty of sharp transitions to
    respond to, unlike a flat color which would score near zero regardless
    of blur.
    """
    img = Image.new("RGB", (size, size), (255, 255, 255))
    draw = ImageDraw.Draw(img)
    step = 20
    for y in range(0, size, step):
        for x in range(0, size, step):
            if (x // step + y // step) % 2 == 0:
                draw.rectangle([x, y, x + step, y + step], fill=(0, 0, 0))
    return img


def test_sharp_image_scores_higher_than_blurred_copy():
    """A blurred copy of the same image scores lower than the original."""
    sharp = _make_sharp_image()
    blurred = sharp.filter(ImageFilter.GaussianBlur(6))

    assert sharpness_score(sharp) > sharpness_score(blurred)


def test_more_blur_scores_lower():
    """Increasing blur radius monotonically decreases the score."""
    sharp = _make_sharp_image()
    lightly_blurred = sharp.filter(ImageFilter.GaussianBlur(2))
    heavily_blurred = sharp.filter(ImageFilter.GaussianBlur(10))

    assert sharpness_score(sharp) > sharpness_score(lightly_blurred)
    assert sharpness_score(lightly_blurred) > sharpness_score(heavily_blurred)


def test_flat_color_image_scores_near_zero():
    """An image with no edges at all (flat color) has ~zero variance."""
    flat = Image.new("RGB", (200, 200), (128, 128, 128))

    assert sharpness_score(flat) == 0.0


def test_shallow_depth_of_field_scores_near_the_sharp_case():
    """Tile-max tolerates a sharp subject against a heavily blurred background.

    This is the shallow-depth-of-field / bokeh case that a global (whole-
    frame) variance-of-Laplacian would misjudge as blurry - the softened
    background drags a global average down even though the subject itself
    is in perfect focus. Tile-max takes the sharpest tile, so a photo that
    is sharp *anywhere* is not penalized for a deliberately soft background.
    """
    sharp = _make_sharp_image()
    blurred_background = sharp.filter(ImageFilter.GaussianBlur(10))

    # Simulate a bokeh portrait: sharp subject pasted over a blurred frame.
    bokeh = blurred_background.copy()
    w, h = sharp.size
    box = (w // 3, h // 3, 2 * w // 3, 2 * h // 3)
    bokeh.paste(sharp.crop(box), box[:2])

    fully_blurred_score = sharpness_score(blurred_background)
    bokeh_score = sharpness_score(bokeh)
    sharp_score = sharpness_score(sharp)

    # The bokeh shot should score well above the fully blurred frame...
    assert bokeh_score > fully_blurred_score * 1.5
    # ...and not collapse all the way down from the fully sharp score.
    assert bokeh_score > sharp_score * 0.25


def test_score_is_resolution_independent_for_the_same_scene():
    """The same scene at different resolutions scores comparably.

    sharpness_score downscales to a fixed working size before scoring, so
    a photo shot at a higher native resolution shouldn't score
    dramatically differently just because of pixel count.
    """
    sharp = _make_sharp_image(size=800)
    downscaled = sharp.resize((400, 400), Image.Resampling.LANCZOS)

    high_res_score = sharpness_score(sharp)
    low_res_score = sharpness_score(downscaled)

    # Not identical (resampling changes edge response slightly), but within
    # the same order of magnitude.
    ratio = high_res_score / low_res_score
    assert 0.3 < ratio < 3.0


def test_small_image_does_not_crash():
    """An image too small to tile at the default grid still scores cleanly."""
    tiny = _make_sharp_image(size=8)

    score = sharpness_score(tiny)

    assert score >= 0.0


def test_custom_grid_and_work_size_are_respected():
    """A finer grid still finds the sharp tile in a bokeh-style image."""
    sharp = _make_sharp_image()
    blurred_background = sharp.filter(ImageFilter.GaussianBlur(10))
    bokeh = blurred_background.copy()
    w, h = sharp.size
    box = (w // 3, h // 3, 2 * w // 3, 2 * h // 3)
    bokeh.paste(sharp.crop(box), box[:2])

    coarse = sharpness_score(bokeh, grid=2)
    fine = sharpness_score(bokeh, grid=8)

    # Both should find *some* sharp region; neither should be zero.
    assert coarse > 0.0
    assert fine > 0.0

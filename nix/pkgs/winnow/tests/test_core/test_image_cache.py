"""Tests for the bounded, LRU-evicted ImageCache.

Drives the real ImageCache directly (not mocked) - the concurrency stress
test in particular is the regression net for a previously-real data race
where a one-sided lock let worker threads iterate the cache dicts while the
main thread mutated them unlocked, raising "dictionary changed size during
iteration" and silently dropping photos.
"""

from PySide6.QtGui import QPixmap

from winnow.core.image_cache import ImageCache


def test_get_returns_none_for_uncached_path(qapp, portrait_image):
    """A path that was never put/loaded is a cache miss."""
    cache = ImageCache()
    assert cache.get(portrait_image) is None


def test_put_then_get_round_trips(qapp, portrait_image):
    """put() followed by get() returns the same pixmap."""
    cache = ImageCache()
    pixmap = QPixmap(str(portrait_image))

    cache.put(portrait_image, pixmap)

    assert cache.get(portrait_image) is pixmap


def test_get_memory_usage_mb_reflects_only_cache(qapp, portrait_image, landscape_image):
    """Memory estimate is the sum of cached pixmap widths*heights*4 bytes."""
    cache = ImageCache()
    assert cache.get_memory_usage_mb() == 0.0

    portrait_pixmap = QPixmap(str(portrait_image))
    landscape_pixmap = QPixmap(str(landscape_image))
    cache.put(portrait_image, portrait_pixmap)
    cache.put(landscape_image, landscape_pixmap)

    expected_bytes = (
        portrait_pixmap.width() * portrait_pixmap.height() * 4
        + landscape_pixmap.width() * landscape_pixmap.height() * 4
    )
    expected_mb = expected_bytes / (1024 * 1024)
    assert cache.get_memory_usage_mb() == expected_mb


def test_is_active_reflects_active_set(qapp, qtbot, portrait_image, landscape_image):
    """is_active() tracks the paths from the most recent set_active_images call."""
    cache = ImageCache()
    assert not cache.is_active(portrait_image)

    cache.set_active_images({portrait_image})
    assert cache.is_active(portrait_image)
    assert not cache.is_active(landscape_image)

    cache.set_active_images({landscape_image})
    assert not cache.is_active(portrait_image)
    assert cache.is_active(landscape_image)

    # Both calls queued a real background decode for their active path
    # (neither was cached yet) - drain both before returning.
    qtbot.waitUntil(
        lambda: cache.get(portrait_image) is not None
        and cache.get(landscape_image) is not None,
        timeout=2000,
    )


def test_set_active_images_does_not_evict_within_budget(
    qapp, portrait_image, landscape_image, square_image
):
    """Anything cached stays cached as long as the budget allows it.

    This is the core behavior change from the old evict-everything-outside-
    active-set design: revisiting an already-viewed photo, or navigating
    back to one, should be a cache hit rather than a re-decode. With the
    default multi-gigabyte budget, these tiny test images are nowhere near
    triggering eviction.
    """
    cache = ImageCache()
    cache.put(portrait_image, QPixmap(str(portrait_image)))
    cache.put(landscape_image, QPixmap(str(landscape_image)))
    cache.put(square_image, QPixmap(str(square_image)))

    # Only portrait is active, nothing prefetched - but landscape and square
    # stay cached, since nothing is evicted while under budget.
    cache.set_active_images({portrait_image})

    assert cache.get(portrait_image) is not None
    assert cache.get(landscape_image) is not None
    assert cache.get(square_image) is not None


def test_inactive_lru_entry_evicted_when_over_budget(
    qapp, portrait_image, landscape_image
):
    """The least-recently-touched non-active entry is evicted first over budget.

    portrait.jpg and landscape.jpg are both 100x200px (0.076MB as ARGB), so
    a budget just under 2x that size holds one comfortably but not both.
    """
    cache = ImageCache(max_memory_mb=0.1)

    cache.put(portrait_image, QPixmap(str(portrait_image)))
    cache.put(landscape_image, QPixmap(str(landscape_image)))

    # Adding landscape pushed memory over budget; portrait (older, and
    # never touched again) is the LRU victim.
    assert cache.get(portrait_image) is None
    assert cache.get(landscape_image) is not None


def test_active_images_survive_eviction_even_over_budget(
    qapp, portrait_image, landscape_image
):
    """An active (displayed) image is never evicted, even over budget.

    Simulates comparison mode: both images are active simultaneously, with a
    budget far smaller than either alone. Naive LRU eviction would want to
    reclaim one of them, but active images are exempt - the cache is allowed
    to run over budget rather than evict something on screen.

    Sets _active_images directly rather than via set_active_images(), which
    would also queue a real background decode for each path not yet
    cached - out of scope here, which is only about the eviction-protection
    invariant once both are already cached.
    """
    cache = ImageCache(max_memory_mb=0.01)
    cache._active_images = {portrait_image, landscape_image}

    cache.put(portrait_image, QPixmap(str(portrait_image)))
    cache.put(landscape_image, QPixmap(str(landscape_image)))

    assert cache.get(portrait_image) is not None
    assert cache.get(landscape_image) is not None


def test_set_active_images_keeps_prefetch_paths(qapp, portrait_image, landscape_image):
    """A cached path in the prefetch set (but not active) is not evicted."""
    cache = ImageCache()
    cache.put(portrait_image, QPixmap(str(portrait_image)))
    cache.put(landscape_image, QPixmap(str(landscape_image)))

    cache.set_active_images({portrait_image}, prefetch={landscape_image})

    assert cache.get(portrait_image) is not None
    assert cache.get(landscape_image) is not None


def test_set_active_images_queues_and_delivers_prefetch(qapp, qtbot, portrait_image):
    """An uncached prefetch path is decoded in the background and cached.

    Exercises the full async path: worker decodes a QImage, the main thread
    converts it to a QPixmap in _on_image_loaded, and image_ready fires.
    """
    cache = ImageCache()
    ready_paths = []
    cache.image_ready.connect(ready_paths.append)

    cache.set_active_images(set(), prefetch={portrait_image})

    qtbot.waitUntil(lambda: cache.get(portrait_image) is not None, timeout=2000)

    pixmap = cache.get(portrait_image)
    assert pixmap is not None
    assert not pixmap.isNull()
    assert ready_paths == [portrait_image]


def test_request_queues_background_decode_and_delivers(qapp, qtbot, portrait_image):
    """request() decodes an uncached path in the background and caches it."""
    cache = ImageCache()
    ready_paths = []
    cache.image_ready.connect(ready_paths.append)

    cache.request(portrait_image)

    qtbot.waitUntil(lambda: cache.get(portrait_image) is not None, timeout=2000)
    assert ready_paths == [portrait_image]


def test_request_is_noop_for_already_cached_path(qapp, portrait_image):
    """request() on an already-cached path bumps recency without re-decoding."""
    cache = ImageCache()
    pixmap = QPixmap(str(portrait_image))
    cache.put(portrait_image, pixmap)

    cache.request(portrait_image)

    # Still the exact same object - no background decode replaced it.
    assert cache.get(portrait_image) is pixmap


def test_load_failed_emitted_for_corrupt_file(qapp, qtbot, tmp_path):
    """A background decode that raises emits load_failed, not image_ready."""
    corrupt = tmp_path / "corrupt.jpg"
    corrupt.write_bytes(b"not a real jpeg")

    cache = ImageCache()
    ready_paths = []
    failed_paths = []
    cache.image_ready.connect(ready_paths.append)
    cache.load_failed.connect(failed_paths.append)

    cache.request(corrupt)

    qtbot.waitUntil(lambda: failed_paths == [corrupt], timeout=2000)
    assert ready_paths == []
    assert cache.get(corrupt) is None


def test_clear_removes_everything(qapp, portrait_image):
    """clear() empties the cache."""
    cache = ImageCache()
    cache.put(portrait_image, QPixmap(str(portrait_image)))
    assert cache.get(portrait_image) is not None

    cache.clear()

    assert cache.get(portrait_image) is None
    assert cache.get_memory_usage_mb() == 0.0


def test_rapid_selection_changes_do_not_raise(
    qapp, qtbot, portrait_image, landscape_image, square_image
):
    """Regression test for the dict-mutation-during-iteration data race.

    The old design had worker threads iterate self._cache/_pyramid_cache
    under a lock the main thread never took when inserting new keys,
    raising "RuntimeError: dictionary changed size during iteration" and
    silently dropping photos. The current design keeps all _cache mutation
    on the main thread, so there is nothing left for a worker to race - this
    simulates rapid arrow-key navigation (many overlapping set_active_images
    calls, each queuing a background prefetch) and asserts nothing raises
    and the pool drains cleanly.
    """
    from PySide6.QtCore import QThreadPool

    images = [portrait_image, landscape_image, square_image]
    cache = ImageCache()

    errors = []
    cache.image_ready.connect(lambda path: None)  # keep the connection warm

    import builtins

    original_print = builtins.print

    def capturing_print(*args, **kwargs):
        text = " ".join(str(a) for a in args)
        if "Failed to load" in text or "RuntimeError" in text:
            errors.append(text)
        original_print(*args, **kwargs)

    builtins.print = capturing_print
    try:
        for round_num in range(30):
            path = images[round_num % len(images)]
            neighbors = {p for p in images if p != path}
            cache.set_active_images({path}, prefetch=neighbors)
            qapp.processEvents()
    finally:
        builtins.print = original_print

    # Drain any in-flight background tasks and let queued signals deliver.
    QThreadPool.globalInstance().waitForDone(2000)
    for _ in range(20):
        qapp.processEvents()

    assert (
        not errors
    ), f"background load errors during rapid selection changes: {errors}"

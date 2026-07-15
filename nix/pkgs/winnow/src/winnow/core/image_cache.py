"""In-memory cache for full-resolution images, bounded by a memory budget.

The currently active (displayed) images are always kept in memory and are
never evicted, no matter how long they've been displayed. Everything else -
prefetched neighbors, previously-viewed photos - is kept too, up to
max_memory_mb, evicted least-recently-used first once that budget is
exceeded. This means revisiting a photo or navigating back to one already
seen is a cache hit rather than a re-decode, while still bounding memory
rather than preloading (or indefinitely retaining) the whole directory.

Background worker threads decode images into QImage, which is safe to build
and manipulate off the GUI thread. QPixmap conversion always happens on the
main thread via a queued signal, since Qt does not support creating or
scaling QPixmap outside the GUI thread.
"""

from collections import OrderedDict
from pathlib import Path

from PIL import Image, ImageOps
from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, Signal
from PySide6.QtGui import QImage, QPixmap


class ImageLoadTask(QRunnable):
    """Runnable task that decodes a single image on a background thread."""

    def __init__(self, path: Path, cache: "ImageCache") -> None:
        """Initialize the image load task.

        Args:
            path: Path to the image file to load.
            cache: ImageCache instance to notify on completion.
        """
        super().__init__()
        self.path = path
        self.cache = cache
        self.setAutoDelete(True)

    def run(self) -> None:
        """Decode the image to a QImage and notify the cache.

        Only builds a QImage here - QPixmap must not be created or scaled
        outside the GUI thread, so the QPixmap conversion happens in the
        main-thread handler (_on_image_loaded) instead.
        """
        try:
            qimage = self._load_qimage()
            self.cache._image_loaded.emit(self.path, qimage, True)
        except Exception as e:
            print(f"Failed to load {self.path}: {e}")
            self.cache._image_loaded.emit(self.path, None, False)

    def _load_qimage(self) -> QImage:
        """Load full-resolution image with EXIF orientation applied.

        Returns:
            QImage containing the loaded image. QImage is thread-safe to
            build and manipulate off the GUI thread, unlike QPixmap.

        Raises:
            Exception: If image loading fails.
        """
        img = Image.open(self.path)
        img = ImageOps.exif_transpose(img) or img

        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGB")

        if img.mode == "RGB":
            data = img.tobytes("raw", "RGB")
            qimage = QImage(
                data, img.width, img.height, img.width * 3, QImage.Format.Format_RGB888
            )
        else:  # RGBA
            data = img.tobytes("raw", "RGBA")
            qimage = QImage(
                data,
                img.width,
                img.height,
                img.width * 4,
                QImage.Format.Format_RGBA8888,
            )

        # Copy so the QImage owns its buffer once `data` (and `img`) go out
        # of scope at the end of this worker call.
        return qimage.copy()


class ImageCache(QObject):
    """Bounded, LRU-evicted cache of full-resolution images.

    Holds full-resolution QPixmaps for every image decoded so far, up to
    max_memory_mb - well beyond just what's on screen, since the point is to
    make revisits and back-navigation instant rather than a re-decode. Once
    over budget, the least-recently-used entry is evicted, except paths in
    the current active set (set via set_active_images()), which are never
    evicted while displayed, even if that means briefly running over budget.
    """

    # Emitted on the main thread once a background-loaded image is cached.
    image_ready = Signal(Path)

    # Emitted on the main thread when a background decode fails (corrupt or
    # unreadable file).
    load_failed = Signal(Path)

    # Internal signal used to marshal background thread callbacks to the main
    # thread. (path, qimage, success)
    _image_loaded = Signal(object, object, bool)

    def __init__(
        self,
        max_threads: int = 6,
        max_memory_mb: float = 24576.0,
        parent: QObject | None = None,
    ) -> None:
        """Initialize the image cache.

        Args:
            max_threads: Maximum number of parallel background decode threads.
            max_memory_mb: Soft memory budget in MB. Once cached pixmaps
                exceed this, least-recently-used entries are evicted (never
                the currently active/displayed images) until back under
                budget. Default is generous - see --max-memory.
            parent: Optional parent QObject.
        """
        super().__init__(parent)

        self.thread_pool = QThreadPool.globalInstance()
        self.thread_pool.setMaxThreadCount(max_threads)
        self.max_memory_mb = max_memory_mb

        # Cache storage: path -> full-resolution pixmap, ordered oldest- to
        # most-recently-touched (move_to_end on every get/put/background
        # load), so the front of the dict is always the correct LRU
        # eviction victim.
        self._cache: OrderedDict[Path, QPixmap] = OrderedDict()

        # Paths currently displayed (as of the last set_active_images call).
        # Protected from eviction regardless of recency.
        self._active_images: set[Path] = set()

        # Paths with a background decode currently queued or running.
        self._inflight: set[Path] = set()

        # Marshal background thread callbacks to the main thread.
        self._image_loaded.connect(
            self._on_image_loaded, Qt.ConnectionType.QueuedConnection
        )

    def get(self, path: Path) -> QPixmap | None:
        """Get a cached image by path.

        A hit bumps the entry to most-recently-used, so repeatedly viewing
        the same photo keeps it near the front of the LRU eviction order.

        Args:
            path: Path to the image file.

        Returns:
            Cached QPixmap if available, None otherwise.
        """
        pixmap = self._cache.get(path)
        if pixmap is not None:
            self._cache.move_to_end(path)
        return pixmap

    def put(self, path: Path, pixmap: QPixmap) -> None:
        """Insert a synchronously-decoded image into the cache.

        Used directly by callers (and tests) that already have a decoded
        pixmap in hand. Only ever called on the main thread, so no locking is
        needed - all cache mutation happens on the main thread.

        Args:
            path: Path to the image file.
            pixmap: The decoded, valid (non-null) pixmap.
        """
        self._cache[path] = pixmap
        self._cache.move_to_end(path)
        self._evict_lru_if_over_budget()

    def is_active(self, path: Path) -> bool:
        """Check if an image is in the currently active (displayed) set.

        Args:
            path: Path to the image file.

        Returns:
            True if the image is in the active set, False otherwise.
        """
        return path in self._active_images

    def clear(self) -> None:
        """Clear all cached images from memory."""
        self._cache.clear()

    def get_memory_usage_mb(self) -> float:
        """Estimate memory usage of cached images in megabytes.

        Returns:
            Estimated memory usage in MB.
        """
        total_bytes = sum(
            pixmap.width() * pixmap.height() * 4 for pixmap in self._cache.values()
        )
        return total_bytes / (1024 * 1024)

    def request(self, path: Path) -> None:
        """Queue a background decode for path unless already cached or in flight.

        The single choke point for starting an ImageLoadTask. Both
        set_active_images (for the active selection and its prefetch
        neighbors) and ImageWidget (defensively, on its own cache miss) call
        this for the same paths in the common case, so a path the other
        caller already covered is a safe no-op rather than a duplicate
        decode.

        Args:
            path: Path to the image file to decode in the background.
        """
        if path in self._cache:
            self._cache.move_to_end(path)  # LRU hit - bump recency
            return
        if path in self._inflight:
            return
        self._inflight.add(path)
        task = ImageLoadTask(path, self)
        self.thread_pool.start(task)

    def set_active_images(
        self, active: set[Path], prefetch: set[Path] = frozenset()
    ) -> None:
        """Update the active set and queue background decodes for anything missing.

        Call this whenever the displayed selection changes. Active paths are
        protected from LRU eviction for as long as they stay in this set
        (see _evict_lru_if_over_budget). Both the active paths and their
        prefetch neighbors are requested here so they start decoding as soon
        as the selection changes, not only on a widget's own cache miss.

        Args:
            active: Paths currently displayed (selected).
            prefetch: Additional paths to opportunistically pre-decode in the
                background (e.g. neighbors of a single selection). Empty for
                comparison mode, where there's no obvious "next" image.
        """
        self._active_images = set(active)
        for path in self._active_images | set(prefetch):
            self.request(path)

    def _evict_lru_if_over_budget(self) -> None:
        """Evict least-recently-used, non-active entries while over budget.

        _cache iterates oldest-to-newest (OrderedDict, with move_to_end on
        every get/put/background load), so the first non-active path found
        is the correct LRU eviction victim. Active (currently displayed)
        images are never evicted, even if that leaves the cache over budget -
        better to briefly exceed max_memory_mb than to evict a photo the user
        is looking at right now.
        """
        while self.get_memory_usage_mb() > self.max_memory_mb:
            victim = next(
                (p for p in self._cache if p not in self._active_images), None
            )
            if victim is None:
                break
            del self._cache[victim]

    def _on_image_loaded(
        self, path: Path, qimage: QImage | None, success: bool
    ) -> None:
        """Handle a completed background load (runs on the main thread).

        Converts the decoded QImage to a QPixmap here, since QPixmap must
        only be created or scaled on the GUI thread.

        Args:
            path: Path to the loaded image.
            qimage: Decoded QImage, or None if loading failed.
            success: Whether the load succeeded.
        """
        self._inflight.discard(path)

        if success and qimage is not None:
            self._cache[path] = QPixmap.fromImage(qimage)
            self._cache.move_to_end(path)
            self._evict_lru_if_over_budget()
            self.image_ready.emit(path)
        else:
            self.load_failed.emit(path)

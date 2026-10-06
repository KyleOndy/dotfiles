"""Thumbnailer module for generating Qt-compatible thumbnails from images.

This module provides functionality to generate thumbnails from JPEG images using
Pillow, converting them to QPixmap format for display in Qt applications.
Thumbnails are generated with configurable size and maintain aspect ratio,
either synchronously (generate) or via a background queue (queue_thumbnail).
"""

from pathlib import Path

from PIL import Image, ImageOps
from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, Signal
from PySide6.QtGui import QColor, QImage, QPixmap


def _open_oriented(image_path: Path, size: int) -> Image.Image | None:
    """Open image_path at reduced resolution and apply its EXIF orientation.

    draft() lets libjpeg decode at 1/2, 1/4 or 1/8 scale while keeping both
    sides at least 2*size, so the LANCZOS pass still has twice the target
    resolution to work from. It is a no-op for non-JPEG files.

    Args:
        image_path: Path to the image file to open.
        size: Thumbnail size the result will be shrunk to, in pixels.

    Returns:
        The oriented PIL Image, or None on any decode failure.
    """
    try:
        img = Image.open(image_path)
        img.draft("RGB", (size * 2, size * 2))
        return ImageOps.exif_transpose(img) or img
    except Exception:
        return None


def _make_error_pixmap(size: int) -> QPixmap:
    """A filled gray square shown in place of a thumbnail that failed to decode.

    QPixmap(size, size) alone leaves pixel data uninitialized (Qt does not
    zero it), so callers must fill it explicitly or risk rendering garbage.

    Args:
        size: Side length of the pixmap, in pixels.

    Returns:
        A filled, valid QPixmap of size x size.
    """
    pixmap = QPixmap(size, size)
    pixmap.fill(QColor(128, 128, 128))
    return pixmap


class ThumbnailTask(QRunnable):
    """Runnable task that decodes a single thumbnail on a background thread."""

    def __init__(self, path: Path, size: int, thumbnailer: "Thumbnailer") -> None:
        """Initialize the thumbnail task.

        Args:
            path: Path to the image file to thumbnail.
            size: Target thumbnail size, captured at queue time so a later
                set_size() call can't change an in-flight task's target.
            thumbnailer: Thumbnailer instance to notify on completion.
        """
        super().__init__()
        self.path = path
        self.size = size
        self.thumbnailer = thumbnailer
        self.setAutoDelete(True)

    def run(self) -> None:
        """Decode the thumbnail and notify the thumbnailer.

        Only builds a QImage here - QPixmap must not be created outside the
        GUI thread, so the QPixmap conversion happens in the main-thread
        handler (Thumbnailer._on_thumbnail_loaded) instead.
        """
        qimage = self.thumbnailer.generate_qimage(self.path, self.size)
        self.thumbnailer._thumbnail_loaded.emit(self.path, qimage, self.size)


class Thumbnailer(QObject):
    """Generate thumbnails from JPEG images, synchronously or via a background queue.

    This class handles thumbnail generation using Pillow for image processing
    and converts the results to Qt-compatible QPixmap format. Thumbnails
    maintain the original aspect ratio and use high-quality LANCZOS resampling.

    Attributes:
        size: Maximum dimension (width or height) for generated thumbnails in pixels.
    """

    # Emitted on the main thread once a queue_thumbnail() task completes.
    # (path, pixmap) - pixmap is always valid (a blank placeholder on decode
    # failure), so callers never need to special-case a None result.
    thumbnail_ready = Signal(Path, QPixmap)

    # Internal signal marshaling background decode results to the main
    # thread. (path, qimage-or-None, size the task was queued at)
    _thumbnail_loaded = Signal(Path, object, int)

    def __init__(
        self, size: int = 150, max_threads: int = 4, parent: QObject | None = None
    ) -> None:
        """Initialize the Thumbnailer with a target size.

        Args:
            size: Maximum dimension for thumbnails in pixels. Defaults to 150.
                  Thumbnails will be scaled to fit within a size×size box
                  while maintaining aspect ratio.
            max_threads: Maximum parallel background decode threads.
                Pillow releases the GIL while decoding and resampling, so
                throughput scales with threads. A private pool rather than
                QThreadPool.globalInstance(), which ImageCache uses: on a
                10-core M5 (4P+6E), 4 here and 6 there fill every core while
                holding the photo on screen to about 145ms per decode during
                the initial thumbnail pass, against about 130ms idle. 8 here
                pushes it to about 175ms.
            parent: Optional parent QObject.
        """
        super().__init__(parent)
        self.size = size
        self._thread_pool = QThreadPool()
        self._thread_pool.setMaxThreadCount(max_threads)
        # (path, size) pairs with a decode currently queued or running, so a
        # caller re-requesting the same path/size (e.g. refresh_thumbnails()
        # racing an initial load still in flight) doesn't double the work.
        self._inflight: set[tuple[Path, int]] = set()
        self._thumbnail_loaded.connect(
            self._on_thumbnail_loaded, Qt.ConnectionType.QueuedConnection
        )

    def generate(self, image_path: Path) -> QPixmap:
        """Generate a thumbnail for the given image.

        Opens the image file, generates a thumbnail at the configured size,
        and converts it to a QPixmap suitable for display in Qt widgets.
        This operation is relatively fast (~20ms per image for typical JPEGs).

        The thumbnail maintains the original aspect ratio - it will fit within
        a size×size box but may be smaller in one dimension.

        Args:
            image_path: Path to the image file to thumbnail.

        Returns:
            QPixmap containing the thumbnail image. On error (corrupt file,
            unsupported format, etc.), returns a filled gray QPixmap of the
            configured size.

        Example:
            >>> thumbnailer = Thumbnailer(size=200)
            >>> pixmap = thumbnailer.generate(Path("photo.jpg"))
            >>> label.setPixmap(pixmap)  # Display in Qt label
        """
        qimage = self.generate_qimage(image_path, self.size)
        if qimage is None:
            # Error pixmap on any decode failure (corrupt file, unsupported
            # format, permission denied, etc.). QPixmap(w, h) alone leaves
            # pixel data uninitialized, so fill it explicitly.
            return _make_error_pixmap(self.size)
        return QPixmap.fromImage(qimage)

    def generate_qimage(self, image_path: Path, size: int) -> QImage | None:
        """Generate a thumbnail as a QImage, safe to call from a worker thread.

        Does the same decode-and-resize work as generate(), but stops at
        QImage rather than QPixmap - QPixmap must only be created on the GUI
        thread. Takes an explicit size rather than reading self.size, so a
        background task already in flight can't race a later set_size() call
        from the zoom slider.

        Args:
            image_path: Path to the image file to thumbnail.
            size: Maximum dimension for the thumbnail, in pixels.

        Returns:
            QImage containing the thumbnail, or None on error (corrupt file,
            unsupported format, permission denied, etc.) - the caller is
            responsible for substituting a placeholder.
        """
        img = _open_oriented(image_path, size)
        if img is None:
            return None
        try:
            return self._resize_to_qimage(img, size)
        except Exception:
            return None

    @staticmethod
    def _resize_to_qimage(img: Image.Image, size: int) -> QImage:
        """Shrink an oriented PIL image to a thumbnail and convert to QImage.

        Mutates and consumes img (thumbnail() resizes in place) - callers
        needing the original resolution must use it first.

        Args:
            img: Oriented PIL image, as returned by _open_oriented.
            size: Maximum dimension for the thumbnail, in pixels.

        Returns:
            A QImage owning its own pixel buffer.
        """
        # Generate thumbnail (maintains aspect ratio)
        img.thumbnail((size, size), Image.Resampling.LANCZOS)

        # Convert PIL Image to QImage
        img_bytes = img.tobytes("raw", img.mode)

        # Select appropriate QImage format based on image mode
        if img.mode == "RGB":
            qimage_format = QImage.Format_RGB888
        elif img.mode == "RGBA":
            qimage_format = QImage.Format_RGBA8888
        else:
            # Convert other modes to RGB
            img = img.convert("RGB")
            img_bytes = img.tobytes("raw", "RGB")
            qimage_format = QImage.Format_RGB888

        # Calculate bytes per line (stride) for proper QImage construction
        bytes_per_line = img.width * len(img.getbands())

        qimage = QImage(
            img_bytes,
            img.width,
            img.height,
            bytes_per_line,
            qimage_format,
        )

        # Copy so the QImage owns its buffer once `img_bytes` (and `img`)
        # go out of scope - important when called from a worker thread.
        return qimage.copy()

    def set_size(self, size: int) -> None:
        """Change the thumbnail size.

        This method updates the target size for future thumbnail generation.
        It does not regenerate existing thumbnails - that must be done
        separately by calling generate() or queue_thumbnail() again.

        This is used for the thumbnail zoom feature, allowing users to
        dynamically adjust thumbnail size in the UI.

        Args:
            size: New maximum dimension for thumbnails in pixels.
        """
        self.size = size

    def queue_thumbnail(self, image_path: Path) -> None:
        """Queue a background decode of image_path at the current size.

        Decoding happens on a worker thread; thumbnail_ready is emitted on
        the main thread once it completes (or fails, with a blank
        placeholder pixmap). A no-op if a decode for this exact (path, size)
        is already queued or running - without this, a caller that requests
        the same path twice before the first decode lands (e.g. a filter
        toggle racing the initial load) would queue duplicate work and
        compete with itself for the pool's threads. A genuine size change
        still queues a new task, since it's keyed on (path, size).

        Args:
            image_path: Path to the image file to thumbnail.
        """
        key = (image_path, self.size)
        if key in self._inflight:
            return
        self._inflight.add(key)
        task = ThumbnailTask(image_path, self.size, self)
        self._thread_pool.start(task)

    def shutdown(self) -> None:
        """Drop queued decodes and block until the running ones finish.

        Call before tearing down the Thumbnailer (e.g. on window close) so no
        worker thread emits into a partially-destroyed object. Queued tasks
        are discarded rather than drained: on a fresh directory that queue
        holds every thumbnail, tens of seconds of work nobody will see.
        """
        self._thread_pool.clear()
        self._thread_pool.waitForDone()

    def _on_thumbnail_loaded(
        self, path: Path, qimage: QImage | None, size: int
    ) -> None:
        """Handle a completed background decode (runs on the main thread).

        Converts the decoded QImage to a QPixmap here, since QPixmap must
        only be created on the GUI thread.

        Args:
            path: Path to the thumbnailed image.
            qimage: Decoded QImage, or None if decoding failed.
            size: The size this task was queued at.
        """
        self._inflight.discard((path, size))

        if size != self.size:
            # Superseded by a later size change (e.g. the zoom slider moved
            # again before this task finished) - a newer task is already
            # queued for the current size, so drop this stale result.
            return

        pixmap = (
            QPixmap.fromImage(qimage)
            if qimage is not None
            else _make_error_pixmap(size)
        )
        self.thumbnail_ready.emit(path, pixmap)

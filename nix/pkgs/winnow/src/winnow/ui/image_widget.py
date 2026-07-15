"""ImageWidget module for displaying zoomable/pannable photos with status overlay.

This module provides the core image viewing functionality with zoom and pan controls,
plus a status overlay for marking photos as keeper/delete/unmarked.
"""

import math
from pathlib import Path

from PIL import Image, ImageOps
from PySide6.QtCore import QEvent, QPoint, QRect, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QImage, QMouseEvent, QPixmap, QWheelEvent
from PySide6.QtWidgets import (
    QGestureEvent,
    QHBoxLayout,
    QLabel,
    QPinchGesture,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from winnow.core.session import PhotoStatus, Session

# Standard zoom stops, as percentages of original image size. Single source
# of truth for the zoom ladder - reused by wheelEvent, pinch_triggered (as
# fractions), and ZoomControlOverlay in viewing_area.py, so changing the
# ladder only requires editing this one list.
ZOOM_STOPS_PERCENT = (10, 25, 33, 50, 67, 75, 100, 150, 200, 300, 400)


class ImageWidget(QWidget):
    """Zoomable/pannable image viewer with status overlay.

    Displays a full-resolution image with mouse wheel zoom (0.1x to 10x range)
    and click-and-drag pan functionality. At 1.0x zoom, the image fits the widget
    while maintaining aspect ratio.

    Coordinate System:
        - zoom_level: Multiplier of original image size (e.g., 2.0 = 200% of original)
        - pan_offset: Position in ORIGINAL image pixels (not scaled)
        - During rendering, pan_offset is multiplied by zoom_level to get scaled position
        - This makes pan_offset independent of viewport size changes

    When synchronized=True, emits zoom_changed and pan_changed signals for
    coordinating multiple viewers in comparison mode.

    Signals:
        zoom_changed(float): Emitted when zoom level changes (if synchronized)
        pan_changed(int, int): Emitted when pan offset changes (if synchronized)
        remove_from_comparison: Emitted when Ctrl+click to remove from comparison
        mark_requested(Path, PhotoStatus): Overlay button asked for a status
    """

    zoom_changed = Signal(float)
    pan_changed = Signal(int, int)
    fit_mode_changed = Signal(bool)
    remove_from_comparison = Signal()
    mark_requested = Signal(Path, PhotoStatus)

    def __init__(
        self,
        path: Path,
        session: Session,
        synchronized: bool = False,
        fixed_size: QSize | None = None,
    ) -> None:
        """Initialize the ImageWidget.

        Args:
            path: Path to the image file to display.
            session: Session object for status tracking.
            synchronized: If True, emit signals for zoom/pan synchronization.
            fixed_size: If provided, constrain display to this uniform size.
        """
        super().__init__()
        self.path = path
        self.session = session
        self.synchronized = synchronized
        self.fixed_size = fixed_size
        self._focused = False

        # Zoom/pan state
        self.zoom_level = 1.0
        self.fit_mode = (
            True  # True = fit image to widget; False = zoom_level is % of original
        )
        self.pan_offset = QPoint(0, 0)  # Synchronized pan offset (shared across images)
        self.individual_pan_offset = QPoint(
            0, 0
        )  # Individual pan offset (this image only)
        self.last_mouse_pos: QPoint | None = None
        self.is_shift_panning = False  # Track if currently shift-panning
        self.is_ctrl_click = False  # Track if Ctrl was pressed on mouse down
        self.viewport_size: QSize | None = (
            None  # Track viewport size for pan adjustment
        )

        # True while original_pixmap is a placeholder standing in for a
        # background decode that hasn't landed yet (see load_full_image).
        self._pending_full_load = False

        # Load full-resolution image (from cache if available, otherwise
        # from disk or a placeholder while a background decode runs).
        self.original_pixmap = self.load_full_image()

        # Build UI
        self.setup_ui()

        # Enable pinch gesture for trackpad support
        self.grabGesture(Qt.GestureType.PinchGesture)

        # Initial display
        self.update_display()

    def load_full_image(self) -> QPixmap:
        """Load full-resolution image from cache, or start loading it.

        First attempts to load from the session's image cache for instant
        access (a hit means either this image was already viewed, or the
        cache's background prefetch got to it first). On a cache miss, a
        full-resolution decode is too slow to run synchronously on the UI
        thread for the photo the user just clicked, so instead:

        - If a background cache exists, queue a decode there and return a
          placeholder immediately (see _placeholder_pixmap); set_full_image()
          swaps in the real pixmap once ImageCache.image_ready reports it via
          ViewingArea.
        - Otherwise (no cache - only true in tests, which never show the
          window), fall back to a synchronous decode, since there is no
          background path to hand this off to.

        Returns:
            QPixmap containing the full-resolution image with correct
            orientation (on a hit or synchronous fallback), a placeholder
            (while a background decode is pending), or a null QPixmap if a
            synchronously-decoded file could not be read (see
            has_valid_image()).
        """
        # Try to load from cache first
        cached_pixmap = self.session.get_full_image(self.path)
        if cached_pixmap is not None:
            return cached_pixmap

        if self.session.image_cache is not None:
            self._pending_full_load = True
            self.session.image_cache.request(self.path)
            return self._placeholder_pixmap()

        # No cache at all - decode from disk on the main thread.
        return self._decode_from_disk()

    def _decode_from_disk(self) -> QPixmap:
        """Decode the image file directly, applying EXIF orientation.

        Returns:
            QPixmap containing the decoded image, or a null QPixmap if
            decoding fails (corrupt, truncated, or zero-byte file).
        """
        try:
            # Open image with PIL to handle EXIF orientation
            img = Image.open(self.path)

            # Apply EXIF orientation to rotate image correctly
            img = ImageOps.exif_transpose(img) or img

            # Convert to RGB if needed (handles RGBA, grayscale, etc.)
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGB")

            # Convert PIL Image to QPixmap
            img_bytes = img.tobytes("raw", img.mode)

            # Select appropriate QImage format
            qimage_format = (
                QImage.Format_RGB888 if img.mode == "RGB" else QImage.Format_RGBA8888
            )

            # Calculate bytes per line
            bytes_per_line = img.width * len(img.getbands())

            qimage = QImage(
                img_bytes,
                img.width,
                img.height,
                bytes_per_line,
                qimage_format,
            )

            return QPixmap.fromImage(qimage)

        except Exception:
            # Fallback to Qt's loader if PIL fails
            return QPixmap(str(self.path))

    def _placeholder_pixmap(self) -> QPixmap:
        """Return an immediate stand-in shown while the full image decodes in the background.

        Reuses the already-decoded thumbnail when one is available - it
        almost always is, since thumbnails decode on their own fast
        background pool well before a photo is likely to be selected - so
        the widget shows the right photo, just softly, rather than a blank
        box. Falls back to a neutral gray square if no thumbnail has landed
        yet either.

        Returns:
            A valid (non-null) QPixmap suitable for immediate display.
        """
        thumbnail = self.session.thumbnails.get(self.path)
        if thumbnail is not None and not thumbnail.isNull():
            return thumbnail
        placeholder = QPixmap(64, 64)
        placeholder.fill(Qt.GlobalColor.darkGray)
        return placeholder

    def set_full_image(self, pixmap: QPixmap) -> None:
        """Swap in the real full-resolution pixmap once its background decode lands.

        Called by ViewingArea when the cache reports this widget's path is
        ready (see ImageCache.image_ready / ViewingArea.on_image_ready).

        Args:
            pixmap: The decoded, valid (non-null) full-resolution pixmap.
        """
        if pixmap is None or pixmap.isNull():
            return
        self._pending_full_load = False
        self.original_pixmap = pixmap
        self.update_display()

    def show_load_failed(self) -> None:
        """Show the corrupt/unreadable-file placeholder for a failed background decode.

        Called by ViewingArea when the cache reports this widget's path
        failed to decode (see ImageCache.load_failed / ViewingArea.
        on_image_load_failed).
        """
        self._pending_full_load = False
        self.original_pixmap = QPixmap()
        self.update_display()

    def has_valid_image(self) -> bool:
        """Check whether original_pixmap is a valid, non-empty image.

        A corrupt, truncated, or zero-byte file yields a null (0x0) pixmap -
        either from load_full_image's synchronous fallback, or from
        show_load_failed() after a failed background decode. Callers must
        check this before dividing by original_pixmap.width()/height()
        (fit-percentage and zoom-to-cursor math), or an invalid file would
        raise ZeroDivisionError on selection. While a background decode is
        still pending, original_pixmap is a placeholder (see
        _placeholder_pixmap) and this returns True - the placeholder is a
        valid pixmap in its own right, just not the final image.

        Returns:
            True if original_pixmap has positive width and height.
        """
        return (
            self.original_pixmap is not None
            and self.original_pixmap.width() > 0
            and self.original_pixmap.height() > 0
        )

    def setup_ui(self) -> None:
        """Build the widget UI with image label and status overlay."""
        layout = QVBoxLayout(self)
        if self.fixed_size is not None:
            # Comparison tile: reserve constant room for the focus ring so
            # toggling focus never reflows the grid, and enable stylesheet
            # backgrounds - a plain QWidget subclass won't render stylesheet
            # borders without WA_StyledBackground.
            self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
            layout.setContentsMargins(3, 3, 3, 3)
        else:
            layout.setContentsMargins(0, 0, 0, 0)

        # Image display label
        self.image_label = QLabel()
        self.image_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        # Enable clipping so zoomed images don't expand the widget
        self.image_label.setScaledContents(False)
        # Set maximum size policy to prevent expansion
        from PySide6.QtWidgets import QSizePolicy

        self.image_label.setSizePolicy(
            QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored
        )
        layout.addWidget(self.image_label)

        # Status overlay (positioned at top-left)
        self.overlay = StatusOverlay(self.path, self.session)
        self.overlay.setParent(self)
        self.overlay.move(10, 10)
        self.overlay.raise_()
        self.overlay.mark_requested.connect(self._relay_mark_request)

        # Position number label (top-right corner, hidden by default)
        self.position_label = QLabel()
        self.position_label.setParent(self)
        self.position_label.setFixedSize(24, 24)
        self.position_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.position_label.setStyleSheet(
            "background-color: rgba(0, 0, 0, 150); color: white; "
            "font-weight: bold; font-size: 12px; border-radius: 12px;"
        )
        self.position_label.hide()

    def update_display(self) -> None:
        """Update the displayed image based on current zoom and pan state.

        - Fit mode: scales the whole original down to fit the viewport.
          Paints immediately with a cheap FastTransformation scale - this
          runs on every selection change, including cache hits, so it must
          never block on a slow smooth resample of a full-resolution
          pixmap - then schedules a one-shot upgrade to SmoothTransformation
          for the final, sharp result (see _schedule_smooth_upgrade). The
          result is never larger than the viewport, so both scales are
          cheap regardless of the original's resolution.
        - Zoomed: crops the needed source region from the original FIRST,
          then scales only that crop to the viewport (see _crop_then_scale).
          Peak allocation stays viewport-sized regardless of zoom level or
          the original image's resolution - scaling the whole original
          before cropping could allocate gigabytes for a large photo at high
          zoom just to display a small visible region.

        If fixed_size is set, constrains the image to fit within that uniform
        size, ensuring all images in a grid have the same display dimensions.
        """
        # Determine the target size to fit within
        target_size = self.fixed_size if self.fixed_size is not None else self.size()

        # Track viewport size for pan adjustment on size changes
        if self.viewport_size is None:
            self.viewport_size = target_size

        if not self.has_valid_image():
            self._show_invalid_image_placeholder()
            return

        if self.fit_mode:
            fast = self.original_pixmap.scaled(
                target_size,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.FastTransformation,
            )
            self.image_label.setPixmap(fast)
            self._schedule_smooth_upgrade(target_size)
        else:
            self.image_label.setPixmap(self._crop_then_scale(target_size))

    def _schedule_smooth_upgrade(self, target_size: QSize) -> None:
        """Schedule a one-shot upgrade from the fast-scaled paint to a smooth one.

        update_display's fit-mode branch paints immediately with a cheap
        FastTransformation scale so a selection change never blocks on a
        slow smooth resample of a full-resolution pixmap, then this fires
        shortly after to redo the same scale with SmoothTransformation for
        the final, sharp result.

        Guards against having become stale by the time it runs: the widget
        may have been torn down (deleteLater only schedules deletion, so the
        underlying C++ object can still vanish before a 0ms timer fires -
        caught as a RuntimeError), fit mode may have been exited, or another
        resize/selection may have already repainted at a different size.

        Args:
            target_size: The viewport size this paint was for.
        """

        def upgrade() -> None:
            try:
                if not self.fit_mode or not self.has_valid_image():
                    return
                current_size = (
                    self.fixed_size if self.fixed_size is not None else self.size()
                )
                if current_size != target_size:
                    return  # a newer paint already handled this size
                smooth = self.original_pixmap.scaled(
                    target_size,
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
                self.image_label.setPixmap(smooth)
            except RuntimeError:
                return  # widget was deleted before this ran

        QTimer.singleShot(0, upgrade)

    def _crop_then_scale(self, target_size: QSize) -> QPixmap:
        """Render the current zoom/pan by cropping the source, then scaling.

        Computes the source region (in original-image pixels) needed to fill
        target_size at the current zoom level, crops just that region from
        original_pixmap, and scales only the crop. Peak allocation is bounded
        by target_size regardless of zoom level or original resolution - a
        24MP image at 400% zoom only ever allocates viewport-sized pixmaps,
        not a 400%-scaled copy of the whole 24MP original.

        Clamping the crop to the image bounds also means pan can never be
        dragged so far that the crop rectangle misses the image entirely -
        the visible region just stops moving once it hits the edge.

        Args:
            target_size: The viewport size to fill.

        Returns:
            A QPixmap sized to fit within target_size (KeepAspectRatio).
        """
        orig_w = self.original_pixmap.width()
        orig_h = self.original_pixmap.height()

        # Source region size needed to fill the viewport at this zoom level,
        # clamped to the image's own bounds (zooming out below 1:1 needs more
        # source pixels than the image actually has).
        src_w = min(orig_w, max(1, math.ceil(target_size.width() / self.zoom_level)))
        src_h = min(orig_h, max(1, math.ceil(target_size.height() / self.zoom_level)))

        # Center of the crop region in original-image pixels: the image's
        # own center, offset by the total pan (synchronized + individual).
        total_pan_x = self.pan_offset.x() + self.individual_pan_offset.x()
        total_pan_y = self.pan_offset.y() + self.individual_pan_offset.y()
        center_x = orig_w / 2 - total_pan_x
        center_y = orig_h / 2 - total_pan_y

        src_x = int(center_x - src_w / 2)
        src_y = int(center_y - src_h / 2)

        # Clamp so the crop rectangle always stays within the image bounds.
        src_x = max(0, min(src_x, orig_w - src_w))
        src_y = max(0, min(src_y, orig_h - src_h))

        crop = self.original_pixmap.copy(QRect(src_x, src_y, src_w, src_h))

        return crop.scaled(
            target_size,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation,
        )

    def _show_invalid_image_placeholder(self) -> None:
        """Display a placeholder for a file that failed to decode.

        Shows the filename instead of a pixmap, so a corrupt/truncated JPEG
        is visibly distinct from a loading image rather than a blank or
        garbled tile.
        """
        self.image_label.setPixmap(QPixmap())
        self.image_label.setText(f"Unable to load image:\n{self.path.name}")

    def _zoom_to_point(
        self,
        new_zoom: float,
        cursor_x: float,
        cursor_y: float,
        individual: bool = False,
    ) -> None:
        """Zoom to new_zoom level, keeping the cursor point fixed in the viewport.

        Handles both fit mode (uses actual display scale as old_zoom) and explicit
        zoom mode. Updates pan_offset (synchronized) or individual_pan_offset
        (individual), then calls set_zoom.

        Args:
            new_zoom: Target zoom level (fraction of original image size).
            cursor_x: X position of cursor in widget coordinates.
            cursor_y: Y position of cursor in widget coordinates.
            individual: If True, adjust individual_pan_offset only and suppress signals.
        """
        target_size = self.fixed_size if self.fixed_size is not None else self.size()

        if self.fit_mode and self.has_valid_image():
            old_zoom = min(
                target_size.width() / self.original_pixmap.width(),
                target_size.height() / self.original_pixmap.height(),
            )
        else:
            old_zoom = self.zoom_level

        if old_zoom != new_zoom and old_zoom > 0:
            # Offset of cursor from viewport center (in viewport pixels)
            cursor_offset_x = cursor_x - (target_size.width() / 2)
            cursor_offset_y = cursor_y - (target_size.height() / 2)

            # Pan delta to keep the cursor point fixed (in original image pixels)
            delta_x = cursor_offset_x / old_zoom - cursor_offset_x / new_zoom
            delta_y = cursor_offset_y / old_zoom - cursor_offset_y / new_zoom

            if individual:
                self.individual_pan_offset = QPoint(
                    int(self.individual_pan_offset.x() + delta_x),
                    int(self.individual_pan_offset.y() + delta_y),
                )
            else:
                self.pan_offset = QPoint(
                    int(self.pan_offset.x() + delta_x),
                    int(self.pan_offset.y() + delta_y),
                )
                if self.synchronized:
                    self.pan_changed.emit(self.pan_offset.x(), self.pan_offset.y())

        self.set_zoom(new_zoom, emit_signal=not individual)

    def wheelEvent(self, event: QWheelEvent) -> None:  # noqa: N802
        """Handle mouse wheel for zoom.

        Scroll up zooms in to next stop, scroll down zooms out to previous stop.
        Uses standard zoom stops: 10%, 25%, 33%, 50%, 67%, 75%, 100%, 150%, 200%, 300%, 400%

        The zoom is centered on the mouse cursor position, keeping the point under
        the cursor fixed as the zoom changes.

        Args:
            event: The wheel event containing scroll direction and position.
        """
        if not self.has_valid_image():
            return

        # Get current zoom as percentage
        if self.fit_mode:
            # Calculate actual fit percentage from viewport and original image size
            target_size = (
                self.fixed_size if self.fixed_size is not None else self.size()
            )
            scale_w = target_size.width() / self.original_pixmap.width()
            scale_h = target_size.height() / self.original_pixmap.height()
            current_percentage = int(min(scale_w, scale_h) * 100)
        else:
            current_percentage = int(self.zoom_level * 100)

        # Determine zoom direction
        delta = event.angleDelta().y()
        direction = 1 if delta > 0 else -1

        # Find next zoom stop
        if direction > 0:
            # Zoom in: find next higher stop
            new_zoom = ZOOM_STOPS_PERCENT[-1] / 100.0  # Default to max
            for stop in ZOOM_STOPS_PERCENT:
                if stop > current_percentage:
                    new_zoom = stop / 100.0
                    break
        else:
            # Zoom out: find next lower stop
            new_zoom = ZOOM_STOPS_PERCENT[0] / 100.0  # Default to min
            for stop in reversed(ZOOM_STOPS_PERCENT):
                if stop < current_percentage:
                    new_zoom = stop / 100.0
                    break

        mouse_pos = event.position()
        self._zoom_to_point(new_zoom, mouse_pos.x(), mouse_pos.y())

    def event(self, event: QEvent) -> bool:  # noqa: N802
        """Override event() to intercept gesture events.

        Args:
            event: The event to process.

        Returns:
            True if the event was handled, False otherwise.
        """
        if event.type() == QEvent.Type.Gesture:
            return self.gestureEvent(event)
        return super().event(event)

    def gestureEvent(self, event: QGestureEvent) -> bool:  # noqa: N802
        """Handle gesture events for pinch-to-zoom.

        Args:
            event: The gesture event to process.

        Returns:
            True if the gesture was handled, False otherwise.
        """
        gesture = event.gesture(Qt.GestureType.PinchGesture)
        if gesture:
            return self.pinch_triggered(gesture)
        return False

    def pinch_triggered(self, gesture: QPinchGesture) -> bool:
        """Handle pinch gesture for trackpad zoom.

        Args:
            gesture: The pinch gesture containing scale and center point.

        Returns:
            True if the gesture was handled.
        """
        if gesture.state() == Qt.GestureState.GestureUpdated:
            if not self.has_valid_image():
                return True

            # Get scale factor (relative change since last update)
            scale_factor = gesture.scaleFactor()

            # Calculate new zoom level from actual current display scale
            if self.fit_mode:
                target_size = (
                    self.fixed_size if self.fixed_size is not None else self.size()
                )
                scale_w = target_size.width() / self.original_pixmap.width()
                scale_h = target_size.height() / self.original_pixmap.height()
                current_zoom = min(scale_w, scale_h)
            else:
                current_zoom = self.zoom_level
            new_zoom = current_zoom * scale_factor

            # Snap to nearest standard zoom stop for cleaner feel
            zoom_stops = [p / 100.0 for p in ZOOM_STOPS_PERCENT]
            new_zoom = min(zoom_stops, key=lambda x: abs(x - new_zoom))

            # Clamp to valid range
            new_zoom = max(zoom_stops[0], min(zoom_stops[-1], new_zoom))

            center_point = gesture.centerPoint()
            self._zoom_to_point(new_zoom, center_point.x(), center_point.y())

        return True

    def mousePressEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Start panning on left button press.

        Special behaviors:
        - Ctrl+click: Remove from comparison (no panning)
        - Shift+drag: Pan only this image (individual pan offset)
        - Normal drag: Pan all synchronized images together

        Args:
            event: The mouse event containing button and position info.
        """
        if event.button() == Qt.MouseButton.LeftButton:
            # Check for Ctrl modifier (for removal from comparison)
            self.is_ctrl_click = bool(
                event.modifiers() & Qt.KeyboardModifier.ControlModifier
            )

            # If Ctrl is pressed, don't start panning
            if self.is_ctrl_click:
                return

            self.last_mouse_pos = event.pos()
            # Check if Shift key is pressed for individual panning
            self.is_shift_panning = bool(
                event.modifiers() & Qt.KeyboardModifier.ShiftModifier
            )

    def mouseMoveEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Handle panning during mouse drag.

        If Shift key was pressed on mouse down, pan only this image individually.
        Otherwise, pan all synchronized images together.

        Args:
            event: The mouse event containing current position.
        """
        if self.fit_mode:
            # Fit-mode display ignores pan entirely; skip accumulation so a
            # drag while fitted doesn't build up a stale pan_offset that
            # would corrupt the next zoom-to-cursor or synced tiles.
            return

        if self.last_mouse_pos is not None:
            delta = event.pos() - self.last_mouse_pos
            self.last_mouse_pos = event.pos()

            # Convert viewport delta to original-image delta
            # pan_offset is in original image pixels, so divide by zoom
            delta_in_original_x = delta.x() / self.zoom_level
            delta_in_original_y = delta.y() / self.zoom_level

            if self.is_shift_panning:
                # Shift panning: update individual offset only (no sync signal)
                self.individual_pan_offset += QPoint(
                    int(delta_in_original_x), int(delta_in_original_y)
                )
            else:
                # Normal panning: update synchronized offset
                self.pan_offset += QPoint(
                    int(delta_in_original_x), int(delta_in_original_y)
                )
                if self.synchronized:
                    self.pan_changed.emit(self.pan_offset.x(), self.pan_offset.y())

            self.update_display()

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Stop panning on left button release.

        If Ctrl was pressed on mouse down, emit signal to remove from comparison.

        Args:
            event: The mouse event containing button info.
        """
        if event.button() == Qt.MouseButton.LeftButton:
            # If this was a Ctrl+click, emit removal signal
            if self.is_ctrl_click:
                self.remove_from_comparison.emit()
                self.is_ctrl_click = False
                return

            self.last_mouse_pos = None
            self.is_shift_panning = False

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Toggle between fit mode and 100% zoom centered on the click point.

        Double-click from fit mode zooms to 100% at the click point.
        Double-click when zoomed returns to fit mode.
        Shift modifier makes the action affect only this widget (no sync signals).
        Ctrl modifier is ignored (Ctrl+click removes from comparison).

        Args:
            event: The mouse event containing button, position, and modifiers.
        """
        if event.button() != Qt.MouseButton.LeftButton:
            return
        if event.modifiers() & Qt.KeyboardModifier.ControlModifier:
            return

        shift_held = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)
        pos = event.position()

        if self.fit_mode:
            self._zoom_to_point(1.0, pos.x(), pos.y(), individual=shift_held)
        else:
            self.set_fit_mode(True, emit_signal=not shift_held)

    def set_zoom(self, zoom_level: float, emit_signal: bool = True) -> None:
        """Set zoom level programmatically.

        Any explicit zoom call exits fit mode. Used for synchronization.

        Args:
            zoom_level: New zoom level (0.1 to 4.0).
            emit_signal: If True, emit zoom_changed signal.
        """
        self.zoom_level = zoom_level
        self.fit_mode = False  # Any explicit zoom exits fit mode
        self.update_display()

        if emit_signal:
            # Emit regardless of `synchronized`: ViewingArea listens to this
            # even for a single (unsynchronized) image, to keep the zoom%
            # overlay label in sync with wheel/pinch/double-click zoom.
            # `synchronized` only gates SynchronizedViewController's
            # cross-widget broadcast, not this emission; `emit_signal=False`
            # (used by that broadcast) is what actually prevents feedback
            # loops.
            self.zoom_changed.emit(zoom_level)

    def set_fit_mode(self, fit: bool, emit_signal: bool = True) -> None:
        """Enter or exit fit-to-widget mode.

        In fit mode, the image is scaled to fill the viewport while preserving
        aspect ratio. zoom_level is ignored for display in fit mode.

        Args:
            fit: True to enter fit mode, False to use explicit zoom_level.
            emit_signal: If True, emit fit_mode_changed signal (if synchronized).
        """
        self.fit_mode = fit
        if fit:
            # Fit-mode display ignores pan entirely, so the displayed pan is
            # always 0 while fitted. Zero the stored offsets too, otherwise a
            # later zoom-to-cursor uses this stale pan as its base (wrong
            # center point) and any leftover value gets broadcast to synced
            # comparison tiles.
            self.pan_offset = QPoint(0, 0)
            self.individual_pan_offset = QPoint(0, 0)
        self.update_display()

        if emit_signal and self.synchronized:
            self.fit_mode_changed.emit(fit)

    def set_pan(self, offset_x: int, offset_y: int, emit_signal: bool = True) -> None:
        """Set pan offset programmatically.

        Used for synchronization - allows setting pan without re-emitting signals.

        Args:
            offset_x: Horizontal pan offset in pixels.
            offset_y: Vertical pan offset in pixels.
            emit_signal: If True, emit pan_changed signal (if synchronized).
        """
        self.pan_offset = QPoint(offset_x, offset_y)
        self.update_display()

        if emit_signal and self.synchronized:
            self.pan_changed.emit(offset_x, offset_y)

    def set_individual_pan(self, offset_x: int, offset_y: int) -> None:
        """Set this tile's individual pan offset programmatically and repaint.

        Unlike pan_offset, the individual offset is never broadcast to other
        synchronized tiles (see the coordinate-system note above) - it
        exists to register a single mismatched shot against its peers
        without disturbing the group's shared view.

        Args:
            offset_x: Horizontal individual pan offset, in original-image
                pixels.
            offset_y: Vertical individual pan offset, in original-image
                pixels.
        """
        self.individual_pan_offset = QPoint(offset_x, offset_y)
        self.update_display()

    def adjust_pan_for_viewport_change(self, new_viewport_size: QSize) -> None:
        """Adjust pan offset to maintain visual center when viewport size changes.

        When the viewport size changes (e.g., from grid layout changes), the same
        pan offset will produce a different visual result. This method recalculates
        the pan offset to keep the same point centered in the new viewport.

        The math:
        - In old viewport: visual_center = old_viewport_center + pan_offset * zoom
        - We want: visual_center = new_viewport_center + new_pan_offset * zoom
        - Therefore: new_pan_offset = (visual_center - new_viewport_center) / zoom

        Args:
            new_viewport_size: The new viewport size to adjust for.
        """
        # Only adjust if we have a previous viewport size and are not in fit mode
        if self.viewport_size is None or self.fit_mode:
            self.viewport_size = new_viewport_size
            return

        # Calculate the visual center point in the old viewport (in scaled image coords)
        old_center_x = self.viewport_size.width() / 2
        old_center_y = self.viewport_size.height() / 2

        # Calculate the new viewport center
        new_center_x = new_viewport_size.width() / 2
        new_center_y = new_viewport_size.height() / 2

        # Calculate the change in viewport center (in viewport coordinates)
        delta_center_x = new_center_x - old_center_x
        delta_center_y = new_center_y - old_center_y

        # Convert viewport delta to original image delta
        # Since pan_offset is in original image coordinates, we divide by zoom
        delta_pan_x = delta_center_x / self.zoom_level
        delta_pan_y = delta_center_y / self.zoom_level

        # Adjust pan offset to compensate for the viewport center shift
        # We subtract because a larger viewport means less pan is needed
        new_pan_x = self.pan_offset.x() - int(delta_pan_x)
        new_pan_y = self.pan_offset.y() - int(delta_pan_y)

        self.pan_offset = QPoint(new_pan_x, new_pan_y)
        self.viewport_size = new_viewport_size

    def set_focused(self, focused: bool) -> None:
        """Show or hide the comparison focus ring on this tile.

        Args:
            focused: True to draw the ring, False to clear it.
        """
        if focused == self._focused:
            return
        self._focused = focused
        color = "#FFC107" if focused else "transparent"
        self.setStyleSheet(f"ImageWidget {{ border: 3px solid {color}; }}")

    def set_position_number(self, n: int) -> None:
        """Show a position number in the top-right corner for comparison mode shortcuts.

        Args:
            n: Position number to display (1-indexed).
        """
        self.position_label.setText(str(n))
        self.position_label.show()
        self._reposition_position_label()
        self.position_label.raise_()

    def _reposition_position_label(self) -> None:
        """Update position label location to stay at top-right corner."""
        x = self.width() - self.position_label.width() - 10
        self.position_label.move(max(0, x), 10)

    def _relay_mark_request(self, status: PhotoStatus) -> None:
        """Forward an overlay mark request, tagged with this widget's path."""
        self.mark_requested.emit(self.path, status)

    def resizeEvent(self, event) -> None:  # noqa: N802, ANN001
        """Handle widget resize.

        Updates display to fit the new widget size.

        Args:
            event: The resize event.
        """
        super().resizeEvent(event)
        self.update_display()
        if self.position_label.isVisible():
            self._reposition_position_label()


class StatusOverlay(QWidget):
    """Semi-transparent overlay widget with status marking buttons.

    Displays three buttons (keep, reject, clear) in the top-left corner
    of the image for quick status marking. The active button is highlighted
    with a colored background.

    The overlay never mutates the session itself: buttons emit mark_requested
    and the keyboard controller applies the mark, so overlay clicks and key
    presses share one marking pipeline.

    Signals:
        mark_requested(PhotoStatus): Emitted when a button asks for a status.
    """

    mark_requested = Signal(PhotoStatus)

    def __init__(self, path: Path, session: Session) -> None:
        """Initialize the StatusOverlay.

        Args:
            path: Path to the photo this overlay controls.
            session: Session object for status tracking.
        """
        super().__init__()
        self.path = path
        self.session = session

        self.setup_ui()
        self.update_appearance()

    def setup_ui(self) -> None:
        """Build the overlay UI with three status buttons."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(5, 5, 5, 5)
        layout.setSpacing(5)

        # NoFocus on all three: Space is the keep shortcut and must never
        # double as "click the focused button".
        # Keeper button
        self.btn_keeper = QPushButton("✓")
        self.btn_keeper.setFixedSize(30, 30)
        self.btn_keeper.setToolTip("Keep (Space)")
        self.btn_keeper.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_keeper.clicked.connect(self.mark_keeper)

        # Delete button
        self.btn_delete = QPushButton("✕")
        self.btn_delete.setFixedSize(30, 30)
        self.btn_delete.setToolTip("Reject (x)")
        self.btn_delete.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_delete.clicked.connect(self.mark_delete)

        # Clear button
        self.btn_clear = QPushButton("−")
        self.btn_clear.setFixedSize(30, 30)
        self.btn_clear.setToolTip("Clear (c)")
        self.btn_clear.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_clear.clicked.connect(self.clear_status)

        layout.addWidget(self.btn_keeper)
        layout.addWidget(self.btn_delete)
        layout.addWidget(self.btn_clear)

        # Set fixed size for the overlay to ensure background renders correctly
        self.setFixedSize(110, 40)

        # Semi-transparent background with styled buttons
        self.setStyleSheet(
            """
            StatusOverlay {
                background-color: rgba(0, 0, 0, 150);
                border-radius: 5px;
            }
            QPushButton {
                background-color: white;
                border: none;
                border-radius: 3px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: #f0f0f0;
            }
        """
        )

    def mark_keeper(self) -> None:
        """Request keeper status for this photo."""
        self.mark_requested.emit(PhotoStatus.KEEPER)

    def mark_delete(self) -> None:
        """Request delete status for this photo."""
        self.mark_requested.emit(PhotoStatus.DELETE)

    def clear_status(self) -> None:
        """Request unmarked status for this photo."""
        self.mark_requested.emit(PhotoStatus.UNMARKED)

    def update_appearance(self) -> None:
        """Update button appearance based on current photo status.

        Highlights the active button with a colored background:
        - Keeper: green (#4CAF50)
        - Delete: red (#F44336)
        - Unmarked: default white
        """
        status = self.session.get_status(self.path)

        # Default button style (white background)
        default_style = """
            background-color: white;
            border: none;
            border-radius: 3px;
            font-weight: bold;
            color: black;
        """

        if status == PhotoStatus.KEEPER:
            self.btn_keeper.setStyleSheet(
                "background-color: #4CAF50; color: white; border: none; "
                "border-radius: 3px; font-weight: bold;"
            )
            self.btn_delete.setStyleSheet(default_style)
            self.btn_clear.setStyleSheet(default_style)
        elif status == PhotoStatus.DELETE:
            self.btn_delete.setStyleSheet(
                "background-color: #F44336; color: white; border: none; "
                "border-radius: 3px; font-weight: bold;"
            )
            self.btn_keeper.setStyleSheet(default_style)
            self.btn_clear.setStyleSheet(default_style)
        else:  # UNMARKED
            self.btn_keeper.setStyleSheet(default_style)
            self.btn_delete.setStyleSheet(default_style)
            self.btn_clear.setStyleSheet(default_style)

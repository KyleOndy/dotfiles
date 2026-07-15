"""MainWindow for the Winnow photo culling application.

This module provides the main application window containing the viewing area
and thumbnail strip widgets, along with session state management.
"""

from pathlib import Path

from PySide6.QtCore import QThreadPool, QTimer
from PySide6.QtGui import QCloseEvent
from PySide6.QtWidgets import (
    QLabel,
    QMainWindow,
    QMessageBox,
    QStatusBar,
    QVBoxLayout,
    QWidget,
)

from winnow.core.image_cache import ImageCache
from winnow.core.scanner import scan_directory
from winnow.core.session import Session
from winnow.core.thumbnailer import Thumbnailer
from winnow.ui.help_overlay import HelpOverlay
from winnow.ui.keyboard_controller import KeyboardController
from winnow.ui.keymap import Mode, legend_text, mode_style
from winnow.ui.thumbnail_strip import ThumbnailStrip
from winnow.ui.viewing_area import ViewingArea


class MainWindow(QMainWindow):
    """Main application window for photo culling.

    This window serves as the primary container for the application, managing:
    - Session initialization and state
    - Layout of ViewingArea (top) and ThumbnailStrip (bottom)
    - Window lifecycle events (close handling)
    """

    def __init__(self, directory: Path, max_memory_mb: float = 24576.0) -> None:
        """Initialize the MainWindow with a photo directory.

        Scans the directory for JPEG files and initializes a new session.

        Args:
            directory: Path to the directory containing JPEG photos to cull.
            max_memory_mb: Soft memory budget (MB) for the full-resolution
                image cache - see ImageCache and the --max-memory CLI flag.
        """
        super().__init__()

        self.max_memory_mb = max_memory_mb

        # Scan directory and initialize session
        images = scan_directory(directory)
        self.session = Session(directory=directory, images=images)

        # Create thumbnailer for generating thumbnails
        self.thumbnailer = Thumbnailer()

        # Set window properties
        self.setWindowTitle(f"Winnow - {directory.name}")
        self.resize(1200, 800)

        # Create central widget with vertical layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Create and add widgets
        self.viewing_area = ViewingArea(self.session)
        self.thumbnail_strip = ThumbnailStrip(self.session, self.thumbnailer)

        # Connect signals
        self.thumbnail_strip.selection_changed.connect(self.viewing_area.set_images)
        # When displayed images change, refresh the memory usage readout
        self.viewing_area.current_images_changed.connect(self._refresh_memory_label)
        # Sync thumbnail selection when viewing area changes (e.g., auto-advance)
        self.viewing_area.current_images_changed.connect(
            self.thumbnail_strip.set_selection
        )

        layout.addWidget(self.viewing_area)
        layout.addWidget(self.thumbnail_strip)

        # Create status bar for displaying memory usage
        self._setup_status_bar()

        # Full-keymap cheat sheet, toggled with ?
        self.help_overlay = HelpOverlay(central_widget)

        # Keyboard-driven culling: shortcuts, marking pipeline, undo
        self.keyboard = KeyboardController(self)
        self.keyboard.mode_changed.connect(self._on_mode_changed)
        self._on_mode_changed(self.keyboard.mode)

        # Initialize image cache after the window is shown. Deferred via
        # QTimer so the window paints first.
        QTimer.singleShot(0, self._start_image_loading)

    def _setup_status_bar(self) -> None:
        """Create the status bar: mode badge, key legend left, memory right."""
        status_bar = QStatusBar()
        self.setStatusBar(status_bar)

        # Colored SELECT/COMPARE/VISUAL badge; styled by _on_mode_changed
        # whenever the keyboard mode changes.
        self.mode_badge = QLabel()
        status_bar.addWidget(self.mode_badge)

        # Context-sensitive key legend; content set by _on_mode_changed
        # whenever the keyboard mode changes. Transient showMessage
        # notices ("pass complete") temporarily cover both and auto-restore.
        self.legend_label = QLabel()
        status_bar.addWidget(self.legend_label)

        # Memory usage label (permanent widget on the right)
        self.memory_label = QLabel("Memory: 0 MB")
        status_bar.addPermanentWidget(self.memory_label)

    def _on_mode_changed(self, mode: Mode) -> None:
        """Refresh every mode-driven presentation: badge, legend, frame.

        Args:
            mode: The mode to reflect in the UI.
        """
        self.legend_label.setText(legend_text(mode))
        style = mode_style(mode)
        self.mode_badge.setText(f" {style.label} ")
        self.mode_badge.setStyleSheet(
            f"background-color: {style.color}; color: white; "
            "font-weight: bold; border-radius: 4px; padding: 1px 6px;"
        )
        self.viewing_area.set_mode_frame(mode)

    def _start_image_loading(self) -> None:
        """Create the bounded image cache once the window is visible.

        The cache holds every image decoded so far, up to max_memory_mb,
        evicting least-recently-used entries once over budget (see
        ImageCache) - there is no bulk preload, but there's no eager
        eviction either, so revisiting a photo is a cache hit.
        """
        # Skip if there are no images
        if not self.session.images:
            return

        # Skip in test environments, which never show the window. Tests then
        # run without a cache, using ImageWidget's synchronous on-demand
        # decode instead - this keeps test behavior simple and deterministic.
        if not self.isVisible():
            return

        self.session.image_cache = ImageCache(
            max_threads=6, max_memory_mb=self.max_memory_mb, parent=self
        )
        self.session.image_cache.image_ready.connect(self._refresh_memory_label)
        self.session.image_cache.image_ready.connect(self.viewing_area.on_image_ready)
        self.session.image_cache.load_failed.connect(
            self.viewing_area.on_image_load_failed
        )

    def _refresh_memory_label(self, *_args: object) -> None:
        """Update the status bar's memory usage readout from the cache.

        Connected to both ImageCache.image_ready (Path) and
        ViewingArea.current_images_changed (list) - accepts and ignores
        whatever argument the sender passes, since only the current memory
        total matters here.
        """
        if self.session.image_cache is not None:
            memory_mb = self.session.image_cache.get_memory_usage_mb()
            self.memory_label.setText(f"Memory: {memory_mb:.1f} MB")

    def resizeEvent(self, event) -> None:  # noqa: N802, ANN001
        """Keep the help overlay covering the central area on resize."""
        super().resizeEvent(event)
        if self.help_overlay.isVisible():
            self.help_overlay.setGeometry(self.centralWidget().rect())

    def closeEvent(self, event: QCloseEvent) -> None:  # noqa: N802
        """Handle window close with a quit confirmation when marks exist.

        Any mark - keeper or delete - triggers the confirmation, because
        the session is ephemeral: keeper and other non-delete marks are
        always lost on quit. Pending deletes are only applied if the user
        picks Yes; Discard quits without touching disk; No keeps the
        window open. A session with no marks closes silently.

        On an accepted close, background image and thumbnail loading are
        stopped and drained before teardown or file deletion - a worker
        thread emitting into an ImageCache or Thumbnailer mid-teardown
        would otherwise fire into an object being deleted.

        Args:
            event: The close event to accept or ignore.
        """
        keeper_count = len(self.session.keepers)
        delete_count = self.session.count_deletes()
        raw_count = self.session.count_raw_deletes()

        apply_deletes = True
        if keeper_count > 0 or delete_count > 0:
            delete_text = (
                f"{delete_count} deletes (+{raw_count} RAW)"
                if raw_count > 0
                else f"{delete_count} deletes"
            )
            reply = QMessageBox.question(
                self,
                "Confirm Quit",
                f"{keeper_count} keepers, {delete_text} marked. "
                "Yes deletes the marked photos and quits; Discard quits "
                "without deleting anything; other marks are lost either way.",
                QMessageBox.StandardButton.Yes
                | QMessageBox.StandardButton.Discard
                | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,  # Default to No for safety
            )
            if reply == QMessageBox.StandardButton.No:
                event.ignore()
                return
            apply_deletes = reply == QMessageBox.StandardButton.Yes

        # Stop background image loading and wait for in-flight decodes to
        # finish before any further teardown or file deletion below.
        if self.session.image_cache is not None:
            self.session.image_cache.set_active_images(set())
            QThreadPool.globalInstance().waitForDone()
        self.thumbnailer.wait_for_pending()

        if delete_count > 0 and apply_deletes:
            # Attempt deletion
            failed = self.session.delete_marked_files()

            # Report failures if any
            if failed:
                import sys

                for path in failed:
                    print(f"Failed to delete: {path}", file=sys.stderr)

        event.accept()

"""ViewingArea widget for displaying selected photos.

This module provides the top viewing area widget where selected photos are displayed.
Currently a placeholder, will be extended to show single photos and comparison grids.
"""

from pathlib import Path

from PySide6.QtCore import QPoint, QSize, Qt, Signal
from PySide6.QtWidgets import QGridLayout, QHBoxLayout, QLabel, QPushButton, QWidget

from winnow.core.session import PhotoStatus, Session
from winnow.ui.image_widget import ZOOM_STOPS_PERCENT, ImageWidget
from winnow.ui.keymap import Mode, mode_style

# Background-decode this many neighbors on each side of a single selection,
# so sequential culling (arrow-key navigation) stays a cache hit in either
# direction. Generous now that ImageCache is a large-budget LRU rather than
# an evict-everything-else cache (see ImageCache.max_memory_mb).
PREFETCH_RADIUS = 8

# Fraction of the viewport one keyboard pan step reveals, so a press covers
# the same visual distance at any zoom level.
PAN_STEP_FRACTION = 0.15

# Individual-tile alignment nudges are much finer than group panning - they
# register a mismatched shot against its peers rather than roam a zoomed
# photo.
ALIGN_STEP_FRACTION = 0.025


def _pan_delta(
    widget: ImageWidget, dx: int, dy: int, fraction: float
) -> tuple[int, int]:
    """Compute a pan delta, in original-image pixels, for one keyboard step.

    Args:
        widget: The widget the step is sized against (its viewport and
            zoom level).
        dx: -1 to reveal content to the left, +1 to reveal content to the
            right, 0 for no horizontal movement.
        dy: -1 to reveal content above, +1 to reveal content below, 0 for
            no vertical movement.
        fraction: Fraction of the viewport one step should reveal.

    Returns:
        (delta_x, delta_y) to add to a pan offset. Revealing content in a
        direction shifts the crop window that way (see the center = orig/2
        - pan math in ImageWidget._crop_then_scale), which means the
        offset itself moves opposite dx/dy.
    """
    target_size = widget.fixed_size if widget.fixed_size is not None else widget.size()
    step_x = fraction * target_size.width() / widget.zoom_level
    step_y = fraction * target_size.height() / widget.zoom_level
    return (-round(dx * step_x), -round(dy * step_y))


class SynchronizedViewController:
    """Manages synchronized zoom and pan across multiple ImageWidgets.

    Tracks multiple ImageWidget instances and broadcasts zoom/pan changes
    to all widgets except the sender to prevent feedback loops.
    """

    def __init__(self) -> None:
        """Initialize with empty widget list."""
        self.widgets: list[ImageWidget] = []

    def add_widget(self, widget: ImageWidget) -> None:
        """Add widget to synchronization group and connect signals.

        Args:
            widget: ImageWidget to add to synchronized group.
        """
        self.widgets.append(widget)
        widget.zoom_changed.connect(lambda level: self.on_zoom_changed(widget, level))
        widget.pan_changed.connect(lambda x, y: self.on_pan_changed(widget, x, y))
        widget.fit_mode_changed.connect(
            lambda fit: self.on_fit_mode_changed(widget, fit)
        )

    def clear(self) -> None:
        """Clear all tracked widgets."""
        self.widgets.clear()

    def on_zoom_changed(self, sender: ImageWidget, zoom_level: float) -> None:
        """Broadcast zoom change to all widgets except sender.

        Args:
            sender: Widget that initiated the zoom change.
            zoom_level: New zoom level to apply.
        """
        for widget in self.widgets:
            if widget is not sender:
                widget.set_zoom(zoom_level, emit_signal=False)

    def on_pan_changed(self, sender: ImageWidget, offset_x: int, offset_y: int) -> None:
        """Broadcast pan change to all widgets except sender.

        Args:
            sender: Widget that initiated the pan change.
            offset_x: Horizontal pan offset.
            offset_y: Vertical pan offset.
        """
        for widget in self.widgets:
            if widget is not sender:
                widget.set_pan(offset_x, offset_y, emit_signal=False)

    def on_fit_mode_changed(self, sender: ImageWidget, fit: bool) -> None:
        """Broadcast fit mode change to all widgets except sender.

        Args:
            sender: Widget that initiated the fit mode change.
            fit: New fit mode state.
        """
        for widget in self.widgets:
            if widget is not sender:
                widget.set_fit_mode(fit, emit_signal=False)


class ZoomControlOverlay(QWidget):
    """Semi-transparent overlay with zoom control buttons.

    Displays zoom controls in a horizontal layout:
    - "-": Zoom out to previous standard stop
    - "+": Zoom in to next standard stop
    - Zoom level indicator (e.g., "100%")
    - "100%": Zoom to 1:1 pixel ratio (actual size)
    - "Fit": Reset zoom to fit-to-widget mode (zoom_level = 1.0)

    Standard zoom stops: 10%, 25%, 33%, 50%, 67%, 75%, 100%, 150%, 200%, 300%, 400%
    Positioned at bottom-right corner of ViewingArea.
    """

    # Standard zoom stops (as percentages) - shared with ImageWidget's wheel
    # and pinch zoom handling, see ZOOM_STOPS_PERCENT in image_widget.py.
    ZOOM_STOPS = ZOOM_STOPS_PERCENT

    def __init__(self, viewing_area: "ViewingArea") -> None:
        """Initialize the ZoomControlOverlay.

        Args:
            viewing_area: Parent ViewingArea for accessing image widgets.
        """
        super().__init__()
        self.viewing_area = viewing_area

        self.setup_ui()

    def setup_ui(self) -> None:
        """Build the overlay UI with zoom control buttons and level indicator."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        # NoFocus on all zoom buttons: Tab must never park focus here where
        # Space/Enter would trigger a zoom instead of the mark shortcut.
        # Zoom out button
        self.btn_zoom_out = QPushButton("-")
        self.btn_zoom_out.setFixedSize(36, 36)
        self.btn_zoom_out.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_zoom_out.clicked.connect(self.on_zoom_out)

        # Zoom in button
        self.btn_zoom_in = QPushButton("+")
        self.btn_zoom_in.setFixedSize(36, 36)
        self.btn_zoom_in.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_zoom_in.clicked.connect(self.on_zoom_in)

        # Zoom level label
        self.zoom_label = QLabel("100%")
        self.zoom_label.setFixedSize(60, 36)
        self.zoom_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.zoom_label.setStyleSheet(
            """
            color: white;
            font-weight: bold;
            font-size: 12px;
            background-color: transparent;
        """
        )

        # Zoom to 100% button
        self.btn_zoom_100 = QPushButton("100%")
        self.btn_zoom_100.setFixedSize(50, 36)
        self.btn_zoom_100.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_zoom_100.clicked.connect(self.on_zoom_to_100)

        # Zoom to fit button
        self.btn_zoom_fit = QPushButton("Fit")
        self.btn_zoom_fit.setFixedSize(50, 36)
        self.btn_zoom_fit.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.btn_zoom_fit.clicked.connect(self.on_zoom_to_fit)

        layout.addWidget(self.btn_zoom_out)
        layout.addWidget(self.btn_zoom_in)
        layout.addWidget(self.zoom_label)
        layout.addWidget(self.btn_zoom_100)
        layout.addWidget(self.btn_zoom_fit)

        # Set fixed size for the overlay
        self.setFixedSize(268, 52)

        # Semi-transparent background with styled buttons - more visible
        self.setStyleSheet(
            """
            ZoomControlOverlay {
                background-color: rgba(0, 0, 0, 180);
                border-radius: 6px;
                border: 1px solid rgba(255, 255, 255, 0.3);
            }
            QPushButton {
                background-color: white;
                border: 1px solid #ccc;
                border-radius: 4px;
                font-weight: bold;
                font-size: 12px;
                color: #333;
            }
            QPushButton:hover {
                background-color: #e8e8e8;
                border-color: #999;
            }
            QPushButton:pressed {
                background-color: #d0d0d0;
            }
        """
        )

    def get_fit_percentage(self) -> float:
        """Calculate the percentage when image is fitted to widget (zoom_level=1.0).

        This is the base percentage that zoom_level multiplies against.

        Returns:
            Float percentage of original size when fitted (e.g., 50.0 for 50%).
        """
        if not self.viewing_area.image_widgets:
            return 100.0

        widget = self.viewing_area.image_widgets[0]
        if not widget.has_valid_image():
            return 100.0
        original_size = widget.original_pixmap.size()
        target_size = widget.fixed_size if widget.fixed_size else widget.size()

        # Calculate how much the image is scaled when fitted
        scale_w = target_size.width() / original_size.width()
        scale_h = target_size.height() / original_size.height()
        fit_scale = min(scale_w, scale_h)  # KeepAspectRatio uses minimum

        return fit_scale * 100.0

    def calculate_actual_zoom_percentage(self) -> int:
        """Calculate the actual display percentage relative to original image size.

        Returns:
            Integer percentage of original image size currently displayed.
        """
        if not self.viewing_area.image_widgets:
            return 100

        widget = self.viewing_area.image_widgets[0]

        if widget.fit_mode:
            return int(self.get_fit_percentage())
        else:
            return int(widget.zoom_level * 100)

    def actual_percentage_to_zoom_level(self, percentage: float) -> float:
        """Convert an actual display percentage to a zoom_level value.

        Args:
            percentage: Desired actual percentage (e.g., 100.0 for 1:1 pixel ratio)

        Returns:
            Zoom level that achieves this percentage.
        """
        return percentage / 100.0

    def update_zoom_label(self) -> None:
        """Update the zoom level label to show actual display percentage."""
        percentage = self.calculate_actual_zoom_percentage()
        self.zoom_label.setText(f"{percentage}%")

    def get_next_zoom_stop(self, current_percentage: int, direction: int) -> float:
        """Get the next zoom stop in the given direction.

        Args:
            current_percentage: Current zoom as integer percentage (e.g., 75 for 75%)
            direction: +1 for zoom in (next higher), -1 for zoom out (next lower)

        Returns:
            Zoom level value that achieves the next stop percentage
        """
        if direction > 0:
            # Zoom in: find next higher stop
            for stop in self.ZOOM_STOPS:
                if stop > current_percentage:
                    # Convert stop percentage to zoom_level
                    return self.actual_percentage_to_zoom_level(float(stop))
            # Max zoom - convert 400% to zoom_level
            return self.actual_percentage_to_zoom_level(float(self.ZOOM_STOPS[-1]))
        else:
            # Zoom out: find next lower stop
            for stop in reversed(self.ZOOM_STOPS):
                if stop < current_percentage:
                    # Convert stop percentage to zoom_level
                    return self.actual_percentage_to_zoom_level(float(stop))
            # Min zoom - convert 10% to zoom_level
            return self.actual_percentage_to_zoom_level(float(self.ZOOM_STOPS[0]))

    def on_zoom_in(self) -> None:
        """Handle zoom in button click - zoom to next standard stop."""
        current_percentage = self.calculate_actual_zoom_percentage()
        new_zoom = self.get_next_zoom_stop(current_percentage, direction=1)

        # Apply zoom to all widgets
        for widget in self.viewing_area.image_widgets:
            widget.set_zoom(new_zoom, emit_signal=False)

        self.update_zoom_label()

    def on_zoom_out(self) -> None:
        """Handle zoom out button click - zoom to previous standard stop."""
        current_percentage = self.calculate_actual_zoom_percentage()
        new_zoom = self.get_next_zoom_stop(current_percentage, direction=-1)

        # Apply zoom to all widgets
        for widget in self.viewing_area.image_widgets:
            widget.set_zoom(new_zoom, emit_signal=False)

        self.update_zoom_label()

    def on_zoom_to_100(self) -> None:
        """Handle 100% button click - zoom to 1:1 pixel ratio."""
        if not self.viewing_area.image_widgets:
            return

        # Apply zoom to all widgets (emit_signal=False to prevent sync loops)
        for widget in self.viewing_area.image_widgets:
            widget.set_zoom(1.0, emit_signal=False)

        self.update_zoom_label()

    def on_zoom_to_fit(self) -> None:
        """Handle Fit button click - enter fit-to-widget mode."""
        for widget in self.viewing_area.image_widgets:
            widget.set_fit_mode(True, emit_signal=False)

        self.update_zoom_label()


class ViewingArea(QWidget):
    """Viewing area widget for displaying selected photos.

    Currently shows an empty state message when no photos are selected.
    Will be extended in future tasks to:
    - Display single selected photos with zoom/pan controls
    - Show multiple photos in synchronized comparison grid

    Signals:
        mark_requested(Path, PhotoStatus): An overlay button asked for a
            status; the keyboard controller applies it.
        current_images_changed(list): Emitted when displayed images change (list of Paths).
    """

    mark_requested = Signal(Path, PhotoStatus)
    current_images_changed = Signal(list)

    def __init__(self, session: Session) -> None:
        """Initialize the ViewingArea with grid layout and empty state.

        Args:
            session: Session object for photo state management.
        """
        super().__init__()

        self.session = session
        self.image_widgets: list[ImageWidget] = []
        self.sync_controller = SynchronizedViewController()
        self.focused_index: int = 0

        # Reserve constant room for the mode frame (see set_mode_frame) so
        # toggling it never reflows the grid, and enable stylesheet
        # backgrounds - a plain QWidget subclass won't render stylesheet
        # borders without WA_StyledBackground (same pattern as ImageWidget's
        # focus ring, see image_widget.py's setup_ui).
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)

        # Grid layout for future single/multi-image display
        layout = QGridLayout(self)
        layout.setContentsMargins(3, 3, 3, 3)
        layout.setSpacing(2)

        # Empty state message
        self.empty_label = QLabel("Select photos from thumbnails below")
        self.empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.empty_label, 0, 0)

        # Zoom control overlay (positioned at bottom-right)
        self.zoom_overlay = ZoomControlOverlay(self)
        self.zoom_overlay.setParent(self)
        self.zoom_overlay.hide()  # Hidden until images displayed

    def set_mode_frame(self, mode: Mode) -> None:
        """Tint the viewing-area border to match the current keyboard mode.

        Paired with MainWindow's status-bar mode badge (both driven by
        mode_style) so a live VISUAL span and a committed COMPARE grid -
        otherwise identical, a grid with an amber focus ring - are
        distinguishable at a glance.

        Args:
            mode: The mode to reflect in the frame color.
        """
        color = "transparent" if mode is Mode.SINGLE else mode_style(mode).color
        self.setStyleSheet(f"ViewingArea {{ border: 3px solid {color}; }}")

    def clear_widgets(self) -> None:
        """Clear all currently displayed image widgets.

        Removes all widgets from the layout and schedules them for deletion.
        Also clears the synchronization controller. The empty label is removed
        from layout if present to allow image widgets to occupy grid positions.
        """
        # Remove empty label from layout if present
        if self.layout().indexOf(self.empty_label) >= 0:
            self.layout().removeWidget(self.empty_label)

        # Clear all image widgets
        for widget in self.image_widgets:
            self.layout().removeWidget(widget)
            widget.deleteLater()
        self.image_widgets.clear()
        self.sync_controller.clear()

    def _neighbor_paths(self, path: Path, radius: int) -> set[Path]:
        """Return up to `radius` neighbors on each side of path.

        Neighbors are taken from the current filtered image order, so
        prefetching follows the same sequence as arrow-key navigation.

        Args:
            path: The currently selected image.
            radius: How many images on each side to include.

        Returns:
            Set of neighboring paths (excludes `path` itself). Empty if
            `path` isn't in the filtered list.
        """
        images = self.session.filtered_images()
        if path not in images:
            return set()

        index = images.index(path)
        lo = max(0, index - radius)
        hi = min(len(images), index + radius + 1)
        neighbors = images[lo:hi]
        neighbors.remove(path)
        return set(neighbors)

    def calculate_grid_layout(self, count: int) -> list[tuple[int, int]]:
        """Calculate grid positions for displaying multiple photos.

        Implements fixed layout rules for comparison mode:
        - 0 photos: empty list
        - 1 photo: single position at (0, 0)
        - 2 photos: 1x2 horizontal layout
        - 3 photos: 1x3 horizontal layout
        - 4 photos: 2x2 grid layout (centered as 2x2)
        - 5+ photos: dynamic grid with rows of 3, with incomplete rows centered

        For grids with incomplete final rows, the items are centered by offsetting
        their column positions. For example:
        - 7 photos: 3x3 grid with last row centered (columns 0,1,2 | 0,1,2 | 1)
        - 5 photos: 2x3 grid with last row left-aligned (columns 0,1,2 | 0,1)

        Args:
            count: Number of photos to display.

        Returns:
            List of (row, col) tuples for each photo position.
        """
        if count == 0:
            return []
        elif count == 1:
            return [(0, 0)]
        elif count == 2:
            return [(0, 0), (0, 1)]
        elif count == 3:
            return [(0, 0), (0, 1), (0, 2)]
        elif count == 4:
            return [(0, 0), (0, 1), (1, 0), (1, 1)]
        else:
            # 5+ photos: rows of 3 with incomplete rows centered
            max_cols = 3
            positions = []

            for i in range(count):
                row = i // max_cols
                col_in_row = i % max_cols

                # Calculate number of items in this row
                items_in_row = min(max_cols, count - row * max_cols)

                # Center incomplete rows by offsetting columns
                col_offset = (max_cols - items_in_row) // 2
                col = col_in_row + col_offset

                positions.append((row, col))

            return positions

    def calculate_grid_dimensions(self, count: int) -> tuple[int, int]:
        """Calculate grid dimensions (rows, cols) for a given photo count.

        Args:
            count: Number of photos to display.

        Returns:
            Tuple of (rows, cols) for the grid.
        """
        if count == 0 or count == 1:
            return (1, 1)
        elif count == 2:
            return (1, 2)
        elif count == 3:
            return (1, 3)
        elif count == 4:
            return (2, 2)
        else:
            # 5+ photos: rows of 3
            rows = (count + 2) // 3  # Ceiling division
            return (rows, 3)

    def calculate_uniform_cell_size(self, count: int) -> QSize:
        """Calculate uniform cell size for grid layout.

        All cells get exactly the same size regardless of image aspect ratios.
        Size is calculated based on viewport dimensions and grid structure.

        Args:
            count: Number of photos to display.

        Returns:
            QSize representing the uniform size for each grid cell.
        """
        if count <= 1:
            # Single image gets full viewport
            return self.size()

        # Get grid dimensions
        rows, cols = self.calculate_grid_dimensions(count)

        # Calculate uniform cell size based on viewport
        viewport = self.size()
        cell_width = viewport.width() // cols
        cell_height = viewport.height() // rows

        return QSize(cell_width, cell_height)

    def update_zoom_overlay_position(self) -> None:
        """Position zoom overlay at bottom-right corner."""
        if self.zoom_overlay.isVisible():
            x = self.width() - self.zoom_overlay.width() - 10
            y = self.height() - self.zoom_overlay.height() - 10
            self.zoom_overlay.move(x, y)

    def set_images(self, paths: list[Path]) -> None:
        """Update the viewing area based on selected photos.

        Handles three cases:
        - 0 selected: Shows empty state message
        - 1 selected: Creates and displays ImageWidget full-screen
        - 2+ selected: Creates grid with uniform cell sizing

        Args:
            paths: List of Path objects for selected images.
                   Empty list shows the empty state message.
        """
        # Remember what was displayed and focused, so the focus ring can
        # follow the photo (or hold its grid position) across the rebuild.
        prev_paths = [w.path for w in self.image_widgets]
        prev_focused_path = (
            prev_paths[self.focused_index]
            if 0 <= self.focused_index < len(prev_paths)
            else None
        )

        # Save current zoom/pan state before clearing widgets
        saved_zoom_level = None
        saved_pan_offset = None
        saved_fit_mode = True
        saved_individual_pan_offsets: dict[Path, QPoint] = {}
        saved_viewport_size = None
        if self.image_widgets:
            # Get zoom/pan from first widget to apply to all new widgets
            first_widget = self.image_widgets[0]
            saved_zoom_level = first_widget.zoom_level
            saved_pan_offset = first_widget.pan_offset
            saved_fit_mode = first_widget.fit_mode
            # Save each widget's individual pan offset keyed by path
            saved_individual_pan_offsets = {
                widget.path: widget.individual_pan_offset
                for widget in self.image_widgets
            }
            # Track the old viewport size for pan adjustment
            saved_viewport_size = (
                first_widget.fixed_size if first_widget.fixed_size else self.size()
            )

        # Clear any existing widgets
        self.clear_widgets()

        # Notify the cache which images are active, so they're protected
        # from LRU eviction and start decoding in the background right away
        # (see ImageCache.set_active_images) rather than waiting on each
        # ImageWidget's own cache-miss fallback. For a single selection,
        # also prefetch nearby neighbors so sequential culling (arrow-key
        # navigation) stays a cache hit. Comparison mode has no obvious
        # "next" image, so it prefetches nothing beyond the tiles themselves.
        if self.session.image_cache is not None:
            prefetch = (
                self._neighbor_paths(paths[0], radius=PREFETCH_RADIUS)
                if len(paths) == 1
                else set()
            )
            self.session.image_cache.set_active_images(set(paths), prefetch)

        if len(paths) == 0:
            self.focused_index = 0
            # Show empty state - add back to layout if not present
            if self.layout().indexOf(self.empty_label) < 0:
                self.layout().addWidget(self.empty_label, 0, 0)
            self.empty_label.show()
            # Hide zoom overlay when no images
            self.zoom_overlay.hide()
        elif len(paths) == 1:
            self.focused_index = 0
            # Single image: create ImageWidget and display full-screen
            self.empty_label.hide()
            widget = ImageWidget(paths[0], self.session, synchronized=False)

            # Route overlay button requests through the marking pipeline
            widget.mark_requested.connect(self.mark_requested)

            # Connect zoom changes to update overlay label
            widget.zoom_changed.connect(lambda _: self.zoom_overlay.update_zoom_label())

            # Connect removal signal (Ctrl+click removes from comparison)
            widget.remove_from_comparison.connect(
                lambda p=paths[0]: self.on_remove_from_comparison(p)
            )

            self.layout().addWidget(widget, 0, 0)
            self.image_widgets.append(widget)

            # Apply saved zoom/pan state if available
            if saved_zoom_level is not None and saved_pan_offset is not None:
                widget.set_zoom(saved_zoom_level, emit_signal=False)
                widget.set_pan(
                    saved_pan_offset.x(), saved_pan_offset.y(), emit_signal=False
                )

                # Adjust pan offset for viewport size change to maintain visual center
                # (skip when restoring into fit mode — pan is irrelevant there)
                if saved_viewport_size is not None and not saved_fit_mode:
                    widget.viewport_size = saved_viewport_size
                    widget.adjust_pan_for_viewport_change(self.size())

                individual_offset = saved_individual_pan_offsets.get(
                    paths[0], QPoint(0, 0)
                )
                widget.individual_pan_offset = QPoint(
                    individual_offset.x(), individual_offset.y()
                )

                # Restore fit mode after set_zoom (which always exits fit mode)
                if saved_fit_mode:
                    widget.set_fit_mode(True, emit_signal=False)

            # Show zoom controls for single image
            self.zoom_overlay.show()
            self.zoom_overlay.raise_()
            self.update_zoom_overlay_position()
            self.zoom_overlay.update_zoom_label()
        else:
            # Multiple images: comparison mode with synchronized zoom/pan
            self.empty_label.hide()

            # Calculate uniform cell size for all images
            cell_size = self.calculate_uniform_cell_size(len(paths))

            # Calculate grid layout
            grid = self.calculate_grid_layout(len(paths))

            # Create ImageWidget for each path with uniform size constraint
            for i, path in enumerate(paths):
                row, col = grid[i]

                # Create widget with synchronization enabled and fixed size
                widget = ImageWidget(
                    path, self.session, synchronized=True, fixed_size=cell_size
                )

                # Route overlay button requests through the marking pipeline
                widget.mark_requested.connect(self.mark_requested)

                # Connect every widget's zoom changes to update the overlay
                # label, not just the first: the SynchronizedViewController
                # broadcast reaches other widgets via set_zoom(emit_signal=
                # False), so only the widget the user actually zoomed emits
                # zoom_changed - if only widget[0] were connected, zooming
                # any other tile would leave the label stale.
                widget.zoom_changed.connect(
                    lambda _: self.zoom_overlay.update_zoom_label()
                )

                # Connect removal signal (Ctrl+click removes from comparison)
                widget.remove_from_comparison.connect(
                    lambda p=path: self.on_remove_from_comparison(p)
                )

                # Add to layout at calculated position
                self.layout().addWidget(widget, row, col)
                self.image_widgets.append(widget)
                widget.set_position_number(i + 1)

                # Register with sync controller
                self.sync_controller.add_widget(widget)

                # Apply saved zoom/pan state if available
                if saved_zoom_level is not None and saved_pan_offset is not None:
                    widget.set_zoom(saved_zoom_level, emit_signal=False)
                    widget.set_pan(
                        saved_pan_offset.x(), saved_pan_offset.y(), emit_signal=False
                    )

                    # Adjust pan offset for viewport size change to maintain visual center
                    # (skip when restoring into fit mode — pan is irrelevant there)
                    if saved_viewport_size is not None and not saved_fit_mode:
                        widget.viewport_size = saved_viewport_size
                        widget.adjust_pan_for_viewport_change(cell_size)

                    individual_offset = saved_individual_pan_offsets.get(
                        path, QPoint(0, 0)
                    )
                    widget.individual_pan_offset = QPoint(
                        individual_offset.x(), individual_offset.y()
                    )

                    # Restore fit mode after set_zoom (which always exits fit mode)
                    if saved_fit_mode:
                        widget.set_fit_mode(True, emit_signal=False)

            # Resolve where the focus ring lands: follow the previously
            # focused photo if it is still displayed; on a tile removal
            # (subset) hold the grid position so focus lands on the tile
            # that slid into the removed one's slot; otherwise this is a
            # fresh comparison, start at the first tile.
            if prev_focused_path in paths:
                self.focused_index = paths.index(prev_focused_path)
            elif set(paths) <= set(prev_paths):
                self.focused_index = min(self.focused_index, len(paths) - 1)
            else:
                self.focused_index = 0
            self._apply_focus_ring()

            # Show zoom controls for comparison mode
            self.zoom_overlay.show()
            self.zoom_overlay.raise_()
            self.update_zoom_overlay_position()
            self.zoom_overlay.update_zoom_label()

        # Emit signal with current images
        self.current_images_changed.emit(paths)

    def on_image_ready(self, path: Path) -> None:
        """Swap the real pixmap into any currently-displayed widget for path.

        Connected to ImageCache.image_ready by MainWindow once the cache
        exists (see MainWindow._start_image_loading) - a background decode
        completing after the user already moved on to a different photo
        finds no matching widget and is a silent no-op.

        Args:
            path: Path to the image whose background decode just completed.
        """
        if self.session.image_cache is None:
            return
        pixmap = self.session.image_cache.get(path)
        if pixmap is None:
            return
        for widget in self.image_widgets:
            if widget.path == path:
                widget.set_full_image(pixmap)

    def on_image_load_failed(self, path: Path) -> None:
        """Show the failed-to-load placeholder on any currently-displayed widget for path.

        Connected to ImageCache.load_failed by MainWindow once the cache
        exists (see MainWindow._start_image_loading).

        Args:
            path: Path to the image whose background decode just failed.
        """
        for widget in self.image_widgets:
            if widget.path == path:
                widget.show_load_failed()

    def set_focused_index(self, index: int) -> None:
        """Move the comparison focus ring to the tile at index.

        Clamped to the current tile range; no-op outside comparison mode.

        Args:
            index: Target tile index in display order (0-based).
        """
        if len(self.image_widgets) < 2:
            return
        self.focused_index = max(0, min(index, len(self.image_widgets) - 1))
        self._apply_focus_ring()

    def move_focus(self, dx: int = 0, dy: int = 0) -> None:
        """Move the focus ring spatially through the comparison grid.

        Args:
            dx: Steps through the row-major tile order (h/l), clamped at
                both ends.
            dy: Grid rows down (positive) or up (negative) (j/k). Lands on
                the nearest column when the target row is shorter; no-op
                when the target row does not exist.
        """
        count = len(self.image_widgets)
        if count < 2:
            return
        if dx:
            self.set_focused_index(self.focused_index + dx)
            return
        if not dy:
            return
        positions = self.calculate_grid_layout(count)
        row, col = positions[self.focused_index]
        candidates = [(i, c) for i, (r, c) in enumerate(positions) if r == row + dy]
        if not candidates:
            return
        index, _ = min(candidates, key=lambda entry: abs(entry[1] - col))
        self.set_focused_index(index)

    def focused_path(self) -> Path | None:
        """Return the focused tile's path, or the single displayed photo.

        Returns:
            Path of the focused tile in comparison mode, the displayed
            photo in single mode, or None when nothing is displayed.
        """
        if not self.image_widgets:
            return None
        index = min(self.focused_index, len(self.image_widgets) - 1)
        return self.image_widgets[index].path

    def pan_group(self, dx: int, dy: int) -> None:
        """Pan the synchronized view by one keyboard step.

        No-op while fit mode is active - the whole image is already
        visible, so there is nothing to pan to (matches mouse-drag
        panning, which is also a no-op in fit mode).

        Args:
            dx: -1 to reveal content to the left, +1 to reveal content to
                the right, 0 for no horizontal movement.
            dy: -1 to reveal content above, +1 to reveal content below, 0
                for no vertical movement.
        """
        if not self.image_widgets:
            return
        reference = self.image_widgets[0]
        if reference.fit_mode:
            return
        delta_x, delta_y = _pan_delta(reference, dx, dy, PAN_STEP_FRACTION)
        new_x = reference.pan_offset.x() + delta_x
        new_y = reference.pan_offset.y() + delta_y
        for widget in self.image_widgets:
            widget.set_pan(new_x, new_y, emit_signal=False)

    def align_focused(self, dx: int, dy: int) -> None:
        """Nudge the focused tile's individual pan offset.

        Lets one tile be registered against its peers when its shot is
        framed slightly differently - the offset is per-tile and never
        broadcast to the rest of the group (see
        ImageWidget.individual_pan_offset). No-op outside comparison mode
        or while the focused tile is in fit mode.

        Args:
            dx: -1 to reveal content to the left, +1 to reveal content to
                the right, 0 for no horizontal movement.
            dy: -1 to reveal content above, +1 to reveal content below, 0
                for no vertical movement.
        """
        if len(self.image_widgets) < 2:
            return
        widget = self.image_widgets[self.focused_index]
        if widget.fit_mode:
            return
        delta_x, delta_y = _pan_delta(widget, dx, dy, ALIGN_STEP_FRACTION)
        offset = widget.individual_pan_offset
        widget.set_individual_pan(offset.x() + delta_x, offset.y() + delta_y)

    def reset_focused_alignment(self) -> None:
        """Clear the focused tile's individual pan offset, re-syncing it to the group."""
        if len(self.image_widgets) < 2:
            return
        self.image_widgets[self.focused_index].set_individual_pan(0, 0)

    def _apply_focus_ring(self) -> None:
        """Draw the focus ring on the focused tile only (comparison mode)."""
        show_ring = len(self.image_widgets) >= 2
        for i, widget in enumerate(self.image_widgets):
            widget.set_focused(show_ring and i == self.focused_index)

    def on_remove_from_comparison(self, path: Path) -> None:
        """Handle Ctrl+click removal of image from comparison view.

        Removes the image from the current display and updates the session selection
        without changing its keeper/delete status.

        Args:
            path: Path to the image to remove from comparison.
        """
        # Check if this photo is currently displayed
        if path not in [w.path for w in self.image_widgets]:
            return

        # Get current paths and remove this one
        current_paths = [w.path for w in self.image_widgets]
        remaining_paths = [p for p in current_paths if p != path]

        # Update display with remaining images
        self.set_images(remaining_paths)

        # Update session selection to remove this image
        if path in self.session.selected:
            self.session.selected.remove(path)

    def resizeEvent(self, event) -> None:  # noqa: N802, ANN001
        """Handle widget resize, updating overlay position and grid layout.

        When in comparison mode (multiple images), recalculates grid cell sizes
        to fit the new window dimensions.

        Args:
            event: The resize event.
        """
        super().resizeEvent(event)
        self.update_zoom_overlay_position()

        # Recalculate grid layout if in comparison mode
        if len(self.image_widgets) > 1:
            # Recalculate uniform cell size for new viewport dimensions
            cell_size = self.calculate_uniform_cell_size(len(self.image_widgets))

            # Update fixed_size for all widgets and refresh their display
            for widget in self.image_widgets:
                widget.fixed_size = cell_size
                widget.update_display()

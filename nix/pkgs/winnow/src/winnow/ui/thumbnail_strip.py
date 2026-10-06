"""ThumbnailStrip widget for displaying photo thumbnails.

This module provides the bottom thumbnail strip widget showing all photos in the session.
Currently a placeholder, will be extended to show scrollable thumbnails with selection handling.
"""

from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QColor, QMouseEvent, QPixmap
from PySide6.QtWidgets import (
    QGraphicsDropShadowEffect,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QSlider,
    QVBoxLayout,
    QWidget,
)

from winnow.core.session import PhotoStatus, Session
from winnow.core.thumbnailer import Thumbnailer


class ThumbnailWidget(QLabel):
    """Widget displaying a single thumbnail with status-colored border.

    Displays a QPixmap thumbnail with a color-coded border indicating the photo's
    status and selection state:
    - Blue (3px): Selected photo (highest priority)
    - Green (2px): Marked as keeper
    - Red (2px): Marked for deletion
    - Gray (1px): Unmarked (default state)

    The border updates when update_appearance() is called after session state changes.
    """

    def __init__(
        self, pixmap: QPixmap, path: Path, session: Session, strip: "ThumbnailStrip"
    ) -> None:
        """Initialize the ThumbnailWidget.

        Args:
            pixmap: The thumbnail QPixmap to display.
            path: Path to the image file this thumbnail represents.
            session: Session object containing status and selection state.
            strip: Parent ThumbnailStrip for handling click events.
        """
        super().__init__()
        self.path = path
        self.session = session
        self.strip = strip

        # Display the thumbnail
        self.setPixmap(pixmap)

        # Set fixed size to match pixmap for consistent layout
        self.setFixedSize(pixmap.size())

        # Apply initial border styling
        self.update_appearance()

    def mousePressEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Handle mouse click events for thumbnail selection.

        Single click (no modifiers): Select only this thumbnail
        Ctrl+click: Toggle this thumbnail in multi-selection
        Shift+click: Select range from last clicked to this thumbnail (replaces selection)
        Ctrl+Shift+click: Add range to existing selection (preserves previous selection)

        Args:
            event: The mouse event containing click information.
        """
        # Check if modifier keys are pressed
        ctrl_pressed = bool(event.modifiers() & Qt.KeyboardModifier.ControlModifier)
        shift_pressed = bool(event.modifiers() & Qt.KeyboardModifier.ShiftModifier)

        # Delegate selection handling to parent strip
        self.strip.handle_thumbnail_click(self.path, ctrl_pressed, shift_pressed)

        # Call parent implementation
        super().mousePressEvent(event)

    def update_appearance(self) -> None:
        """Update the widget's border based on current session state.

        Shows dual borders when both selected and has status:
        - Outer border: selection (blue 5px) or status color (green/red 4px)
        - Outline: status color (green/red 3px) when selected
        - Shadow: matching the primary color

        Uses QGraphicsDropShadowEffect for proper Qt-compatible shadows.
        """
        is_selected = self.path in self.session.selected
        status = self.session.get_status(self.path)

        # Determine border, outline, and shadow based on selection + status
        if is_selected:
            # Selected: blue outer border
            border = "5px solid #2196F3"
            shadow_color = QColor(33, 150, 243, 153)  # Blue shadow
            shadow_blur = 8

            # Add status outline if not unmarked
            if status == PhotoStatus.KEEPER:
                outline = "3px solid #4CAF50"  # Green inner
            elif status == PhotoStatus.DELETE:
                outline = "3px solid #F44336"  # Red inner
            else:
                outline = None
        elif status == PhotoStatus.KEEPER:
            # Keeper: green border with shadow
            border = "4px solid #4CAF50"
            shadow_color = QColor(76, 175, 80, 128)
            shadow_blur = 6
            outline = None
        elif status == PhotoStatus.DELETE:
            # Delete: red border with shadow
            border = "4px solid #F44336"
            shadow_color = QColor(244, 67, 54, 128)
            shadow_blur = 6
            outline = None
        else:
            # Unmarked: gray border (no shadow)
            border = "3px solid #757575"
            shadow_color = None
            shadow_blur = 0
            outline = None

        # Apply styles
        if outline:
            style = f"border: {border}; outline: {outline}; outline-offset: -4px;"
        else:
            style = f"border: {border};"

        self.setStyleSheet(style)

        # Apply shadow effect if needed
        if shadow_color:
            shadow = QGraphicsDropShadowEffect()
            shadow.setBlurRadius(shadow_blur)
            shadow.setColor(shadow_color)
            shadow.setOffset(0, 0)
            self.setGraphicsEffect(shadow)
        else:
            self.setGraphicsEffect(None)

    def regenerate_thumbnail(self, pixmap: QPixmap) -> None:
        """Update the thumbnail with a new pixmap at a different size.

        This method is used when the zoom level changes to update the thumbnail
        in-place without destroying and recreating the widget.

        Args:
            pixmap: New QPixmap at updated size.
        """
        self.setPixmap(pixmap)
        self.setFixedSize(pixmap.size())
        # Reapply appearance to preserve border styling after size change
        self.update_appearance()


class ThumbnailStrip(QWidget):
    """Thumbnail strip widget for displaying photo thumbnails.

    Displays all photos in a scrollable horizontal strip with:
    - Control bar with filter buttons and zoom slider (placeholders for future tasks)
    - Scrollable horizontal thumbnail grid
    - Status borders (blue=selected, green=keeper, red=delete, gray=unmarked)
    - Selection change signal emission (click handling to be added in future task)
    """

    # Signal emitted when selection changes (list of selected Paths)
    selection_changed = Signal(list)
    # Signal emitted when filter buttons are toggled
    filter_changed = Signal()

    def __init__(self, session: Session, thumbnailer: Thumbnailer) -> None:
        """Initialize the ThumbnailStrip with session and thumbnailer.

        Args:
            session: Session object containing images and state.
            thumbnailer: Thumbnailer instance for generating thumbnails.
        """
        super().__init__()

        self.session = session
        self.thumbnailer = thumbnailer
        # Every photo's widget, created once. Filtering hides and shows
        # these rather than rebuilding them, so marking a photo (which can
        # hide it) costs one visibility pass, not a strip rebuild.
        self._widgets: dict[Path, ThumbnailWidget] = {}
        # The visible widgets, in strip order.
        self.thumbnail_widgets: list[ThumbnailWidget] = []
        self.last_clicked_path: Path | None = None

        # Swap in the real thumbnail as each background decode completes.
        self.thumbnailer.thumbnail_ready.connect(self._on_thumbnail_ready)

        # Calculate initial height based on thumbnail size
        # Control bar: 40px + thumbnail size + margins (20px)
        self._update_strip_height()

        # Main vertical layout
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # Create control bar (~40px height)
        control_bar = self._create_control_bar()
        main_layout.addWidget(control_bar)

        # Create scrollable thumbnail container (~180px height)
        self.scroll_area = self._create_thumbnail_scroll_area()
        main_layout.addWidget(self.scroll_area)

    def handle_thumbnail_click(
        self, path: Path, ctrl_pressed: bool, shift_pressed: bool
    ) -> None:
        """Handle thumbnail click for single, multi, or range selection.

        Args:
            path: Path to the clicked thumbnail image.
            ctrl_pressed: True if Ctrl key was held during click.
            shift_pressed: True if Shift key was held during click.
        """
        previously_selected = set(self.session.selected)

        if shift_pressed and self.last_clicked_path is not None:
            # Range select: select all thumbnails between last clicked and this one
            # IMPORTANT: Use filtered_images() to only select visible thumbnails
            try:
                # Get currently filtered/visible images
                visible_images = self.session.filtered_images()

                # Find indices in the visible images list (not all images)
                start_idx = visible_images.index(self.last_clicked_path)
                end_idx = visible_images.index(path)

                # Ensure start is before end
                if start_idx > end_idx:
                    start_idx, end_idx = end_idx, start_idx

                # If Ctrl is also pressed, add range to existing selection
                # Otherwise, replace selection with range
                if not ctrl_pressed:
                    self.session.selected.clear()

                # Add all visible images in the range to selection
                for i in range(start_idx, end_idx + 1):
                    img_path = visible_images[i]
                    if img_path not in self.session.selected:
                        self.session.selected.append(img_path)
            except ValueError:
                # If either path is not found, fall back to single select
                self.session.selected.clear()
                self.session.selected.append(path)
        elif ctrl_pressed:
            # Multi-select: toggle the clicked thumbnail
            if path in self.session.selected:
                self.session.selected.remove(path)
            else:
                self.session.selected.append(path)
        else:
            # Single select: replace selection with just this thumbnail
            self.session.selected.clear()
            self.session.selected.append(path)

        # Update last clicked path for future range selections
        self.last_clicked_path = path

        # Only restyle thumbnails whose selection membership actually
        # changed - update_appearance() rebuilds a QGraphicsDropShadowEffect
        # per call, so doing this for every thumbnail in the directory on
        # every click doesn't scale with directory size.
        self._restyle(previously_selected ^ set(self.session.selected))

        # Update selection indicator
        self._update_selection_indicator()

        # Keep the clicked/navigated-to thumbnail visible in the strip.
        self.scroll_to_path(path)

        # Emit signal with current selection
        self.selection_changed.emit(list(self.session.selected))

    def set_selection(self, paths: list[Path]) -> None:
        """Programmatically update selection without emitting signals.

        This method is used when selection changes come from external sources
        (e.g., auto-advance in viewing area) to keep the thumbnail strip in sync.

        Args:
            paths: List of paths to select. Empty list clears selection.
        """
        # Check if selection is already correct (avoid circular updates)
        if list(self.session.selected) == paths:
            return

        previously_selected = set(self.session.selected)

        # Update session selection
        self.session.selected.clear()
        self.session.selected.extend(paths)

        # Update last_clicked_path to the first selected item for future Shift+click
        self.last_clicked_path = paths[0] if paths else None

        # Only restyle thumbnails whose selection membership actually
        # changed - see handle_thumbnail_click for why this matters.
        self._restyle(previously_selected ^ set(paths))

        # Update selection indicator
        self._update_selection_indicator()

        # Scroll to make the first selected thumbnail visible
        if paths:
            self.scroll_to_path(paths[0])

    def scroll_to_path(self, path: Path) -> None:
        """Scroll the thumbnail strip to make a specific path visible.

        Args:
            path: Path to the thumbnail to scroll to.
        """
        widget = self._widgets.get(path)
        if widget is not None and not widget.isHidden():
            self.scroll_area.ensureWidgetVisible(widget)

    def _restyle(self, paths: set[Path]) -> None:
        """Refresh the border of each path's widget, visible or not.

        Args:
            paths: Photos whose selection or status changed.
        """
        for path in paths:
            widget = self._widgets.get(path)
            if widget is not None:
                widget.update_appearance()

    def _create_control_bar(self) -> QWidget:
        """Create the control bar with filter buttons and zoom slider.

        Returns:
            QWidget containing the control bar layout.
        """
        control_widget = QWidget()
        control_widget.setFixedHeight(40)
        control_layout = QHBoxLayout(control_widget)
        control_layout.setContentsMargins(10, 5, 10, 5)

        # Filter buttons - checkable toggles that update session filter state.
        # NoFocus keeps Tab and Space from wandering onto them; the keyboard
        # path is the t-prefix chords.
        self.unmarked_btn = QPushButton("Unmarked")
        self.unmarked_btn.setCheckable(True)
        self.unmarked_btn.setChecked(True)  # Show unmarked by default
        self.unmarked_btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.unmarked_btn.clicked.connect(self.on_filter_toggle)

        self.keepers_btn = QPushButton("Keepers")
        self.keepers_btn.setCheckable(True)
        self.keepers_btn.setChecked(True)  # Show keepers by default
        self.keepers_btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.keepers_btn.clicked.connect(self.on_filter_toggle)

        self.deletes_btn = QPushButton("Deletes")
        self.deletes_btn.setCheckable(True)
        self.deletes_btn.setChecked(False)  # Hide deletes by default
        self.deletes_btn.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.deletes_btn.clicked.connect(self.on_filter_toggle)

        # Apply styling to make checked/unchecked state more obvious
        button_style = """
            QPushButton {
                padding: 5px 10px;
                border: 2px solid #999;
                border-radius: 4px;
                background-color: #f0f0f0;
                color: #666;
            }
            QPushButton:checked {
                background-color: #2196F3;
                color: white;
                border-color: #1976D2;
                font-weight: bold;
            }
            QPushButton:hover {
                border-color: #666;
            }
            QPushButton:checked:hover {
                background-color: #1976D2;
            }
        """
        self.unmarked_btn.setStyleSheet(button_style)
        self.keepers_btn.setStyleSheet(button_style)
        self.deletes_btn.setStyleSheet(button_style)

        control_layout.addWidget(self.unmarked_btn)
        control_layout.addWidget(self.keepers_btn)
        control_layout.addWidget(self.deletes_btn)

        # Selection indicator label (e.g., "34/113" or "34/113 · 3 selected")
        self.selection_indicator = QLabel()
        self.selection_indicator.hide()  # Hidden until selection is made
        control_layout.addWidget(self.selection_indicator)

        # Stretch to push zoom slider to the right
        control_layout.addStretch()

        # Zoom slider - adjusts thumbnail size (100-400px). NoFocus so a
        # focused slider can never contend with h/l/arrow navigation keys.
        self.zoom_slider = QSlider(Qt.Orientation.Horizontal)
        self.zoom_slider.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.zoom_slider.setMinimum(100)
        self.zoom_slider.setMaximum(400)
        self.zoom_slider.setValue(150)
        self.zoom_slider.setFixedWidth(200)
        # Use sliderReleased to only regenerate when user finishes dragging
        # (prevents UI freeze from continuous regeneration during drag)
        self.zoom_slider.sliderReleased.connect(self.on_zoom_changed)
        control_layout.addWidget(self.zoom_slider)

        return control_widget

    def _create_thumbnail_scroll_area(self) -> QScrollArea:
        """Create the scrollable horizontal thumbnail container.

        Creates every thumbnail widget immediately with a placeholder pixmap
        (so the window paints without waiting on any decode) and queues a
        background task per image to swap in the real thumbnail as it
        finishes decoding.

        Returns:
            QScrollArea containing all thumbnails.
        """
        # Create scroll area
        scroll_area = QScrollArea()
        scroll_area.setWidgetResizable(True)
        scroll_area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        scroll_area.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        # Create container widget for thumbnails
        container = QWidget()
        self.container_layout = QHBoxLayout(container)
        self.container_layout.setContentsMargins(10, 10, 10, 10)
        self.container_layout.setSpacing(5)
        self.container_layout.setAlignment(
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter
        )

        # Create a widget for every image, with a placeholder until its
        # background decode completes.
        for image_path in self.session.images:
            thumbnail_widget = self._create_thumbnail_widget_async(image_path)
            self._widgets[image_path] = thumbnail_widget
            self.container_layout.addWidget(thumbnail_widget)

        # Add stretch to prevent thumbnails from spreading out
        self.container_layout.addStretch()

        self._apply_filter()

        scroll_area.setWidget(container)
        return scroll_area

    def _apply_filter(self) -> list[Path]:
        """Show exactly the widgets the current filters let through.

        Returns:
            The filtered paths, in strip order.
        """
        filtered = self.session.filtered_images()
        visible = set(filtered)
        for path, widget in self._widgets.items():
            widget.setHidden(path not in visible)
        self.thumbnail_widgets = [self._widgets[p] for p in filtered]
        return filtered

    def _create_thumbnail_widget_async(self, path: Path) -> ThumbnailWidget:
        """Create a thumbnail widget for path, decoding in the background if needed.

        Reuses an already-cached thumbnail immediately if session.thumbnails
        has one. Otherwise shows a placeholder and queues a background
        decode - _on_thumbnail_ready swaps in the real thumbnail once it
        completes.

        Args:
            path: Path to the image file to thumbnail.

        Returns:
            A new ThumbnailWidget for path.
        """
        cached = self.session.thumbnails.get(path)
        if cached is not None:
            return ThumbnailWidget(cached, path, self.session, self)

        placeholder = self._make_placeholder_pixmap(self.thumbnailer.size)
        widget = ThumbnailWidget(placeholder, path, self.session, self)
        self.thumbnailer.queue_thumbnail(path)
        return widget

    @staticmethod
    def _make_placeholder_pixmap(size: int) -> QPixmap:
        """A neutral gray box shown while a thumbnail decodes in the background.

        Args:
            size: Side length of the placeholder, in pixels.

        Returns:
            A filled (not garbage-initialized) square QPixmap.
        """
        pixmap = QPixmap(size, size)
        pixmap.fill(QColor(200, 200, 200))
        return pixmap

    def _on_thumbnail_ready(self, path: Path, pixmap: QPixmap) -> None:
        """Handle a background thumbnail decode completing.

        Args:
            path: Path to the thumbnailed image.
            pixmap: The decoded thumbnail (or a blank placeholder on failure).
        """
        self.session.thumbnails[path] = pixmap
        widget = self._widgets.get(path)
        if widget is not None:
            widget.regenerate_thumbnail(pixmap)

    def _update_strip_height(self) -> None:
        """Update thumbnail strip height based on current thumbnail size.

        Calculates required height as: control bar (40px) + thumbnail size + margins (20px).
        This allows the strip to dynamically resize when zoom changes.
        """
        control_bar_height = 40
        margins = 20  # 10px top + 10px bottom from container layout
        total_height = control_bar_height + self.thumbnailer.size + margins
        self.setFixedHeight(total_height)

    def _update_selection_indicator(self) -> None:
        """Update the selection indicator label based on current selection."""
        if len(self.session.selected) == 0:
            # No selection - hide indicator
            self.selection_indicator.hide()
        else:
            # Position within the strip as filtered, matching h/l navigation.
            visible = [w.path for w in self.thumbnail_widgets]
            total_photos = len(visible)
            first_photo_path = self.session.selected[0]

            try:
                position = visible.index(first_photo_path) + 1  # 1-indexed
            except ValueError:
                position = 0  # Photo filtered out of the strip

            # Build indicator text
            if len(self.session.selected) == 1:
                indicator_text = f"{position}/{total_photos}"
            else:
                indicator_text = (
                    f"{position}/{total_photos} · {len(self.session.selected)} selected"
                )

            self.selection_indicator.setText(indicator_text)
            self.selection_indicator.show()

    def on_filter_toggle(self) -> None:
        """Handle filter button toggles.

        Updates session filter state based on button checked states,
        emits filter_changed signal, and refreshes the thumbnail display.
        """
        # Update session filter state from button states
        self.session.show_unmarked = self.unmarked_btn.isChecked()
        self.session.show_keepers = self.keepers_btn.isChecked()
        self.session.show_deletes = self.deletes_btn.isChecked()

        # Emit signal to notify listeners that filters have changed
        self.filter_changed.emit()

        # Refresh thumbnail display based on new filter state
        self.refresh_thumbnails()

    def on_zoom_changed(self) -> None:
        """Handle zoom slider changes by regenerating thumbnails at new size.

        Every widget, hidden ones included, shows a correctly-sized
        placeholder immediately and swaps in the real thumbnail as its
        background decode completes (see _on_thumbnail_ready). Visible
        photos are queued first. session.thumbnails is cleared so nothing
        later reuses a thumbnail at the old size.

        Called when slider is released (not during drag).
        """
        value = self.zoom_slider.value()
        self.thumbnailer.set_size(value)
        self.session.thumbnails.clear()

        placeholder = self._make_placeholder_pixmap(value)
        for widget in self._widgets.values():
            widget.regenerate_thumbnail(placeholder)

        visible = [w.path for w in self.thumbnail_widgets]
        hidden = self._widgets.keys() - set(visible)
        for path in visible + [p for p in self.session.images if p in hidden]:
            self.thumbnailer.queue_thumbnail(path)

        self._update_selection_indicator()
        self._update_strip_height()

    def refresh_thumbnail_border(self, path: Path) -> None:
        """Refresh the border appearance for a specific thumbnail.

        Updates the thumbnail's border color to reflect its current status
        in the session (keeper, delete, or unmarked).

        Args:
            path: Path to the photo whose thumbnail border should be refreshed.
        """
        self._restyle({path})

    def on_photo_status_changed(self, path: Path) -> None:
        """Handle photo status changes, refreshing display if filtering is affected.

        Updates the thumbnail border, and re-applies the filters when the
        new status hides or reveals the photo.

        Args:
            path: Path to the photo whose status changed.
        """
        self.refresh_thumbnail_border(path)
        widget = self._widgets.get(path)
        if widget is None:
            return
        if widget.isHidden() == (path in self.session.filtered_images()):
            self.refresh_thumbnails()

    def navigate(self, direction: int) -> None:
        """Navigate to the adjacent image in the filtered list.

        Moves selection forward or backward by one position. Clamped to list
        boundaries, no wrapping at the start or end.

        Args:
            direction: +1 for next image, -1 for previous image.
        """
        visible = self.session.filtered_images()
        if not visible:
            return

        if self.session.selected and self.session.selected[0] in visible:
            current_idx = visible.index(self.session.selected[0])
        elif direction > 0:
            current_idx = -1
        else:
            current_idx = len(visible)

        new_idx = max(0, min(len(visible) - 1, current_idx + direction))
        new_path = visible[new_idx]

        # No-op if already at boundary (clamping didn't move us)
        if self.session.selected == [new_path]:
            return

        self.handle_thumbnail_click(new_path, ctrl_pressed=False, shift_pressed=False)

    def refresh_thumbnails(self) -> None:
        """Refresh thumbnail display based on current filter settings.

        Shows the widgets matching the current filter criteria and hides
        the rest. Preserves selection state for photos that remain visible
        after filtering, and notifies listeners via
        selection_changed if the filter hid a currently-displayed photo -
        otherwise the viewing area would keep showing a photo that just
        disappeared from the thumbnail strip.
        """
        visible = set(self._apply_filter())

        # Preserve selection only for still-visible images
        previous_selection = list(self.session.selected)
        self.session.selected = [p for p in self.session.selected if p in visible]
        self._restyle(set(previous_selection) - visible)

        # Update selection indicator
        self._update_selection_indicator()

        # If filtering changed the selection, tell listeners (e.g. the
        # viewing area, which would otherwise keep displaying a photo that
        # just got filtered out).
        if self.session.selected != previous_selection:
            self.selection_changed.emit(list(self.session.selected))

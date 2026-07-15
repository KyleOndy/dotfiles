"""Tests for MainWindow close event and file deletion."""

from pathlib import Path

from PySide6.QtWidgets import QMessageBox

from winnow.core.session import PhotoStatus
from winnow.ui.main_window import MainWindow

# Session.delete_marked_files() tests


def test_delete_marked_files_success(tmp_path):
    """Test delete_marked_files successfully deletes all marked files."""
    # Create test files
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo3 = test_dir / "photo3.jpg"
    photo1.touch()
    photo2.touch()
    photo3.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo1, photo2, photo3])

    # Mark two photos for deletion
    session.set_status(photo1, PhotoStatus.DELETE)
    session.set_status(photo2, PhotoStatus.DELETE)

    # Verify files exist before deletion
    assert photo1.exists()
    assert photo2.exists()
    assert photo3.exists()

    # Delete marked files
    failed = session.delete_marked_files()

    # Verify deletion succeeded
    assert len(failed) == 0
    assert not photo1.exists()
    assert not photo2.exists()
    assert photo3.exists()  # Unmarked file should remain


def test_delete_marked_files_empty(tmp_path):
    """Test delete_marked_files with no marked files returns empty list."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo])

    # Don't mark anything for deletion
    failed = session.delete_marked_files()

    # Should succeed with empty failed list
    assert len(failed) == 0
    assert photo.exists()


def test_delete_marked_files_permission_error(tmp_path, monkeypatch):
    """Test delete_marked_files handles permission errors gracefully."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo1, photo2])

    # Mark both for deletion
    session.set_status(photo1, PhotoStatus.DELETE)
    session.set_status(photo2, PhotoStatus.DELETE)

    # Mock unlink to raise PermissionError for photo1 only
    original_unlink = Path.unlink

    def mock_unlink(self, *args, **kwargs):
        if self == photo1:
            raise PermissionError(f"Permission denied: {self}")
        return original_unlink(self, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", mock_unlink)

    # Attempt deletion
    failed = session.delete_marked_files()

    # photo1 should fail, photo2 should succeed
    assert photo1 in failed
    assert photo2 not in failed
    assert photo1.exists()  # Still exists due to permission error
    assert not photo2.exists()  # Successfully deleted


def test_delete_marked_files_already_deleted(tmp_path):
    """Test delete_marked_files handles already-deleted files gracefully."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    # Delete the file manually before calling delete_marked_files
    photo.unlink()

    # Attempt deletion (file already gone)
    failed = session.delete_marked_files()

    # Should be in failed list (FileNotFoundError is an OSError)
    assert photo in failed


def test_delete_marked_files_deletes_raw_sibling(tmp_path):
    """Test deleting a marked JPEG also deletes its sibling .RAF."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()
    raw1 = test_dir / "photo1.RAF"
    raw2 = test_dir / "photo2.RAF"
    raw1.touch()
    raw2.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo1, photo2])
    session.set_status(photo1, PhotoStatus.DELETE)
    # photo2 is left unmarked

    failed = session.delete_marked_files()

    assert len(failed) == 0
    assert not photo1.exists()
    assert not raw1.exists()
    assert photo2.exists()
    assert raw2.exists()  # Unmarked photo's RAW sibling remains


def test_delete_marked_files_deletes_lowercase_raw_sibling(tmp_path):
    """Test a lowercase .raf sibling is also deleted."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()
    raw = test_dir / "photo.raf"
    raw.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    failed = session.delete_marked_files()

    assert len(failed) == 0
    assert not photo.exists()
    assert not raw.exists()


def test_delete_marked_files_no_raw_sibling(tmp_path):
    """Test deleting a JPEG with no RAW sibling succeeds without a false failure."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    failed = session.delete_marked_files()

    assert len(failed) == 0
    assert not photo.exists()


def test_delete_marked_files_keeper_raw_untouched(tmp_path):
    """Test a keeper's RAW sibling is left alone even when other photos delete."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    keeper = test_dir / "keeper.jpg"
    reject = test_dir / "reject.jpg"
    keeper.touch()
    reject.touch()
    keeper_raw = test_dir / "keeper.RAF"
    reject_raw = test_dir / "reject.RAF"
    keeper_raw.touch()
    reject_raw.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[keeper, reject])
    session.set_status(keeper, PhotoStatus.KEEPER)
    session.set_status(reject, PhotoStatus.DELETE)

    failed = session.delete_marked_files()

    assert len(failed) == 0
    assert keeper.exists()
    assert keeper_raw.exists()
    assert not reject.exists()
    assert not reject_raw.exists()


def test_delete_marked_files_raw_unlink_failure(tmp_path, monkeypatch):
    """Test a RAW sibling that fails to unlink is added to the failed list."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()
    raw = test_dir / "photo.RAF"
    raw.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    original_unlink = Path.unlink

    def mock_unlink(self, *args, **kwargs):
        if self == raw:
            raise PermissionError(f"Permission denied: {self}")
        return original_unlink(self, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", mock_unlink)

    failed = session.delete_marked_files()

    assert failed == [raw]
    assert not photo.exists()  # JPEG still deleted successfully
    assert raw.exists()  # RAW still present due to the permission error


def test_delete_marked_files_mixed_results(tmp_path, monkeypatch):
    """Test delete_marked_files with mixed success and failure."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo3 = test_dir / "photo3.jpg"
    photo1.touch()
    photo2.touch()
    photo3.touch()

    from winnow.core.session import Session

    session = Session(directory=test_dir, images=[photo1, photo2, photo3])

    # Mark all three for deletion
    session.set_status(photo1, PhotoStatus.DELETE)
    session.set_status(photo2, PhotoStatus.DELETE)
    session.set_status(photo3, PhotoStatus.DELETE)

    # Mock unlink to raise PermissionError for photo2 only
    original_unlink = Path.unlink

    def mock_unlink(self, *args, **kwargs):
        if self == photo2:
            raise PermissionError(f"Permission denied: {self}")
        return original_unlink(self, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", mock_unlink)

    # Attempt deletion
    failed = session.delete_marked_files()

    # Only photo2 should fail
    assert len(failed) == 1
    assert photo2 in failed
    assert not photo1.exists()
    assert photo2.exists()  # Still exists due to permission error
    assert not photo3.exists()


# MainWindow.closeEvent() tests


def test_close_event_no_marks_no_dialog(qapp, tmp_path, monkeypatch):
    """Test closeEvent without any marks closes immediately without dialog."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()

    window = MainWindow(test_dir)

    # Track if QMessageBox.question was called
    question_called = []

    def mock_question(*args, **kwargs):
        question_called.append(True)
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", mock_question)

    # Simulate close event
    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Dialog should not be shown
    assert len(question_called) == 0
    # Event should be accepted
    assert event.isAccepted()


def test_close_event_with_deletes_shows_dialog(qapp, tmp_path, monkeypatch):
    """Test closeEvent with deletes shows the quit confirmation dialog."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()

    window = MainWindow(test_dir)

    # Mark photos for deletion
    window.session.set_status(photo1, PhotoStatus.DELETE)
    window.session.set_status(photo2, PhotoStatus.DELETE)

    # Track dialog call
    dialog_args = []

    def mock_question(*args, **kwargs):
        dialog_args.append((args, kwargs))
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", mock_question)

    # Simulate close event
    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Dialog should be shown
    assert len(dialog_args) == 1
    args, kwargs = dialog_args[0]

    # Check dialog content
    assert "Confirm Quit" in args
    assert "2 deletes marked" in args[2]
    assert "Discard quits without deleting" in args[2]


def test_close_event_with_raw_siblings_shows_count(qapp, tmp_path, monkeypatch):
    """Test closeEvent dialog reports the RAW count alongside the delete count.

    RAW siblings are never shown in the UI, so this count is the only place
    the user learns extra, unseen files will also be removed.
    """
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()
    (test_dir / "photo1.RAF").touch()
    (test_dir / "photo2.RAF").touch()

    window = MainWindow(test_dir)

    # Mark both for deletion
    window.session.set_status(photo1, PhotoStatus.DELETE)
    window.session.set_status(photo2, PhotoStatus.DELETE)

    dialog_args = []

    def mock_question(*args, **kwargs):
        dialog_args.append((args, kwargs))
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", mock_question)

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    assert len(dialog_args) == 1
    args, _ = dialog_args[0]
    assert "2 deletes (+2 RAW) marked" in args[2]


def test_close_event_keepers_only_shows_dialog(qapp, tmp_path, monkeypatch):
    """Test closeEvent confirms when only keepers are marked.

    The session is ephemeral, so quitting discards a keepers-only cull
    pass; that deserves the same confirmation as pending deletes.
    """
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    window = MainWindow(test_dir)
    window.session.set_status(photo, PhotoStatus.KEEPER)

    dialog_args = []

    def mock_question(*args, **kwargs):
        dialog_args.append((args, kwargs))
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", mock_question)

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    assert len(dialog_args) == 1
    args, _ = dialog_args[0]
    assert "1 keepers, 0 deletes marked" in args[2]
    # Declining keeps the window open
    assert not event.isAccepted()
    assert photo.exists()


def test_close_event_cancel_keeps_window_open(qapp, tmp_path, monkeypatch):
    """Test that declining the quit confirmation ignores the close event."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    window = MainWindow(test_dir)
    window.session.set_status(photo, PhotoStatus.DELETE)

    # Mock to return No
    monkeypatch.setattr(
        QMessageBox, "question", lambda *args, **kwargs: QMessageBox.StandardButton.No
    )

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    event.accept()  # Start accepted so ignore() is observable
    window.closeEvent(event)

    # Event should be ignored (window stays open)
    assert not event.isAccepted()
    # File should still exist (not deleted)
    assert photo.exists()
    # The session's marks are untouched
    assert window.session.get_status(photo) == PhotoStatus.DELETE


def test_close_event_confirm_deletes_files(qapp, tmp_path, monkeypatch):
    """Test closeEvent actually deletes files when user confirms."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo3 = test_dir / "photo3.jpg"
    photo1.touch()
    photo2.touch()
    photo3.touch()

    window = MainWindow(test_dir)

    # Mark two for deletion
    window.session.set_status(photo1, PhotoStatus.DELETE)
    window.session.set_status(photo2, PhotoStatus.DELETE)

    # Mock to return Yes
    monkeypatch.setattr(
        QMessageBox, "question", lambda *args, **kwargs: QMessageBox.StandardButton.Yes
    )

    # Verify files exist before
    assert photo1.exists()
    assert photo2.exists()
    assert photo3.exists()

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Files should be deleted
    assert not photo1.exists()
    assert not photo2.exists()
    assert photo3.exists()  # Unmarked file remains
    # Event accepted
    assert event.isAccepted()


def test_close_event_discard_quits_without_deleting(qapp, tmp_path, monkeypatch):
    """Test closeEvent quits without deleting when user picks Discard."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()

    window = MainWindow(test_dir)

    # Mark one for deletion
    window.session.set_status(photo1, PhotoStatus.DELETE)

    # Mock to return Discard
    monkeypatch.setattr(
        QMessageBox,
        "question",
        lambda *args, **kwargs: QMessageBox.StandardButton.Discard,
    )

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Marked file is untouched
    assert photo1.exists()
    assert photo2.exists()
    # Event still accepted - the app closes
    assert event.isAccepted()


def test_close_event_prints_failures(qapp, tmp_path, monkeypatch, capsys):
    """Test closeEvent prints failures to stderr."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()

    window = MainWindow(test_dir)

    # Mark both for deletion
    window.session.set_status(photo1, PhotoStatus.DELETE)
    window.session.set_status(photo2, PhotoStatus.DELETE)

    # Mock unlink to raise PermissionError for photo1 only
    original_unlink = Path.unlink

    def mock_unlink(self, *args, **kwargs):
        if self == photo1:
            raise PermissionError(f"Permission denied: {self}")
        return original_unlink(self, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", mock_unlink)

    # Mock to return Yes
    monkeypatch.setattr(
        QMessageBox, "question", lambda *args, **kwargs: QMessageBox.StandardButton.Yes
    )

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Check stderr output
    captured = capsys.readouterr()
    assert "Failed to delete:" in captured.err
    assert str(photo1) in captured.err
    assert str(photo2) not in captured.err  # photo2 succeeded


def test_close_event_default_button_no(qapp, tmp_path, monkeypatch):
    """Test closeEvent dialog defaults to No button for safety."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo = test_dir / "photo.jpg"
    photo.touch()

    window = MainWindow(test_dir)
    window.session.set_status(photo, PhotoStatus.DELETE)

    default_button = []

    def mock_question(parent, title, text, buttons, default):
        default_button.append(default)
        return QMessageBox.StandardButton.No

    monkeypatch.setattr(QMessageBox, "question", mock_question)

    from PySide6.QtGui import QCloseEvent

    event = QCloseEvent()
    window.closeEvent(event)

    # Verify default button is No
    assert len(default_button) == 1
    assert default_button[0] == QMessageBox.StandardButton.No

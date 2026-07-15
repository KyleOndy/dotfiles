"""Tests for the winnow CLI entry point (app.main()).

Both directory-validation branches return before touching Qt (main() only
constructs QApplication after they pass), so these are safe to exercise
directly without a QApplication fixture or worrying about the
one-QApplication-per-process restriction.
"""

import sys

import pytest

from winnow.app import main


def test_main_returns_1_for_nonexistent_directory(monkeypatch, capsys, tmp_path):
    """A nonexistent directory prints a clean error and exits 1."""
    missing = tmp_path / "does-not-exist"
    monkeypatch.setattr(sys, "argv", ["winnow", str(missing)])

    exit_code = main()

    assert exit_code == 1
    captured = capsys.readouterr()
    assert "does not exist" in captured.err


def test_main_returns_1_for_file_not_directory(monkeypatch, capsys, tmp_path):
    """A path that is a file, not a directory, prints a clean error and exits 1."""
    a_file = tmp_path / "not_a_directory.jpg"
    a_file.touch()
    monkeypatch.setattr(sys, "argv", ["winnow", str(a_file)])

    exit_code = main()

    assert exit_code == 1
    captured = capsys.readouterr()
    assert "not a directory" in captured.err


class _FakeWindow:
    """Stand-in for MainWindow that just records its constructor args.

    Used to test --max-memory argument wiring without touching a real
    QApplication/MainWindow - see the module docstring for why the other
    tests here avoid that too.
    """

    def __init__(self, directory, max_memory_mb=24576.0):
        self.directory = directory
        self.max_memory_mb = max_memory_mb
        _FakeWindow.last_instance = self

    def show(self):
        pass


class _FakeApp:
    """Stand-in for QApplication whose exec() returns immediately."""

    def __init__(self, argv):
        pass

    def exec(self):
        return 0


def test_main_threads_max_memory_argument_to_main_window(monkeypatch, tmp_path):
    """--max-memory is parsed and passed through to MainWindow."""
    import winnow.app as app_module

    photos = tmp_path / "photos"
    photos.mkdir()

    monkeypatch.setattr(app_module, "MainWindow", _FakeWindow)
    monkeypatch.setattr(app_module, "QApplication", _FakeApp)
    monkeypatch.setattr(sys, "argv", ["winnow", str(photos), "--max-memory", "512"])

    exit_code = main()

    assert exit_code == 0
    assert _FakeWindow.last_instance.max_memory_mb == 512.0


def test_main_default_max_memory(monkeypatch, tmp_path):
    """Without --max-memory, MainWindow gets the documented default."""
    import winnow.app as app_module

    photos = tmp_path / "photos"
    photos.mkdir()

    monkeypatch.setattr(app_module, "MainWindow", _FakeWindow)
    monkeypatch.setattr(app_module, "QApplication", _FakeApp)
    monkeypatch.setattr(sys, "argv", ["winnow", str(photos)])

    main()

    assert _FakeWindow.last_instance.max_memory_mb == 24576.0


def test_main_version_exits_cleanly(monkeypatch, capsys):
    """--version prints the version and exits via SystemExit(0).

    Handled entirely by argparse's built-in "version" action during
    parse_args(), before any directory validation - no valid directory
    argument is needed.
    """
    monkeypatch.setattr(sys, "argv", ["winnow", "--version"])

    with pytest.raises(SystemExit) as exc_info:
        main()

    assert exc_info.value.code == 0
    captured = capsys.readouterr()
    assert "winnow" in captured.out

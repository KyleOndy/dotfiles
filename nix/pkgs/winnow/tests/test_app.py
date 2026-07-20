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

    def __init__(self, directory, max_memory_mb=8192.0):
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
    """Without --max-memory, MainWindow gets the RAM-fraction default.

    The default is computed once by argparse when the parser is built
    (default_max_memory_mb() called at add_argument time), so it's captured
    before main() runs; assert against that same call rather than a fixed
    literal, since the real default depends on the machine's physical RAM.
    """
    import winnow.app as app_module

    photos = tmp_path / "photos"
    photos.mkdir()

    monkeypatch.setattr(app_module, "MainWindow", _FakeWindow)
    monkeypatch.setattr(app_module, "QApplication", _FakeApp)
    monkeypatch.setattr(sys, "argv", ["winnow", str(photos)])

    expected_default = app_module.default_max_memory_mb()
    main()

    assert _FakeWindow.last_instance.max_memory_mb == expected_default


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


# default_max_memory_mb() tests
#
# The RAM-fraction arithmetic (given a byte count, computed via
# _physical_memory_bytes()) and the no-detection fallback are tested
# directly here. The platform-specific detection mechanics themselves
# (os.sysconf on Linux, ctypes/sysctlbyname on darwin) aren't re-verified
# against a real value - that's exercised by actually running winnow (see
# the port plan's on-device verification steps).


def test_default_max_memory_mb_is_40_percent_of_detected_ram(monkeypatch):
    """default_max_memory_mb() returns 40% of physical RAM, in MB."""
    import winnow.app as app_module

    sixteen_gib = 16 * 1024**3
    monkeypatch.setattr(app_module, "_physical_memory_bytes", lambda: sixteen_gib)

    result = app_module.default_max_memory_mb()

    assert result == pytest.approx(sixteen_gib * 0.4 / (1024 * 1024))


def test_default_max_memory_mb_falls_back_when_ram_undetected(monkeypatch):
    """default_max_memory_mb() falls back to a fixed value if RAM can't be read."""
    import winnow.app as app_module

    monkeypatch.setattr(app_module, "_physical_memory_bytes", lambda: None)

    result = app_module.default_max_memory_mb()

    assert result == app_module._FALLBACK_MAX_MEMORY_MB


def test_physical_memory_bytes_linux_uses_sysconf(monkeypatch):
    """_physical_memory_bytes() computes pages * page_size on non-darwin."""
    import winnow.app as app_module

    monkeypatch.setattr(sys, "platform", "linux")
    values = {"SC_PHYS_PAGES": 1000, "SC_PAGE_SIZE": 4096}
    monkeypatch.setattr(app_module.os, "sysconf", lambda name: values[name])

    assert app_module._physical_memory_bytes() == 1000 * 4096


def test_physical_memory_bytes_returns_none_on_sysconf_failure(monkeypatch):
    """_physical_memory_bytes() returns None rather than raising if sysconf fails."""
    import winnow.app as app_module

    monkeypatch.setattr(sys, "platform", "linux")

    def raise_value_error(name):
        raise ValueError(f"unsupported sysconf name: {name}")

    monkeypatch.setattr(app_module.os, "sysconf", raise_value_error)

    assert app_module._physical_memory_bytes() is None

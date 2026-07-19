import typer
import contextlib
import hashlib
import json
import shutil
from PIL import Image, ExifTags
import sqlite3
import subprocess
from dataclasses import dataclass
from typing_extensions import Annotated
import sys
import os
from xdg import xdg_cache_home
import time
import datetime
import logging
import gphoto2 as gp
from rich import filesize
from rich.console import Console
from rich.logging import RichHandler
from rich.progress import (
    BarColumn,
    DownloadColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
    TransferSpeedColumn,
)

app = typer.Typer()

UNKNOWN = "_unknown"

# Imported in this order: JPEGs (the SOOC library) first, then videos, then
# raws, so a dropped connection or an interrupted import still lands the
# most important files.
IMAGE_EXTENSIONS = [".jpg", ".jpeg"]
VIDEO_EXTENSIONS = [".mov"]
RAW_EXTENSIONS = [".raf"]
IMPORT_GROUPS = [IMAGE_EXTENSIONS, VIDEO_EXTENSIONS, RAW_EXTENSIONS]
GROUP_LABELS = ["JPEG", "MOV", "RAF"]


def group_counts(files):
    """Per-group (label, count) pairs and the grand total, via filter_files()."""
    counts = [
        (label, len(filter_files(files, extensions)))
        for label, extensions in zip(GROUP_LABELS, IMPORT_GROUPS)
    ]
    total = sum(count for _, count in counts)
    return counts, total


def group_sizes(files, size_of):
    """Per-group byte totals (keyed by label) and the grand total, mirroring
    group_counts() but weighted by size instead of file count. size_of(f) is
    f.size for camera files (already known from PTP metadata, no transfer
    required) or os.path.getsize for local paths."""
    sizes = {
        label: sum(size_of(f) for f in filter_files(files, extensions))
        for label, extensions in zip(GROUP_LABELS, IMPORT_GROUPS)
    }
    total = sum(sizes.values())
    return sizes, total


class ImportProgress:
    """Live overall + per-type progress for an import run, weighted by
    bytes rather than file count -- one huge video should not read the same
    as one tiny JPEG. A whole file's byte total is known upfront (camera
    sizes come from PTP metadata, local sizes from os.path.getsize), so
    begin_file()/end_file() alone produce a correct byte-weighted bar even
    if update_file() is never called. update_file() is an optional
    smoothing layer driven by a transfer's own progress callback when the
    underlying driver provides one (see camera()'s gphoto2 context wiring):
    it makes the bar move continuously during a single large file instead
    of jumping only once the whole file lands.

    When stdout is not an interactive terminal, degrades to periodic plain
    log lines instead of a live display (rich would otherwise write raw
    escape codes into a piped log)."""

    def __init__(self, console=None):
        self.console = console or Console()
        self.live = self.console.is_terminal
        self._progress = None
        self._overall_task = None
        self._type_task = None
        self._overall_bytes_done = 0
        self._overall_files_done = 0
        self._type_bytes_done = 0
        self._type_files_done = 0
        self._file_size = 0
        self._file_target = 0
        self._plain_bytes_done = 0
        self._plain_bytes_total = 0
        self._plain_files_done = 0
        self._plain_files_total = 0

    @contextlib.contextmanager
    def listing(self, message="Listing files..."):
        """Indeterminate spinner while enumerating source files."""
        if self.live:
            with self.console.status(message, spinner="dots"):
                yield
        else:
            self.console.print(message)
            yield

    @contextlib.contextmanager
    def run(self, total_bytes, total_files):
        """Owns the live display for the copy/import loop.

        While live, the root logger is temporarily pointed at a RichHandler
        bound to this same Console: Rich only knows how to keep a live
        display intact if log lines are routed through it too, otherwise a
        routine "have seen ..." skip or a collision warning (both expected,
        not rare) would be written straight to the tty and corrupt the
        redraw. Restored on exit regardless of what the rest of the CLI
        (fuji-settings, fuji-recipes) does with logging."""
        self._overall_bytes_done = 0
        self._overall_files_done = 0
        if self.live:
            self._progress = Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                BarColumn(),
                DownloadColumn(),
                TextColumn("{task.fields[files_done]}/{task.fields[files_total]}"),
                TransferSpeedColumn(),
                TimeRemainingColumn(),
                TimeElapsedColumn(),
                console=self.console,
            )
            root = logging.getLogger()
            previous_handlers = root.handlers
            root.handlers = [
                RichHandler(
                    console=self.console,
                    show_time=False,
                    show_path=False,
                    markup=False,
                )
            ]
            try:
                with self._progress:
                    self._overall_task = self._progress.add_task(
                        "Total",
                        total=total_bytes,
                        files_done=0,
                        files_total=total_files,
                    )
                    self._type_task = None
                    yield self
            finally:
                root.handlers = previous_handlers
        else:
            self._plain_bytes_done = 0
            self._plain_bytes_total = total_bytes
            self._plain_files_done = 0
            self._plain_files_total = total_files
            yield self

    def start_group(self, label, count, group_bytes):
        self._type_bytes_done = 0
        self._type_files_done = 0
        if self.live:
            self._type_task = self._progress.add_task(
                label, total=group_bytes, files_done=0, files_total=count
            )
        else:
            logging.info(f"{label}: {count} file(s), {filesize.decimal(group_bytes)}")

    def begin_file(self, size):
        """Call immediately before starting (or skipping) one file's
        transfer. size is the file's already-known total, so the bar can
        credit it correctly in end_file() even if no transfer callback ever
        fires for it."""
        self._file_size = size
        self._file_target = 0

    def set_transfer_target(self, target):
        """Called from the gphoto2 progress-start callback with the
        driver's reported size for the operation now beginning. Compared
        fractionally against begin_file()'s size in update_file(); a
        mismatch only changes how smoothly the fraction climbs, not the
        byte total credited -- end_file() always credits the full size."""
        self._file_target = target

    def update_file(self, current):
        """Optional smoothing: driven by the gphoto2 transfer-progress
        callback while a single file is mid-download. Guarded so a
        callback firing outside an active run() -- some drivers report
        progress during camera init too -- is a no-op rather than touching
        a live display that may not exist yet."""
        if not self.live or self._overall_task is None or self._file_target <= 0:
            return
        frac = min(1.0, max(0.0, current / self._file_target))
        done = self._file_size * frac
        self._progress.update(
            self._overall_task, completed=self._overall_bytes_done + done
        )
        if self._type_task is not None:
            self._progress.update(
                self._type_task, completed=self._type_bytes_done + done
            )

    def end_file(self):
        """Call after one file's transfer (or skip) completes. Credits the
        file's full size exactly, regardless of whether update_file() ever
        fired -- so a driver that emits no progress callbacks still
        produces a correct byte-weighted bar, just in whole-file jumps
        instead of a smooth stream."""
        if self.live:
            if self._overall_task is None:
                return
            self._overall_bytes_done += self._file_size
            self._overall_files_done += 1
            self._progress.update(
                self._overall_task,
                completed=self._overall_bytes_done,
                files_done=self._overall_files_done,
            )
            if self._type_task is not None:
                self._type_bytes_done += self._file_size
                self._type_files_done += 1
                self._progress.update(
                    self._type_task,
                    completed=self._type_bytes_done,
                    files_done=self._type_files_done,
                )
            return
        self._plain_bytes_done += self._file_size
        self._plain_files_done += 1
        # Periodic, not per-file: roughly 20 log lines regardless of total,
        # plus always the final one, so a piped/non-interactive run gets
        # feedback without a line per file.
        step = max(1, self._plain_files_total // 20)
        if (
            self._plain_files_done % step == 0
            or self._plain_files_done == self._plain_files_total
        ):
            pct = (
                100 * self._plain_bytes_done / self._plain_bytes_total
                if self._plain_bytes_total
                else 100
            )
            logging.info(
                f"Total {self._plain_files_done}/{self._plain_files_total} files, "
                f"{filesize.decimal(self._plain_bytes_done)}/"
                f"{filesize.decimal(self._plain_bytes_total)} ({pct:.0f}%)"
            )


class NullProgress:
    """No-op progress used when an inner call must stay quiet, e.g. the
    camera command's internal library-move step, so it doesn't open a second
    live display nested inside the camera download's."""

    @contextlib.contextmanager
    def listing(self, message=None):
        yield

    @contextlib.contextmanager
    def run(self, total_bytes, total_files):
        yield self

    def start_group(self, label, count, group_bytes):
        pass

    def begin_file(self, size):
        pass

    def update_file(self, current):
        pass

    def end_file(self):
        pass


@app.command()
def camera(
    ctx: typer.Context,
    force_download: Annotated[
        bool,
        typer.Option(
            "--force-download",
            help=(
                "Skip the pre-download dedup check and re-transfer every "
                "file off the camera, even ones already imported. The md5 "
                "content dedup still runs afterward, so nothing already in "
                "the library gets re-added -- use this if the fast metadata "
                "skip is ever suspected of skipping something it shouldn't."
            ),
        ),
    ] = False,
):
    db = ctx.obj.db_path
    logging.debug(f"db path: {db}")
    init_db(db)
    dte = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    cache = os.path.join(xdg_cache_home(), "helios", "imports", dte)
    logging.debug(f"using cache: {cache}")
    os.makedirs(cache, exist_ok=True)

    gp.check_result(gp.use_python_logging())
    logging.info("starting import from camera. Connecting...")
    context = gp.gp_context_new()
    camera, serial = connect_to_camera(context)
    logging.debug("Getting list of files from camera.")
    progress = ImportProgress()

    # Sub-file streaming: if the camera's PTP driver reports transfer
    # progress (not all do -- see python-gphoto2's own
    # context_with_callbacks.py example, which notes some Canon bodies only
    # report it during camera.init), the bar moves continuously through one
    # big file instead of jumping only once it lands. update_file() no-ops
    # outside an active progress.run(), so a callback firing during
    # init/listing below is harmless.
    def _progress_start(ctx_, target, text, data):
        progress.set_transfer_target(target)
        return 1

    def _progress_update(ctx_, progress_id, current, data):
        progress.update_file(current)

    def _progress_stop(ctx_, progress_id, data):
        pass

    # The return value is an opaque SWIG object that must be kept alive for
    # as long as the callbacks might fire (python-gphoto2 frees them once
    # this is garbage collected), hence the otherwise-unused local.
    progress_callbacks = gp.gp_context_set_progress_funcs(
        context, _progress_start, _progress_update, _progress_stop, None
    )

    with progress.listing("Listing files on camera..."):
        camera_files = list_camera_files(camera)
    if not camera_files:
        logging.warning("No files found")
        sys.exit(0)

    # Dual-card backup recording (e.g. the X-T5 set to write both slots)
    # exposes the same capture once per slot, byte-identical. Collapse to
    # one entry per capture before we even consider downloading, so the
    # mirror is never fetched twice in a single run.
    deduped = dedupe_camera_files(camera_files)
    mirrored = len(camera_files) - len(deduped)
    if mirrored:
        logging.debug(
            f"{mirrored} file(s) were identical mirror copies across storages/slots"
        )
    camera_files = deduped

    _, total_files = group_counts(camera_files)
    group_bytes, total_bytes = group_sizes(camera_files, lambda f: f.size)
    provisional_dir = os.path.join(ctx.obj.photo_dir, "_provisional")

    # Download and import one media type at a time (JPEGs, then videos, then
    # raws), so a dropped connection partway through still leaves the
    # earlier, more important groups fully downloaded and imported rather
    # than stranded in the cache. Nothing is recorded as imported here; the
    # filesystem import below is the sole place that marks a photo imported
    # (by content md5), and only after it is safely in the library. That way
    # an aborted or interrupted import never orphans a photo: it just gets
    # re-downloaded and re-considered next run.
    #
    # Before that: a cheap, conservative pre-download check (camera serial +
    # name + size + mtime, all readable from the camera without transferring
    # file content) can skip the USB transfer itself for a file already
    # known to be imported. Any mismatch just falls through to a real
    # download -- the md5 dedup below remains the sole authority on what
    # lands in the library, so a wrong skip-check miss costs at worst a
    # redundant download, never a duplicate or a dropped photo.
    # --force-download bypasses the skip check entirely.
    with progress.run(total_bytes, total_files):
        for group_index, (label, extensions) in enumerate(
            zip(GROUP_LABELS, IMPORT_GROUPS)
        ):
            group_files = filter_files(camera_files, extensions)
            if not group_files:
                continue
            progress.start_group(label, len(group_files), group_bytes[label])
            group_cache = os.path.join(cache, str(group_index))
            os.makedirs(group_cache, exist_ok=True)
            for f in group_files:
                progress.begin_file(f.size)
                if not force_download and check_camera_file_seen(
                    db, serial, f.name, f.size, f.mtime
                ):
                    logging.debug(
                        f"skipping download of {f}: already imported "
                        "(matched by camera serial, name, size, mtime)"
                    )
                    progress.end_file()
                    continue
                dst = os.path.join(group_cache, f.name)
                logging.debug(f"copying from camera: {f} -> {dst}")
                camera_file = gp.check_result(
                    gp.gp_camera_file_get(
                        camera, f.folder, f.name, gp.GP_FILE_TYPE_NORMAL, None, context
                    )
                )
                gp.check_result(gp.gp_file_save(camera_file, dst))
                mark_camera_file_seen(db, serial, f.name, f.size, f.mtime, md5(dst))
                progress.end_file()
            # Quiet: this is a fast, local, already-accounted-for step (the
            # progress bars above already ticked once per file as it was
            # downloaded), and rich only supports one live display at a time.
            _run_filesystem_import(
                db,
                group_cache,
                provisional_dir,
                move=True,
                prune=False,
                clobber=False,
                progress=NullProgress(),
            )

    shutil.rmtree(cache)


@app.command()
def filesystem(
    ctx: typer.Context,
    src: str,
    move: Annotated[bool, typer.Option(help="Move files instead of copying")] = False,
    prune: Annotated[
        bool,
        typer.Option(
            help="DANGER! Remove files that already have been imported when seen"
        ),
    ] = False,
    clobber: Annotated[
        bool, typer.Option(help="Clobber files that exist at destination")
    ] = False,
):
    db = ctx.obj.db_path
    init_db(db)
    logging.info(f"importing from filesystem at '{src}'")
    logging.info(f"Files will be moved instead of copied: {move}")

    # TODO: refactor out to somewhere
    PROVISIONAL_DIR = os.path.join(ctx.obj.photo_dir, "_provisional")

    _run_filesystem_import(
        db, src, PROVISIONAL_DIR, move, prune, clobber, progress=ImportProgress()
    )


def _run_filesystem_import(db, src, provisional_dir, move, prune, clobber, progress):
    all_files = get_all_files(src)
    ratings = scan_ratings(all_files)
    sizes = {f: os.path.getsize(f) for f in all_files}
    _, total_files = group_counts(all_files)
    group_bytes, total_bytes = group_sizes(all_files, sizes.__getitem__)
    with progress.run(total_bytes, total_files):
        for label, extensions in zip(GROUP_LABELS, IMPORT_GROUPS):
            group_files = filter_files(all_files, extensions)
            if not group_files:
                continue
            # Rated shots first (5* .. 1*), then unrated; os.walk order kept
            # within each rating tier because Python's sort is stable.
            group_files.sort(key=lambda f: ratings.get(f, 0), reverse=True)
            progress.start_group(label, len(group_files), group_bytes[label])
            for f in group_files:
                progress.begin_file(sizes[f])
                _import_file(db, f, provisional_dir, move, prune, clobber)
                progress.end_file()


def _import_file(db, f, provisional_dir, move, prune, clobber):
    logging.debug(f"file: {f}")
    timestamp = get_media_timestamp(f)
    logging.debug(f"{f} timestamp: {timestamp}")
    if timestamp is None:
        timestamp = UNKNOWN

    dest_dir = get_target_dir(provisional_dir, timestamp)
    f_name = os.path.basename(f)
    md5sum = md5(f)
    if check_is_file_seen_before(db, md5sum):
        logging.info(f"have seen {f} ({md5sum})")
        if prune:
            logging.info(f"Removing {f} since we are pruning")
            os.remove(f)
        return

    dst = os.path.join(dest_dir, f_name)
    if os.path.exists(dst) and not clobber:
        # Different content landed on the same name/date as an existing
        # photo (the seen-before check above already ruled out this
        # being the same file). Never abort the whole batch over one
        # collision: disambiguate with a content-derived suffix so both
        # photos are kept.
        base, ext = os.path.splitext(f_name)
        renamed = f"{base}_{md5sum[:8]}{ext}"
        logging.warning(
            f"{dst} already exists with different content; saving {f} as {renamed}"
        )
        dst = os.path.join(dest_dir, renamed)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if move:
        shutil.move(f, dst)
        logging.debug(f"moving {f} -> {dst}")
    else:
        shutil.copyfile(f, dst)
        logging.debug(f"copying {f} -> {dst}")
    mark_file_as_imported(db, f, md5sum)


def connect_to_camera(context=None):
    camera = gp.check_result(gp.gp_camera_new())
    while True:
        error = gp.gp_camera_init(camera, context)
        if error >= gp.GP_OK:
            # operation completed successfully so exit loop
            break
        if error != gp.GP_ERROR_MODEL_NOT_FOUND:
            # some other error we can't handle here
            raise gp.GPhoto2Error(error)
        # no camera, try again in 2 seconds
        logging.info("Can not find camera. Is it on?")
        time.sleep(2)
    logging.info("Found camera.")
    model, serial = get_camera_identity(camera)
    logging.info(f"Camera: {model or 'unknown model'} (serial {serial or 'unknown'})")
    return camera, serial


def get_camera_identity(camera):
    """Best-effort (model, serial) for a connected gphoto2 camera.

    Either value may be None if the body/driver does not expose it; the
    caller must tolerate that rather than failing the import."""
    model = None
    try:
        abilities = gp.check_result(gp.gp_camera_get_abilities(camera))
        model = abilities.model
    except gp.GPhoto2Error as e:
        logging.debug(f"could not read camera abilities: {e}")

    serial = None
    try:
        config = gp.check_result(gp.gp_camera_get_config(camera))
        widget = gp.check_result(gp.gp_widget_get_child_by_name(config, "serialnumber"))
        serial = gp.check_result(gp.gp_widget_get_value(widget))
    except gp.GPhoto2Error as e:
        # many bodies/modes do not expose a serialnumber widget
        logging.debug(f"could not read camera serial number: {e}")

    return model, serial


@dataclass(frozen=True)
class CameraFile:
    """A file on the camera's PTP filesystem, with the size and mtime
    gp_camera_file_get_info() reports without transferring any file content.
    Cheap enough to fetch for every enumerated file, and what the
    pre-download dedup skip (see check_camera_file_seen) keys off of."""

    folder: str
    name: str
    size: int
    mtime: int

    @property
    def path(self):
        return os.path.join(self.folder, self.name)

    def __fspath__(self):
        # Lets filter_files()/os.path.splitext() and friends treat a
        # CameraFile like a plain path string without special-casing it.
        return self.path

    def __str__(self):
        return self.path


def list_camera_files(camera, path="/"):
    result = []
    # get files
    gp_list = gp.check_result(gp.gp_camera_folder_list_files(camera, path))
    for name, _ in gp_list:
        info = gp.check_result(gp.gp_camera_file_get_info(camera, path, name))
        result.append(
            CameraFile(
                folder=path, name=name, size=info.file.size, mtime=info.file.mtime
            )
        )
    # read folders
    folders = []
    gp_list = gp.check_result(gp.gp_camera_folder_list_folders(camera, path))
    for name, _ in gp_list:
        folders.append(name)
    # recurse over subfolders
    for name in folders:
        result.extend(list_camera_files(camera, os.path.join(path, name)))
    return result


def dedupe_camera_files(files):
    """Collapse duplicate captures that share an identical (name, size,
    mtime) -- e.g. a dual-SD-card body (the X-T5 in Backup mode) exposes
    the same capture once per card/slot. Keeps the first-seen copy; order
    comes from list_camera_files(), which walks SLOT 1 before SLOT 2."""
    seen = set()
    deduped = []
    for f in files:
        key = (f.name, f.size, f.mtime)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(f)
    return deduped


# TODO: better handling of "constants"
FILE_IMPORT_TABLE = "file_imports"
CAMERA_FILE_TABLE = "camera_files"


def init_db(db_path):
    dir = os.path.dirname(db_path)
    os.makedirs(dir, exist_ok=True)
    cmd = f"""
    create table if not exists {FILE_IMPORT_TABLE} (
        file_name TEXT NOT NULL,
        md5 TEXT NOT NULL,
        timestamp TEXT NOT NULL
        );
    create table if not exists {CAMERA_FILE_TABLE} (
        serial TEXT NOT NULL,
        name TEXT NOT NULL,
        size INTEGER NOT NULL,
        mtime INTEGER NOT NULL,
        md5 TEXT NOT NULL,
        imported_at TEXT NOT NULL,
        UNIQUE(serial, name, size, mtime)
        );
      """
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        con.executescript(cmd)
        con.commit()


def get_target_dir(parent_dir, timestamp):
    if timestamp == UNKNOWN:
        return os.path.join(parent_dir, timestamp)

    desired_format = "%Y/%Y_%m_%d/"
    dte = datetime.datetime.strftime(timestamp, desired_format)

    return os.path.join(parent_dir, dte)


def get_all_files(dir):
    result = []
    for root, dirs, files in os.walk(dir):
        for name in files:
            result.append(os.path.join(root, name))
    return result


def scan_ratings(files):
    """Map each path to its embedded star rating (0 when unrated/unknown).

    One batched exiftool call so a big RAF import does not pay per-file
    process startup. Files are fed on stdin to avoid ARG_MAX on large cards.
    """
    if not files:
        return {}
    try:
        # No check=True: exiftool exits non-zero when even one file in the
        # batch is unreadable (e.g. a race, permissions), but still emits
        # valid JSON for every file it *could* read. Failing the whole batch
        # over one bad file would silently drop rating-based ordering for
        # everything else, which defeats the point.
        result = subprocess.run(
            ["exiftool", "-@", "-", "-j", "-n", "-Rating"],
            input="\n".join(files),
            capture_output=True,
            text=True,
        )
        entries = json.loads(result.stdout or "[]")
    except (FileNotFoundError, OSError, ValueError) as e:
        logging.warning(f"rating scan failed, importing unsorted ({e})")
        return {}

    ratings = {}
    for entry in entries:
        src = entry.get("SourceFile")
        rating = entry.get("Rating")
        try:
            ratings[src] = int(rating) if rating is not None else 0
        except (TypeError, ValueError):
            ratings[src] = 0
    return ratings


def get_exif_data(image_path):
    IFD_CODE_LOOKUP = {i.value: i.name for i in ExifTags.IFD}
    tags = {}

    try:
        with Image.open(image_path) as img:
            img_exif = img.getexif()
            for tag_code, value in img_exif.items():
                # if the tag is an IFD block, nest into it
                if tag_code in IFD_CODE_LOOKUP:
                    ifd_tag_name = IFD_CODE_LOOKUP[tag_code]
                    # print(f"IFD '{ifd_tag_name}' (code {tag_code}):")
                    ifd_data = img_exif.get_ifd(tag_code).items()

                    for nested_key, nested_value in ifd_data:
                        nested_tag_name = (
                            ExifTags.GPSTAGS.get(nested_key, None)
                            or ExifTags.TAGS.get(nested_key, None)
                            or nested_key
                        )
                        # print(f"  {nested_tag_name}: {nested_value}")
                        tags[nested_tag_name] = nested_value
                else:
                    # root-level tag
                    # print(f"{ExifTags.TAGS.get(tag_code)}: {value}")
                    tags[tag_code] = value
    except (OSError, SyntaxError) as e:
        # corrupt file, or an extension-spoofed non-image; treat as no EXIF
        logging.warning(f"{image_path} is not a readable image ({e})")
        return {}

    return tags


def get_image_timestamp(image_path):
    tags = get_exif_data(image_path)

    if not tags:
        # some facebook rip or something
        return None

    if "DateTimeOriginal" in tags:
        # 2023:10:01 12:05:05
        raw = tags["DateTimeOriginal"]
    elif "DateTime" in tags:
        raw = tags["DateTime"]
    elif "DateTimeDigitized" in tags:
        raw = tags["DateTimeDigitized"]
    elif 36867 in tags:
        raw = tags[36867]
    elif 306 in tags:
        raw = tags[306]
    else:
        return None

    try:
        return datetime.datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
    except ValueError:
        logging.warning(f"{image_path} has an unparseable EXIF date {raw!r}")
        return None


EXIFTOOL_DATE_TAGS = ["DateTimeOriginal", "CreateDate", "MediaCreateDate"]


def get_media_timestamp(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in IMAGE_EXTENSIONS:
        return get_image_timestamp(path)
    # PIL can't open RAF or MOV; shell out to exiftool instead.
    return get_exiftool_timestamp(path)


def get_exiftool_timestamp(path):
    try:
        result = subprocess.run(
            [
                "exiftool",
                "-T",
                "-d",
                "%Y:%m:%d %H:%M:%S",
                *(f"-{tag}" for tag in EXIFTOOL_DATE_TAGS),
                path,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as e:
        logging.warning(f"{path}: exiftool failed ({e})")
        return None

    for raw in result.stdout.strip().split("\t"):
        if raw in ("", "-"):
            continue
        try:
            return datetime.datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
        except ValueError:
            continue
    return None


def md5(fname):
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


def check_is_file_seen_before(db_path, md5sum):
    sql = f"SELECT EXISTS(SELECT 1 FROM {FILE_IMPORT_TABLE} WHERE md5=?)"
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        cur = con.execute(sql, (md5sum,))
        return cur.fetchone() == (1,)


def mark_file_as_imported(db_path, file_name, md5sum):
    sql = f"INSERT INTO {FILE_IMPORT_TABLE} VALUES (?,?,CURRENT_TIMESTAMP)"
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        con.execute(sql, (file_name, md5sum))
        con.commit()


def check_camera_file_seen(db_path, serial, name, size, mtime):
    """Conservative pre-download check: true only when a file matching this
    exact (serial, name, size, mtime) has already been downloaded and
    recorded. A miss (including an unreadable serial) just means "download
    it" -- the md5 dedup after download remains the sole authority on
    whether it enters the library."""
    if serial is None:
        # Can't scope the key to a specific camera body, so never skip on
        # an unreadable serial -- always fall through to a full download.
        return False
    sql = (
        f"SELECT EXISTS(SELECT 1 FROM {CAMERA_FILE_TABLE} "
        "WHERE serial=? AND name=? AND size=? AND mtime=?)"
    )
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        cur = con.execute(sql, (serial, name, size, mtime))
        return cur.fetchone() == (1,)


def mark_camera_file_seen(db_path, serial, name, size, mtime, md5sum):
    if serial is None:
        # Would never be matched by check_camera_file_seen()'s serial=None
        # guard above, so there is no point persisting it.
        return
    sql = (
        f"INSERT OR REPLACE INTO {CAMERA_FILE_TABLE} "
        "(serial, name, size, mtime, md5, imported_at) "
        "VALUES (?,?,?,?,?,CURRENT_TIMESTAMP)"
    )
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        con.execute(sql, (serial, name, size, mtime, md5sum))
        con.commit()


def filter_files(files, allowed_extensions):
    # TODO: handle these cases in a better way
    # TODO: allow passing in via CLI
    filtered = []
    for f in files:
        extension = os.path.splitext(f)[1]
        if extension.lower() not in allowed_extensions:
            logging.debug(
                f"Skipping {f} as it is not a supported file extension. Supported extensions are {allowed_extensions}"
            )
            continue
        filtered.append(f)
    return filtered


if __name__ == "__main__":
    app()

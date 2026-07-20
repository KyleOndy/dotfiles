import typer
import contextlib
import hashlib
import json
import shutil
from collections import Counter
from PIL import Image, ExifTags
import sqlite3
import subprocess
from dataclasses import dataclass, field
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

# Imported in this order: JPEGs (the SOOC library) first, then HEIFs, then
# videos, then raws, so a dropped connection or an interrupted import still
# lands the most important files.
IMAGE_EXTENSIONS = [".jpg", ".jpeg"]
HEIF_EXTENSIONS = [".hif", ".heic"]
VIDEO_EXTENSIONS = [".mov"]
RAW_EXTENSIONS = [".raf"]
IMPORT_GROUPS = [IMAGE_EXTENSIONS, HEIF_EXTENSIONS, VIDEO_EXTENSIONS, RAW_EXTENSIONS]
GROUP_LABELS = ["JPEG", "HEIF", "MOV", "RAF"]
MEDIA_EXTENSIONS = [ext for group in IMPORT_GROUPS for ext in group]

# One filesystem read per imported file: the same chunks feed both the md5
# and the destination write.
CHUNK_SIZE = 1024 * 1024


def filter_files(files, allowed_extensions):
    return [f for f in files if os.path.splitext(f)[1].lower() in allowed_extensions]


def group_files_by_type(files):
    """One {label: files} dict per run, in import order, so counting,
    sizing, and the import loop all share the same lists."""
    return {
        label: filter_files(files, extensions)
        for label, extensions in zip(GROUP_LABELS, IMPORT_GROUPS)
    }


@dataclass
class ImportSummary:
    """End-of-run accounting, logged loudly on purpose: these numbers are
    what you sanity-check before wiping a card. In particular unhandled
    extensions must never disappear silently -- a card of files we do not
    recognize should look like a problem, not like a clean import."""

    imported: int = 0
    seen: int = 0
    skipped_metadata: int = 0
    failed: int = 0
    unhandled: Counter = field(default_factory=Counter)

    @property
    def total_media(self):
        return self.imported + self.seen + self.skipped_metadata + self.failed

    def merge(self, other):
        self.imported += other.imported
        self.seen += other.seen
        self.skipped_metadata += other.skipped_metadata
        self.failed += other.failed
        self.unhandled.update(other.unhandled)

    def log(self):
        logging.info(
            f"imported {self.imported}, skipped {self.seen} by content and "
            f"{self.skipped_metadata} by metadata, {self.failed} failed"
        )
        if self.unhandled:
            detail = ", ".join(
                f"{ext} x{count}" for ext, count in sorted(self.unhandled.items())
            )
            logging.warning(f"ignored unsupported files: {detail}")


class ImportProgress:
    """Live overall + per-type progress for an import run, weighted by
    bytes rather than file count -- one huge video should not read the same
    as one tiny JPEG. A whole file's byte total is known upfront (camera
    sizes come from PTP metadata, local sizes from os.stat), so
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
    imports_root = os.path.join(xdg_cache_home(), "helios", "imports")
    warn_stale_import_caches(imports_root)
    dte = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    cache = os.path.join(imports_root, dte)
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

    summary = ImportSummary()
    for f in camera_files:
        ext = os.path.splitext(f.name)[1].lower()
        if ext not in MEDIA_EXTENSIONS:
            summary.unhandled[ext or "(no extension)"] += 1
    groups = group_files_by_type(camera_files)
    group_bytes = {label: sum(f.size for f in files) for label, files in groups.items()}
    total_bytes = sum(group_bytes.values())
    total_files = sum(len(files) for files in groups.values())
    provisional_dir = os.path.join(ctx.obj.photo_dir, "_provisional")

    # Download and import one media type at a time (JPEGs, then HEIFs, then
    # videos, then raws), so a dropped connection partway through still
    # leaves the earlier, more important groups fully downloaded and
    # imported rather than stranded in the cache. The filesystem import
    # below is the sole place that marks a photo imported (by content md5),
    # and only after it is durably in the library; the camera_files marker
    # written right after each download only ever skips a transfer when its
    # md5 also shows up there (see check_camera_file_seen), so an aborted
    # or interrupted import never orphans a photo -- it just gets
    # re-downloaded and re-considered next run.
    #
    # The pre-download check (camera serial + name + size + mtime, all
    # readable from the camera without transferring file content) skips the
    # USB transfer itself for a file already known to be imported. Any
    # mismatch just falls through to a real download -- the md5 dedup below
    # remains the sole authority on what lands in the library, so a wrong
    # skip-check miss costs at worst a redundant download, never a
    # duplicate or a dropped photo. --force-download bypasses the skip
    # check entirely.
    with contextlib.closing(open_db(db)) as con:
        with progress.run(total_bytes, total_files):
            for group_index, label in enumerate(GROUP_LABELS):
                group_files = groups[label]
                if not group_files:
                    continue
                progress.start_group(label, len(group_files), group_bytes[label])
                group_cache = os.path.join(cache, str(group_index))
                os.makedirs(group_cache, exist_ok=True)
                for f in group_files:
                    progress.begin_file(f.size)
                    if not force_download and check_camera_file_seen(
                        con, serial, f.name, f.size, f.mtime
                    ):
                        logging.debug(
                            f"skipping download of {f}: already imported "
                            "(matched by camera serial, name, size, mtime)"
                        )
                        summary.skipped_metadata += 1
                        progress.end_file()
                        continue
                    dst = os.path.join(group_cache, f.name)
                    logging.debug(f"copying from camera: {f} -> {dst}")
                    try:
                        camera_file = gp.check_result(
                            gp.gp_camera_file_get(
                                camera,
                                f.folder,
                                f.name,
                                gp.GP_FILE_TYPE_NORMAL,
                                None,
                                context,
                            )
                        )
                        gp.check_result(gp.gp_file_save(camera_file, dst))
                    except gp.GPhoto2Error as e:
                        # A failed transfer can leave a partial file behind;
                        # remove it so the group import below cannot land a
                        # truncated photo in the library.
                        with contextlib.suppress(OSError):
                            os.remove(dst)
                        msg = f"download of {f} failed ({e}); leaving it on the camera"
                        if os.path.splitext(f.name)[1].lower() in VIDEO_EXTENSIONS:
                            msg += (
                                "; files over 4GB exceed the PTP transfer "
                                "limit, import them from the card with "
                                "'helios import filesystem'"
                            )
                        logging.warning(msg)
                        summary.failed += 1
                        progress.end_file()
                        continue
                    mark_camera_file_seen(
                        con, serial, f.name, f.size, f.mtime, md5(dst)
                    )
                    progress.end_file()
                # Quiet: this is a fast, local, already-accounted-for step
                # (the progress bars above already ticked once per file as
                # it was downloaded), and rich only supports one live
                # display at a time.
                summary.merge(
                    _run_filesystem_import(
                        con,
                        group_cache,
                        provisional_dir,
                        move=True,
                        force_hash=False,
                        progress=NullProgress(),
                    )
                )

    # Safe even after per-file failures: anything still in the cache is
    # either already in the library (its md5 was seen) or still on the
    # camera and will re-download next run, because check_camera_file_seen
    # only skips files whose md5 reached the library.
    shutil.rmtree(cache)
    summary.log()
    if summary.failed:
        raise typer.Exit(1)


def warn_stale_import_caches(imports_root):
    """A crashed camera import leaves its cache dir behind, and if the card
    was formatted since, that cache may hold the only copy of those photos.
    Point at them loudly and never delete them automatically."""
    if not os.path.isdir(imports_root):
        return
    for name in sorted(os.listdir(imports_root)):
        path = os.path.join(imports_root, name)
        if not os.path.isdir(path):
            continue
        if any(files for _, _, files in os.walk(path)):
            logging.warning(
                f"leftover import cache from an interrupted run: {path} -- "
                f"it may hold photos not yet imported. Recover with "
                f"'helios import filesystem {path} --move', then remove the "
                "directory."
            )


@app.command()
def filesystem(
    ctx: typer.Context,
    src: str,
    move: Annotated[bool, typer.Option(help="Move files instead of copying")] = False,
    force_hash: Annotated[
        bool,
        typer.Option(
            "--force-hash",
            help=(
                "Skip the fast metadata (name, size, mtime) check and "
                "verify every file by content hash -- use this if the fast "
                "skip is ever suspected of skipping something it shouldn't."
            ),
        ),
    ] = False,
):
    db = ctx.obj.db_path
    if not os.path.isdir(src):
        logging.error(f"source directory does not exist: {src}")
        raise typer.Exit(1)
    # Importing the library into itself is never intended: every file is
    # its own duplicate, and with --move it reshuffles the library.
    src_real = os.path.realpath(src)
    library_real = os.path.realpath(ctx.obj.photo_dir)
    if src_real == library_real or src_real.startswith(library_real + os.sep):
        logging.error(
            f"refusing to import from inside the library "
            f"({src} is under {ctx.obj.photo_dir})"
        )
        raise typer.Exit(1)

    logging.info(f"importing from filesystem at '{src}'")
    logging.info(f"Files will be moved instead of copied: {move}")

    provisional_dir = os.path.join(ctx.obj.photo_dir, "_provisional")
    with contextlib.closing(open_db(db)) as con:
        summary = _run_filesystem_import(
            con, src, provisional_dir, move, force_hash, progress=ImportProgress()
        )
    summary.log()
    if summary.total_media == 0:
        logging.error(f"no media files found under {src}")
        raise typer.Exit(1)
    if summary.failed:
        raise typer.Exit(1)


def _run_filesystem_import(con, src, provisional_dir, move, force_hash, progress):
    summary = ImportSummary()
    with progress.listing():
        all_files = get_all_files(src)

    media_files = []
    for f in all_files:
        ext = os.path.splitext(f)[1].lower()
        if ext in MEDIA_EXTENSIONS:
            media_files.append(f)
        else:
            logging.debug(f"ignoring unsupported file {f}")
            summary.unhandled[ext or "(no extension)"] += 1

    # Pass 1, cheap: stat every media file and drop the ones the metadata
    # skip already knows reached the library. No file content is read here,
    # so a re-run over an already-imported card gets through in seconds.
    stats = {}
    for f in media_files:
        try:
            st = os.stat(f)
        except OSError as e:
            # dangling symlink, or the file vanished since the walk
            logging.warning(f"cannot stat {f}, skipping ({e})")
            summary.failed += 1
            continue
        if not force_hash and check_filesystem_file_skip(
            con, os.path.basename(f), st.st_size, int(st.st_mtime)
        ):
            logging.debug(
                f"skipping {f}: already imported (matched by name, size, mtime)"
            )
            summary.skipped_metadata += 1
            continue
        stats[f] = st

    # Pass 2: one batched exiftool call over just the survivors, then the
    # import itself.
    metadata = scan_metadata(list(stats))
    groups = group_files_by_type(list(stats))
    group_bytes = {
        label: sum(stats[f].st_size for f in files) for label, files in groups.items()
    }
    with progress.run(sum(group_bytes.values()), len(stats)):
        for label in GROUP_LABELS:
            group_files = groups[label]
            if not group_files:
                continue
            # Rated shots first (5* .. 1*), then unrated; os.walk order kept
            # within each rating tier because Python's sort is stable.
            group_files.sort(key=lambda f: metadata.get(f, (0, None))[0], reverse=True)
            progress.start_group(label, len(group_files), group_bytes[label])
            for f in group_files:
                progress.begin_file(stats[f].st_size)
                try:
                    outcome = _import_file(
                        con,
                        f,
                        stats[f],
                        provisional_dir,
                        move,
                        _timestamp_for(f, metadata),
                    )
                except OSError as e:
                    logging.warning(f"failed to import {f} ({e})")
                    summary.failed += 1
                else:
                    if outcome == "imported":
                        summary.imported += 1
                    else:
                        summary.seen += 1
                progress.end_file()
    return summary


def _timestamp_for(path, metadata):
    ext = os.path.splitext(path)[1].lower()
    if ext in IMAGE_EXTENSIONS:
        # Pillow reads JPEG EXIF locally, no subprocess needed.
        return get_image_timestamp(path)
    if path in metadata:
        # Present in the batch output; a None timestamp there means the
        # file really has no date tags, so do not re-ask per file.
        return metadata[path][1]
    return get_exiftool_timestamp(path)


def _import_file(con, f, st, provisional_dir, move, timestamp):
    """Land one file in the library, atomically and durably.

    Order matters: the destination bytes are fsynced and renamed into
    place before the DB records the import. The dedup record must never
    claim content the disk does not durably hold, because everything else
    (skip checks, out-of-band card cleanup) trusts that record.

    Returns "imported" or "seen" for the run summary."""
    logging.debug(f"file: {f} timestamp: {timestamp}")
    if timestamp is None:
        timestamp = UNKNOWN
    dest_dir = get_target_dir(provisional_dir, timestamp)
    f_name = os.path.basename(f)
    os.makedirs(dest_dir, exist_ok=True)

    # A same-filesystem move needs no temp copy: hash the source in place
    # and rename it, which is already atomic.
    fast_move = move and st.st_dev == os.stat(dest_dir).st_dev

    tmp = None
    try:
        if fast_move:
            md5sum = md5(f)
        else:
            tmp = os.path.join(dest_dir, f".{f_name}.part")
            md5sum = copy_to_temp(f, tmp)

        if check_is_file_seen_before(con, md5sum):
            logging.info(f"have seen {f} ({md5sum})")
            mark_filesystem_file_seen(con, f_name, st, md5sum)
            return "seen"

        dst, already_present = resolve_destination(dest_dir, f_name, md5sum)
        if already_present:
            # A previous run landed this exact content but crashed before
            # recording it. Record it now; nothing to copy.
            logging.info(f"{dst} already holds this content; recording it as imported")
        else:
            if fast_move:
                fsync_file(f)
                os.rename(f, dst)
            else:
                fsync_file(tmp)
                os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
                os.rename(tmp, dst)
                tmp = None
            fsync_dir(dest_dir)
            logging.debug(f"{'moved' if move else 'copied'} {f} -> {dst}")
        mark_file_as_imported(con, f, md5sum)
        mark_filesystem_file_seen(con, f_name, st, md5sum)
        if move and not fast_move and not already_present:
            try:
                os.remove(f)
            except OSError as e:
                # e.g. a read-only card; the import itself succeeded
                logging.warning(f"imported {f} but could not remove the source ({e})")
        return "imported"
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.remove(tmp)


def copy_to_temp(src, tmp):
    """Stream src into tmp, hashing as it goes: one read of the source
    serves both the dedup md5 and the copy. Returns the md5 hexdigest."""
    digest = hashlib.md5()
    with open(src, "rb") as fsrc, open(tmp, "wb") as fdst:
        while chunk := fsrc.read(CHUNK_SIZE):
            digest.update(chunk)
            fdst.write(chunk)
    return digest.hexdigest()


def resolve_destination(dest_dir, f_name, md5sum):
    """Pick the final path for new content, disambiguating name
    collisions. Returns (dst, already_present); already_present means dst
    holds byte-identical content from a previous run that crashed before
    recording it, so there is nothing left to copy."""
    dst = os.path.join(dest_dir, f_name)
    if not os.path.exists(dst):
        return dst, False
    if md5(dst) == md5sum:
        return dst, True
    # Different content landed on the same name/date as an existing photo.
    # Never abort the whole batch over one collision: disambiguate with a
    # content-derived suffix so both photos are kept.
    base, ext = os.path.splitext(f_name)
    renamed = f"{base}_{md5sum[:8]}{ext}"
    logging.warning(f"{dst} already exists with different content; saving as {renamed}")
    dst = os.path.join(dest_dir, renamed)
    if os.path.exists(dst) and md5(dst) == md5sum:
        return dst, True
    return dst, False


def fsync_file(path):
    with open(path, "rb") as f:
        os.fsync(f.fileno())


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


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


FILE_IMPORT_TABLE = "file_imports"
CAMERA_FILE_TABLE = "camera_files"
FILESYSTEM_FILE_TABLE = "filesystem_files"

SCHEMA = f"""
create table if not exists {FILE_IMPORT_TABLE} (
    file_name TEXT NOT NULL,
    md5 TEXT NOT NULL,
    timestamp TEXT NOT NULL
    );
create index if not exists file_imports_md5 on {FILE_IMPORT_TABLE}(md5);
create table if not exists {CAMERA_FILE_TABLE} (
    serial TEXT NOT NULL,
    name TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    md5 TEXT NOT NULL,
    imported_at TEXT NOT NULL,
    UNIQUE(serial, name, size, mtime)
    );
create table if not exists {FILESYSTEM_FILE_TABLE} (
    name TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    md5 TEXT NOT NULL,
    imported_at TEXT NOT NULL,
    UNIQUE(name, size, mtime)
    );
"""


def open_db(db_path):
    """One connection per command run, passed down through the import;
    reconnecting per file was measurable overhead on large imports."""
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    con = sqlite3.connect(db_path)
    con.executescript(SCHEMA)
    con.commit()
    return con


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


EXIFTOOL_DATE_TAGS = ["DateTimeOriginal", "CreateDate", "MediaCreateDate"]


def scan_metadata(files):
    """Map each path to (star rating, timestamp): rating 0 when unrated,
    timestamp None when no date tag parses.

    One batched exiftool call so a big import does not pay per-file Perl
    startup. Files are fed on stdin to avoid ARG_MAX on large cards.
    -Rating# disables print conversion for just that tag, so -d still
    formats the date tags."""
    if not files:
        return {}
    try:
        # No check=True: exiftool exits non-zero when even one file in the
        # batch is unreadable (e.g. a race, permissions), but still emits
        # valid JSON for every file it *could* read. Failing the whole
        # batch over one bad file would drop ratings and timestamps for
        # everything else, which defeats the point.
        result = subprocess.run(
            [
                "exiftool",
                "-@",
                "-",
                "-j",
                "-d",
                "%Y:%m:%d %H:%M:%S",
                "-Rating#",
                *(f"-{tag}" for tag in EXIFTOOL_DATE_TAGS),
            ],
            input="\n".join(files),
            capture_output=True,
            text=True,
        )
        entries = json.loads(result.stdout or "[]")
    except (FileNotFoundError, OSError, ValueError) as e:
        logging.warning(f"batched metadata scan failed, falling back per file ({e})")
        return {}

    metadata = {}
    for entry in entries:
        src = entry.get("SourceFile")
        if src is None:
            continue
        try:
            rating = int(entry.get("Rating") or 0)
        except (TypeError, ValueError):
            rating = 0
        timestamp = None
        for tag in EXIFTOOL_DATE_TAGS:
            raw = entry.get(tag)
            if not raw:
                continue
            try:
                timestamp = datetime.datetime.strptime(str(raw), "%Y:%m:%d %H:%M:%S")
                break
            except ValueError:
                continue
        metadata[src] = (rating, timestamp)
    return metadata


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
                    ifd_data = img_exif.get_ifd(tag_code).items()

                    for nested_key, nested_value in ifd_data:
                        nested_tag_name = (
                            ExifTags.GPSTAGS.get(nested_key, None)
                            or ExifTags.TAGS.get(nested_key, None)
                            or nested_key
                        )
                        tags[nested_tag_name] = nested_value
                else:
                    # root-level tag, keyed by its numeric code
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

    # Nested Exif-IFD tags are keyed by name, root-level tags by numeric
    # code (306 is DateTime).
    if "DateTimeOriginal" in tags:
        # 2023:10:01 12:05:05
        raw = tags["DateTimeOriginal"]
    elif "DateTimeDigitized" in tags:
        raw = tags["DateTimeDigitized"]
    elif 306 in tags:
        raw = tags[306]
    else:
        return None

    try:
        return datetime.datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
    except ValueError:
        logging.warning(f"{image_path} has an unparseable EXIF date {raw!r}")
        return None


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
    with open(fname, "rb") as f:
        return hashlib.file_digest(f, "md5").hexdigest()


def check_is_file_seen_before(con, md5sum):
    sql = f"SELECT EXISTS(SELECT 1 FROM {FILE_IMPORT_TABLE} WHERE md5=?)"
    return con.execute(sql, (md5sum,)).fetchone() == (1,)


def mark_file_as_imported(con, file_name, md5sum):
    sql = f"INSERT INTO {FILE_IMPORT_TABLE} VALUES (?,?,CURRENT_TIMESTAMP)"
    con.execute(sql, (file_name, md5sum))
    con.commit()


def check_filesystem_file_skip(con, name, size, mtime):
    """Fast re-import check: skip reading a file entirely when this exact
    (name, size, mtime) was recorded before AND its md5 demonstrably
    reached the library (the join). A miss just means "hash it" -- the md5
    dedup remains the sole authority on what enters the library, so the
    worst a wrong miss costs is a redundant hash, never a duplicate or a
    dropped photo."""
    sql = (
        f"SELECT EXISTS(SELECT 1 FROM {FILESYSTEM_FILE_TABLE} s "
        f"JOIN {FILE_IMPORT_TABLE} i ON i.md5 = s.md5 "
        "WHERE s.name=? AND s.size=? AND s.mtime=?)"
    )
    return con.execute(sql, (name, size, mtime)).fetchone() == (1,)


def mark_filesystem_file_seen(con, name, st, md5sum):
    sql = (
        f"INSERT OR REPLACE INTO {FILESYSTEM_FILE_TABLE} "
        "(name, size, mtime, md5, imported_at) VALUES (?,?,?,?,CURRENT_TIMESTAMP)"
    )
    con.execute(sql, (name, st.st_size, int(st.st_mtime), md5sum))
    con.commit()


def check_camera_file_seen(con, serial, name, size, mtime):
    """Conservative pre-download check: true only when a file matching this
    exact (serial, name, size, mtime) has been downloaded AND its md5
    reached the library. The library join matters: the camera_files marker
    is written right after download, before the import, so without it a
    crash in between would make future runs skip a photo that never landed.
    A miss (including an unreadable serial) just means "download it"."""
    if serial is None:
        # Can't scope the key to a specific camera body, so never skip on
        # an unreadable serial -- always fall through to a full download.
        return False
    sql = (
        f"SELECT EXISTS(SELECT 1 FROM {CAMERA_FILE_TABLE} c "
        f"JOIN {FILE_IMPORT_TABLE} i ON i.md5 = c.md5 "
        "WHERE c.serial=? AND c.name=? AND c.size=? AND c.mtime=?)"
    )
    return con.execute(sql, (serial, name, size, mtime)).fetchone() == (1,)


def mark_camera_file_seen(con, serial, name, size, mtime, md5sum):
    if serial is None:
        # Would never be matched by check_camera_file_seen()'s serial=None
        # guard above, so there is no point persisting it.
        return
    sql = (
        f"INSERT OR REPLACE INTO {CAMERA_FILE_TABLE} "
        "(serial, name, size, mtime, md5, imported_at) "
        "VALUES (?,?,?,?,?,CURRENT_TIMESTAMP)"
    )
    con.execute(sql, (serial, name, size, mtime, md5sum))
    con.commit()


if __name__ == "__main__":
    app()

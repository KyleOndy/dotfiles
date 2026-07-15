import typer
import contextlib
import hashlib
import shutil
from PIL import Image, ExifTags
import sqlite3
import subprocess
from typing_extensions import Annotated
import sys
import os
from xdg import xdg_cache_home
import time
import datetime
import logging
import gphoto2 as gp

app = typer.Typer()

UNKNOWN = "_unknown"

# Imported in this order: JPEGs (the SOOC library) first, then videos, then
# raws, so a dropped connection or an interrupted import still lands the
# most important files.
IMAGE_EXTENSIONS = [".jpg", ".jpeg"]
VIDEO_EXTENSIONS = [".mov"]
RAW_EXTENSIONS = [".raf"]
IMPORT_GROUPS = [IMAGE_EXTENSIONS, VIDEO_EXTENSIONS, RAW_EXTENSIONS]


@app.command()
def camera(ctx: typer.Context):
    db = ctx.obj.db_path
    logging.debug(f"db path: {db}")
    init_db(db)
    dte = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    cache = os.path.join(xdg_cache_home(), "helios", "imports", dte)
    logging.debug(f"using cache: {cache}")
    os.makedirs(cache, exist_ok=True)

    gp.check_result(gp.use_python_logging())
    logging.info("starting import from camera. Connecting...")
    camera = connect_to_camera()
    logging.debug("Getting list of files from camera.")
    camera_files = list_camera_files(camera)
    if not camera_files:
        logging.warning("No files found")
        sys.exit(0)

    # Download and import one media type at a time (JPEGs, then videos, then
    # raws), so a dropped connection partway through still leaves the
    # earlier, more important groups fully downloaded and imported rather
    # than stranded in the cache. Nothing is recorded as imported here; the
    # filesystem() call below is the sole place that marks a photo imported
    # (by content md5), and only after it is safely in the library. That way
    # an aborted or interrupted import never orphans a photo: it just gets
    # re-downloaded and re-considered next run.
    for group_index, extensions in enumerate(IMPORT_GROUPS):
        group_files = filter_files(camera_files, extensions)
        if not group_files:
            continue
        group_cache = os.path.join(cache, str(group_index))
        os.makedirs(group_cache, exist_ok=True)
        for path in group_files:
            folder, name = os.path.split(path)
            dst = os.path.join(group_cache, name)
            logging.info("copying from camera: %s -> %s" % (path, dst))
            camera_file = gp.check_result(
                gp.gp_camera_file_get(camera, folder, name, gp.GP_FILE_TYPE_NORMAL)
            )
            gp.check_result(gp.gp_file_save(camera_file, dst))
        filesystem(ctx, group_cache, move=True, clobber=False)

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

    all_files = get_all_files(src)
    for extensions in IMPORT_GROUPS:
        for f in filter_files(all_files, extensions):
            _import_file(db, f, PROVISIONAL_DIR, move, prune, clobber)


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
        logging.info(f"moving {f} -> {dst}")
    else:
        shutil.copyfile(f, dst)
        logging.info(f"copying {f} -> {dst}")
    mark_file_as_imported(db, f, md5sum)


def connect_to_camera():
    camera = gp.check_result(gp.gp_camera_new())
    while True:
        error = gp.gp_camera_init(camera)
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
    return camera


def list_camera_files(camera, path="/"):
    result = []
    # get files
    gp_list = gp.check_result(gp.gp_camera_folder_list_files(camera, path))
    for name, _ in gp_list:
        result.append(os.path.join(path, name))
    # read folders
    folders = []
    gp_list = gp.check_result(gp.gp_camera_folder_list_folders(camera, path))
    for name, _ in gp_list:
        folders.append(name)
    # recurse over subfolders
    for name in folders:
        result.extend(list_camera_files(camera, os.path.join(path, name)))
    return result


# TODO: better handling of "constants"
FILE_IMPORT_TABLE = "file_imports"


def init_db(db_path):
    dir = os.path.dirname(db_path)
    os.makedirs(dir, exist_ok=True)
    cmd = f"""
    create table if not exists {FILE_IMPORT_TABLE} (
        file_name TEXT NOT NULL,
        md5 TEXT NOT NULL,
        timestamp TEXT NOT NULL
        );
      """
    with contextlib.closing(sqlite3.connect(db_path)) as con:
        con.execute(cmd)
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

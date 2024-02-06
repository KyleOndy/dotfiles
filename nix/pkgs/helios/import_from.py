import typer
import hashlib
import shutil
from PIL import Image, ExifTags
import sqlite3
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
SUPPORTED_EXTENSIONS = [".jpg", ".jpeg"]


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
    for path in filter_files(camera_files, SUPPORTED_EXTENSIONS):
        info = get_camera_file_info(camera, path)
        timestamp = datetime.datetime.fromtimestamp(info.file.mtime)
        folder, name = os.path.split(path)
        if has_photo_from_camera_been_imported(db, name, timestamp):
            logging.warning(
                f"Already imported a photo with name of '{name}' and a capture date of '{timestamp}'"
            )
        else:
            dst = os.path.join(cache, name)
            logging.info("copying from camera: %s -> %s" % (path, dst))
            camera_file = gp.check_result(
                gp.gp_camera_file_get(camera, folder, name, gp.GP_FILE_TYPE_NORMAL)
            )
            gp.check_result(gp.gp_file_save(camera_file, dst))

            logging.debug(f"Marking '{name}' ({timestamp}) as imported")
            mark_photo_from_camera_as_imported(db, name, timestamp)

    filesystem(ctx, cache, move=True, clobber=False)
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

    for f in filter_files(get_all_files(src), SUPPORTED_EXTENSIONS):
        logging.debug(f"file: {f}")
        timestamp = get_image_timestamp(f)
        logging.debug(f"{f} timestamp: {timestamp}")
        if timestamp is None:
            timestamp = UNKNOWN

        dest_dir = get_target_dir(PROVISIONAL_DIR, timestamp)
        f_name = os.path.basename(f)
        dst = os.path.join(dest_dir, f_name)
        md5sum = md5(f)
        if check_is_file_seen_before(db, md5sum):
            logging.info(f"have seen {f} ({md5sum})")
            if prune:
                logging.info(f"Removing {f} since we are pruning")
                os.remove(f)
            continue
        if os.path.isfile(dst) and not clobber:
            logging.error(f"destination already exists and {f} does not match {dst}")
            sys.exit(1)
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


def get_camera_file_info(camera, path):
    folder, name = os.path.split(path)
    return gp.check_result(gp.gp_camera_file_get_info(camera, folder, name))


# TODO: better handling of "constants"
CAMERA_IMPORT_TABLE = "camera_imports"
FILE_IMPORT_TABLE = "file_imports"


def init_db(db_path):
    dir = os.path.dirname(db_path)
    os.makedirs(dir, exist_ok=True)
    cmds = [
        f"""
    create table if not exists {CAMERA_IMPORT_TABLE} (
        file_name TEXT NOT NULL,
        capture_date TEXT NOT NULL,
        timestamp TEXT NOT NULL
        );
        """,
        f"""
    create table if not exists {FILE_IMPORT_TABLE} (
        file_name TEXT NOT NULL,
        md5 TEXT NOT NULL,
        timestamp TEXT NOT NULL
        );
      """,
    ]

    for cmd in cmds:
        con = sqlite3.connect(db_path)
        con.execute(cmd)


def has_photo_from_camera_been_imported(db_path, name, dte):
    con = sqlite3.connect(db_path)
    sql = f"""
    SELECT EXISTS(SELECT 1 FROM {CAMERA_IMPORT_TABLE} WHERE
        file_name="{name}" AND
        capture_date="{dte}"
        );
                """
    cur = con.execute(sql)
    cur.execute(sql)
    if cur.fetchone() == (0,):
        return False
    else:
        return True


def mark_photo_from_camera_as_imported(db, name, timestamp):
    con = sqlite3.connect(db)
    sql = f"""
    INSERT INTO {CAMERA_IMPORT_TABLE} VALUES ('{name}','{timestamp}',CURRENT_TIMESTAMP);
                """
    cur = con.execute(sql)
    con.commit()


def copy_file_from_camera(list, filename):
    mydir = os.path.join(os.getcwd(), datetime.now().strftime("%Y-%m-%d_%H-%M-%S"))
    try:
        os.makedirs(mydir)
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise  # This was not a "directory exist" error..
    with open(os.path.join(mydir, filename), "w") as d:
        d.writelines(list)


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

    img = Image.open(image_path)
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
    return tags


def get_image_timestamp(image_path):
    tags = get_exif_data(image_path)

    if not tags:
        # some facebook rip or something
        return None

    if "DateTimeOriginal" in tags:
        # 2023:10:01 12:05:05
        parsed = datetime.datetime.strptime(
            tags["DateTimeOriginal"], "%Y:%m:%d %H:%M:%S"
        )
    elif "DateTime" in tags:
        parsed = datetime.datetime.strptime(tags["DateTime"], "%Y:%m:%d %H:%M:%S")
    elif "DateTimeDigitized" in tags:
        parsed = datetime.datetime.strptime(
            tags["DateTimeDigitized"], "%Y:%m:%d %H:%M:%S"
        )
    elif 36867 in tags:
        parsed = datetime.datetime.strptime(tags[36867], "%Y:%m:%d %H:%M:%S")
    elif 306 in tags:
        parsed = datetime.datetime.strptime(tags[306], "%Y:%m:%d %H:%M:%S")
    else:
        # breakpoint()
        parsed = None
    return parsed


def md5(fname):
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


def check_is_file_seen_before(db_path, md5sum):
    con = sqlite3.connect(db_path)
    sql = f"""
    SELECT EXISTS(SELECT 1 FROM {FILE_IMPORT_TABLE} WHERE
        md5="{md5sum}"
        );
                """
    cur = con.execute(sql)
    cur.execute(sql)
    if cur.fetchone() == (0,):
        return False
    else:
        return True


def mark_file_as_imported(db_path, file_name, md5sum):
    con = sqlite3.connect(db_path)
    sql = f"""
    INSERT INTO {FILE_IMPORT_TABLE} VALUES ('{file_name}','{md5sum}',CURRENT_TIMESTAMP);
                """
    cur = con.execute(sql)
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

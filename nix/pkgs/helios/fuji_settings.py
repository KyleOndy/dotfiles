import datetime
import logging
import os
import struct
import sys

import typer
import usb.core
import usb.util
from typing_extensions import Annotated

import fuji_backup

app = typer.Typer()

# Protocol reference: petabyt/libfuji lib/fuji_usb.c
# @ 782f9c657ece16890f67343fb5560294d802f94f. With the camera in
# "USB RAW CONV./BACKUP RESTORE" mode the settings blob is PTP object
# handle 0; everything below is standard PIMA 15740 apart from the
# Fuji object format code and the zero-padded ObjectInfo on restore.

FUJI_VENDOR_ID = 0x04CB

USB_CLASS_IMAGE = 6
USB_SUBCLASS_STILL_IMAGE = 1
USB_PROTOCOL_PTP = 1

CONTAINER_COMMAND = 1
CONTAINER_DATA = 2
CONTAINER_RESPONSE = 3

OC_GET_DEVICE_INFO = 0x1001
OC_OPEN_SESSION = 0x1002
OC_CLOSE_SESSION = 0x1003
OC_GET_OBJECT_INFO = 0x1008
OC_GET_OBJECT = 0x1009
OC_SEND_OBJECT_INFO = 0x100C
OC_SEND_OBJECT = 0x100D
OC_GET_DEVICE_PROP_DESC = 0x1014
OC_GET_DEVICE_PROP_VALUE = 0x1015
OC_SET_DEVICE_PROP_VALUE = 0x1016

RC_OK = 0x2001
RC_SESSION_ALREADY_OPEN = 0x201E

# Standard PIMA 15740 operation names, for the device-info dump. Anything the
# camera advertises at or above 0x9000 is a vendor operation and gets flagged as
# such rather than named.
OP_NAMES = {
    0x1001: "GetDeviceInfo",
    0x1002: "OpenSession",
    0x1003: "CloseSession",
    0x1004: "GetStorageIDs",
    0x1005: "GetStorageInfo",
    0x1006: "GetNumObjects",
    0x1007: "GetObjectHandles",
    0x1008: "GetObjectInfo",
    0x1009: "GetObject",
    0x100A: "GetThumb",
    0x100B: "DeleteObject",
    0x100C: "SendObjectInfo",
    0x100D: "SendObject",
    0x100E: "InitiateCapture",
    0x100F: "FormatStore",
    0x1010: "ResetDevice",
    0x1011: "SelfTest",
    0x1012: "SetObjectProtection",
    0x1013: "PowerDown",
    0x1014: "GetDevicePropDesc",
    0x1015: "GetDevicePropValue",
    0x1016: "SetDevicePropValue",
    0x1017: "ResetDevicePropValue",
    0x1018: "TerminateOpenCapture",
    0x1019: "MoveObject",
    0x101A: "CopyObject",
    0x101B: "GetPartialObject",
    0x101C: "InitiateOpenCapture",
}

# PTP DataType codes, for labelling a swept property's storage type
PTP_TYPES = {
    0x0000: "undef",
    0x0001: "i8",
    0x0002: "u8",
    0x0003: "i16",
    0x0004: "u16",
    0x0005: "i32",
    0x0006: "u32",
    0x0007: "i64",
    0x0008: "u64",
    0x4002: "au8",
    0x4004: "au16",
    0x4006: "au32",
    0xFFFF: "str",
}

PROP_USB_MODE = 0xD16E
USB_MODE_BACKUP_RESTORE = 6
# StartRawConversion, RawConvProfile, PresetSlot: only advertised in RAW
# CONV./BACKUP RESTORE mode, the fallback signal on bodies like the X-T5
# that do not expose the USB mode property at all
RAW_CONV_MODE_PROPS = (0xD183, 0xD185, 0xD18C)

# Active custom-slot selector (PresetSlot); saved and restored around a write test.
ACTIVE_SLOT_PROP = 0xD18C
# Properties the write test refuses to touch: writing them is an action or a mode
# switch, not a setting. 0xD16E switches USB mode (drops the link); 0xD183-0xD189
# are the raw-conversion / capture flow (StartRawConversion, RawConvProfile, ...).
WRITE_TEST_DENYLIST = frozenset({PROP_USB_MODE}) | frozenset(range(0xD183, 0xD18A))

FUJI_BACKUP_FORMAT = 0x5000
BACKUP_HANDLE = 0
# libfuji refuses larger files; real backups are tens of KB
MAX_RESTORE_SIZE = 100000
# The ObjectInfo dataset X Acquire sends on restore is exactly 0x434 bytes: a
# usbmon capture of an X-T5 restore shows SendObjectInfo carrying a 1076-byte
# dataset with only three non-zero bytes (ObjectFormat 0x5000, ObjectCompressedSize).
# The old value of 1088 was 1076 + the 12-byte PTP container header, so helios
# sent 12 extra trailing bytes; the camera accepted SendObjectInfo but denied the
# SendObject data phase with 0x200F. Matching the SDK length exactly clears it.
OBJECTINFO_SIZE = 1076

SESSION_ID = 1
IO_TIMEOUT_MS = 5000
READ_CHUNK = 1 << 20

MODE_HINT = (
    "set CONNECTION MODE (on some bodies CONNECTION SETTING > CONNECTION MODE) "
    "to USB RAW CONV./BACKUP RESTORE on the camera, then reconnect the USB cable"
)


class PtpError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(f"0x{code:04X}")


def is_still_image_device(dev):
    for cfg in dev:
        for intf in cfg:
            if (
                intf.bInterfaceClass == USB_CLASS_IMAGE
                and intf.bInterfaceSubClass == USB_SUBCLASS_STILL_IMAGE
                and intf.bInterfaceProtocol == USB_PROTOCOL_PTP
            ):
                return True
    return False


def find_camera(device_index):
    try:
        devices = list(usb.core.find(find_all=True, idVendor=FUJI_VENDOR_ID))
    except usb.core.NoBackendError:
        logging.error("no libusb backend found; is libusb1 available?")
        sys.exit(1)
    devices = [d for d in devices if is_still_image_device(d)]
    devices.sort(key=lambda d: (d.bus, d.address))

    if not devices:
        logging.error(f"no Fujifilm camera found; check the USB cable and {MODE_HINT}")
        sys.exit(1)
    if len(devices) == 1:
        return devices[0]
    if device_index is None:
        logging.error(f"{len(devices)} Fujifilm cameras found; rerun with --device N:")
        for i, dev in enumerate(devices):
            try:
                serial = usb.util.get_string(dev, dev.iSerialNumber)
            except Exception:
                serial = "serial unreadable"
            logging.error(
                f"  --device {i}: bus {dev.bus} address {dev.address} ({serial})"
            )
        sys.exit(1)
    if device_index < 0 or device_index >= len(devices):
        logging.error(
            f"--device {device_index} is out of range, found {len(devices)} cameras"
        )
        sys.exit(1)
    return devices[device_index]


class PtpDevice:
    def __init__(self, dev):
        self.dev = dev
        self.tid = 0
        self.supported_props = frozenset()
        self.supported_ops = frozenset()

        try:
            dev.get_active_configuration()
        except usb.core.USBError:
            dev.set_configuration()
        cfg = dev.get_active_configuration()

        intf = usb.util.find_descriptor(
            cfg,
            custom_match=lambda i: i.bInterfaceClass == USB_CLASS_IMAGE
            and i.bInterfaceSubClass == USB_SUBCLASS_STILL_IMAGE
            and i.bInterfaceProtocol == USB_PROTOCOL_PTP,
        )
        if intf is None:
            logging.error(f"no PTP interface on the camera; {MODE_HINT}")
            sys.exit(1)
        self.interface = intf.bInterfaceNumber

        if dev.is_kernel_driver_active(self.interface):
            dev.detach_kernel_driver(self.interface)
        usb.util.claim_interface(dev, self.interface)

        self.ep_out = usb.util.find_descriptor(
            intf,
            custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)
            == usb.util.ENDPOINT_OUT
            and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK,
        )
        self.ep_in = usb.util.find_descriptor(
            intf,
            custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)
            == usb.util.ENDPOINT_IN
            and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK,
        )
        if self.ep_out is None or self.ep_in is None:
            logging.error("PTP interface is missing its bulk endpoints")
            sys.exit(1)

    def close(self):
        try:
            self.close_session()
        except Exception:
            pass
        try:
            usb.util.release_interface(self.dev, self.interface)
        except Exception:
            pass
        usb.util.dispose_resources(self.dev)

    def _send_container(self, ctype, code, tid, payload=b""):
        packet = struct.pack("<IHHI", 12 + len(payload), ctype, code, tid) + payload
        self.ep_out.write(packet, timeout=IO_TIMEOUT_MS)
        # a transfer that is an exact multiple of the packet size needs a
        # zero length packet so the camera knows the container ended
        if len(packet) % self.ep_out.wMaxPacketSize == 0:
            self.ep_out.write(b"", timeout=IO_TIMEOUT_MS)

    def _read_container(self):
        first = bytes(self.ep_in.read(READ_CHUNK, timeout=IO_TIMEOUT_MS))
        if first == b"":
            # trailing zero length packet from the previous container
            first = bytes(self.ep_in.read(READ_CHUNK, timeout=IO_TIMEOUT_MS))
        if len(first) < 12:
            raise RuntimeError(f"short read from the camera ({len(first)} bytes)")
        total, ctype, code, tid = struct.unpack_from("<IHHI", first)
        buf = bytearray(first)
        while len(buf) < total:
            buf.extend(
                self.ep_in.read(
                    min(READ_CHUNK, total - len(buf)), timeout=IO_TIMEOUT_MS
                )
            )
        return ctype, code, tid, bytes(buf[12:total])

    def transaction(self, opcode, params=(), data=None, ok=(RC_OK,)):
        tid = self.tid
        self.tid += 1

        payload = b"".join(struct.pack("<I", p) for p in params)
        self._send_container(CONTAINER_COMMAND, opcode, tid, payload)
        if data is not None:
            self._send_container(CONTAINER_DATA, opcode, tid, data)

        data_in = None
        ctype, code, rtid, payload = self._read_container()
        if ctype == CONTAINER_DATA:
            data_in = payload
            ctype, code, rtid, payload = self._read_container()
        if ctype != CONTAINER_RESPONSE:
            raise RuntimeError(f"expected a PTP response container, got type {ctype}")
        if rtid != tid:
            raise RuntimeError(f"PTP transaction id mismatch, sent {tid} got {rtid}")
        if code not in ok:
            raise PtpError(code)
        return data_in

    def open_session(self):
        self.transaction(
            OC_OPEN_SESSION, (SESSION_ID,), ok=(RC_OK, RC_SESSION_ALREADY_OPEN)
        )

    def close_session(self):
        self.transaction(OC_CLOSE_SESSION)

    def device_info(self):
        manufacturer, model, props, ops = parse_device_info(
            self.transaction(OC_GET_DEVICE_INFO)
        )
        self.supported_props = props
        self.supported_ops = ops
        return manufacturer, model

    def get_prop(self, prop):
        return self.transaction(OC_GET_DEVICE_PROP_VALUE, (prop,))

    def get_prop_desc(self, prop):
        """Return {data_type, writable, value} from GetDevicePropDesc, or None.

        The DevicePropDesc dataset is DevicePropCode(2), DataType(2), GetSet(1),
        then the factory/current values and form. GetSet is a fixed byte 4 (0 =
        read-only, 1 = read/write) regardless of the value type, so writability
        reads out without parsing the type-dependent tail. This is a pure read;
        it never changes anything on the camera. Raises PtpError when the camera
        does not support the property.
        """
        data = self.transaction(OC_GET_DEVICE_PROP_DESC, (prop,))
        if data is None or len(data) < 5:
            return None
        (data_type,) = struct.unpack_from("<H", data, 2)
        return {"data_type": data_type, "writable": data[4] == 1}

    def set_prop(self, prop, data):
        self.transaction(OC_SET_DEVICE_PROP_VALUE, (prop,), data=data)

    def usb_mode(self):
        data = self.transaction(OC_GET_DEVICE_PROP_VALUE, (PROP_USB_MODE,))
        if not data:
            raise RuntimeError("camera sent an empty USB mode property")
        if len(data) >= 4:
            return struct.unpack_from("<I", data)[0]
        if len(data) >= 2:
            return struct.unpack_from("<H", data)[0]
        return data[0]

    def read_backup(self):
        # libfuji reads the ObjectInfo first; keep the sequence identical
        self.transaction(OC_GET_OBJECT_INFO, (BACKUP_HANDLE,))
        data = self.transaction(OC_GET_OBJECT, (BACKUP_HANDLE,))
        if data is None:
            raise RuntimeError("camera sent no data for the backup object")
        return data

    def write_backup(self, blob):
        # Restore is plain PTP: SendObjectInfo then SendObject to object 0. The
        # ObjectInfo is a 1076-byte (OBJECTINFO_SIZE) dataset with StorageID 0,
        # ObjectFormat 0x5000, and ObjectCompressedSize set to the blob length,
        # everything else zero. This is byte-for-byte what a usbmon capture of an
        # X-T5 restore in X Acquire sends. Getting the length right is what matters:
        # padding past 1076 makes the camera accept SendObjectInfo and then deny
        # the SendObject data phase with 0x200F.
        info = struct.pack("<IHHI", 0, FUJI_BACKUP_FORMAT, 0, len(blob))
        info = info.ljust(OBJECTINFO_SIZE, b"\x00")
        logging.debug("restore: sending ObjectInfo (%d bytes)", len(info))
        self.transaction(OC_SEND_OBJECT_INFO, (0, 0), data=info)
        logging.debug("restore: ObjectInfo accepted, sending object data")
        self.transaction(OC_SEND_OBJECT, data=blob)
        logging.debug("restore: object data accepted")


def read_ptp_string(buf, off):
    count = buf[off]
    off += 1
    text = buf[off : off + count * 2].decode("utf-16-le")
    return text.rstrip("\x00"), off + count * 2


def encode_ptp_string(text):
    # count byte is the number of UTF-16 code units including the terminator
    if not text:
        return b"\x00"
    encoded = (text + "\x00").encode("utf-16-le")
    count = len(encoded) // 2
    if count > 255:
        raise ValueError(f"string too long for PTP ({count} UTF-16 code units)")
    return bytes([count]) + encoded


def skip_ptp_array(buf, off, elem_size):
    (count,) = struct.unpack_from("<I", buf, off)
    return off + 4 + count * elem_size


def read_ptp_u16_array(buf, off):
    (count,) = struct.unpack_from("<I", buf, off)
    off += 4
    return list(struct.unpack_from(f"<{count}H", buf, off)), off + count * 2


def parse_device_info(data):
    try:
        off = 2 + 4 + 2  # StandardVersion, VendorExtensionID, VendorExtensionVersion
        _, off = read_ptp_string(data, off)  # VendorExtensionDesc
        off += 2  # FunctionalMode
        ops, off = read_ptp_u16_array(data, off)  # OperationsSupported
        off = skip_ptp_array(data, off, 2)  # EventsSupported
        props, off = read_ptp_u16_array(data, off)  # DevicePropertiesSupported
        # CaptureFormats and ImageFormats: u16 arrays
        for _ in range(2):
            off = skip_ptp_array(data, off, 2)
        manufacturer, off = read_ptp_string(data, off)
        model, off = read_ptp_string(data, off)
        return manufacturer, model, frozenset(props), frozenset(ops)
    except (IndexError, struct.error, UnicodeDecodeError) as e:
        logging.warning(f"could not parse the camera DeviceInfo ({e})")
        return "unknown", "unknown", frozenset(), frozenset()


def open_camera(device_index, force=False):
    dev = find_camera(device_index)
    try:
        ptp = PtpDevice(dev)
    except usb.core.USBError as e:
        if e.errno == 13:
            logging.error(
                "permission denied opening the camera; the udev rules that let "
                "'helios import camera' work should cover this device, check "
                f"ls -l /dev/bus/usb/{dev.bus:03d}/{dev.address:03d}"
            )
        elif e.errno == 16:
            logging.error("camera is busy; another process (gvfs?) may have it open")
        else:
            logging.error(f"could not open the camera: {e}")
        sys.exit(1)

    ptp.open_session()
    manufacturer, model = ptp.device_info()
    logging.info(f"connected to {manufacturer} {model}")
    fuji_props = sorted(p for p in ptp.supported_props if p >= 0xD000)
    logging.debug(
        f"camera advertises {len(fuji_props)} fuji properties: "
        + " ".join(f"0x{p:04X}" for p in fuji_props)
    )

    # libfuji treats a failed USB mode read as expected, not an error; some
    # bodies (the X-T5 among them) never expose the property, so fall back
    # to the properties only advertised in RAW CONV./BACKUP RESTORE mode
    if PROP_USB_MODE in ptp.supported_props or not ptp.supported_props:
        try:
            mode = ptp.usb_mode()
        except (PtpError, RuntimeError) as e:
            logging.debug(f"USB mode read failed: {e}")
            mode = None
        in_backup_mode = mode == USB_MODE_BACKUP_RESTORE
        detail = f"USB mode {mode}"
    else:
        in_backup_mode = any(p in ptp.supported_props for p in RAW_CONV_MODE_PROPS)
        detail = "no USB mode property and no raw conversion properties"
        if in_backup_mode:
            logging.debug(
                "no USB mode property; raw conversion properties are advertised"
            )

    if not in_backup_mode:
        if force:
            logging.warning(f"{detail}, continuing because of --force")
        else:
            logging.error(f"camera is not in backup mode ({detail}); {MODE_HINT}")
            if fuji_props:
                logging.error(
                    "vendor properties the camera advertises: "
                    + " ".join(f"0x{p:04X}" for p in fuji_props)
                )
            # card reader mode presents MTP, whose only vendor-range
            # properties are 0xD401/0xD402
            if fuji_props and all(0xD400 <= p <= 0xD4FF for p in fuji_props):
                logging.error(
                    "this looks like USB CARD READER mode; change CONNECTION "
                    "MODE and unplug and replug the cable"
                )
            ptp.close()
            sys.exit(1)

    return ptp, model


def settings_dir(ctx, *parts):
    photo_dir = getattr(ctx.obj, "photo_dir", None) or os.path.join(
        os.path.expanduser("~"), "photos"
    )
    return os.path.join(photo_dir, "settings", *parts)


def default_backup_name(model):
    safe = model.strip().replace("/", "-").replace(" ", "-")
    return f"{safe}-{datetime.date.today().isoformat()}.bak"


@app.command()
def backup(
    ctx: typer.Context,
    output: Annotated[
        str,
        typer.Option(
            help="Output file, defaults to MODEL-DATE.bak under <library>/settings/backups"
        ),
    ] = None,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool,
        typer.Option(
            "--force",
            help="Skip the USB mode check; lets older bodies like the X-T1 attempt a backup from tether mode",
        ),
    ] = False,
):
    ptp = None
    try:
        ptp, model = open_camera(device, force=force)
        if output:
            path = output
        else:
            backup_dir = settings_dir(ctx, "backups")
            os.makedirs(backup_dir, exist_ok=True)
            path = os.path.join(backup_dir, default_backup_name(model))
        if os.path.exists(path):
            logging.error(f"refusing to overwrite {path}; move it or pass --output")
            sys.exit(1)
        blob = ptp.read_backup()
        if len(blob) == 0:
            logging.error("camera returned an empty backup")
            sys.exit(1)
        with open(path, "wb") as f:
            f.write(blob)
        logging.info(f"wrote {len(blob)} bytes to {path}")
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


@app.command()
def restore(
    ctx: typer.Context,
    file: str,
    yes: Annotated[
        bool, typer.Option("--yes", help="Skip the confirmation prompt")
    ] = False,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
):
    try:
        with open(file, "rb") as f:
            blob = f.read()
    except OSError as e:
        logging.error(f"could not read {file}: {e}")
        sys.exit(1)
    if len(blob) == 0:
        logging.error(f"{file} is empty")
        sys.exit(1)
    if len(blob) >= MAX_RESTORE_SIZE:
        logging.error(
            f"{file} is {len(blob)} bytes but backups are tens of KB; is this the right file?"
        )
        sys.exit(1)

    ptp = None
    try:
        ptp, model = open_camera(device)
        print(f"Connected camera: {model}")
        print(f"Restore file:     {file} ({len(blob)} bytes)")
        print("Backup files only restore to the same model that created them.")
        if model == "unknown" and not yes:
            logging.error(
                "could not identify the camera model; rerun with --yes to restore anyway"
            )
            sys.exit(1)
        if not yes and not typer.confirm("Write these settings to the camera?"):
            logging.info("aborted, nothing was sent")
            sys.exit(0)
        ptp.write_backup(blob)
        logging.info(
            "restore complete; power cycle the camera to make sure all settings apply"
        )
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


def _slot_change_lines(old_rec, new_rec):
    """Human-readable before/after for one slot's decoded blob fields. Takes two
    Record objects so the preamble fields (WB, color temp, long-exp NR) show."""
    lines = []
    of = fuji_backup.decode_slot(old_rec)
    nf = fuji_backup.decode_slot(new_rec)
    keys = list(of)
    keys += [k for k in nf if k not in of]
    for key in keys:
        if of.get(key) != nf.get(key):
            lines.append(f"      {key}: {of.get(key)} -> {nf.get(key)}")
    oa = fuji_backup.decode_auto_iso(old_rec.data)
    na = fuji_backup.decode_auto_iso(new_rec.data)
    if oa and na:
        for i in range(3):
            if oa[i] != na[i]:
                lines.append(f"      auto_iso AUTO{i + 1}: {oa[i]} -> {na[i]}")
    return lines


@app.command()
def edit(
    file: str,
    slot: Annotated[
        int,
        typer.Option(help="Slot to edit, 1-7 (C1..C7); required with --name/--recipe"),
    ] = None,
    name: Annotated[
        str, typer.Option(help="New slot name (ASCII, up to 25 characters)")
    ] = None,
    recipe: Annotated[
        str,
        typer.Option(
            help="Recipe YAML to write into --slot (image look, auto-ISO, menu settings)"
        ),
    ] = None,
    recipe_dir: Annotated[
        str,
        typer.Option(
            "--recipe-dir",
            help="Directory of c1..c7 recipe files; configures every matching slot",
        ),
    ] = None,
    output: Annotated[
        str,
        typer.Option(help="Output file; defaults to <input>-edited<ext> next to it"),
    ] = None,
    force: Annotated[
        bool,
        typer.Option("--force", help="Parse even if the model is not one we verified"),
    ] = False,
):
    """Edit per-slot settings in a backup FILE and write a new file (offline).

    Three modes: --name renames a slot; --recipe writes one recipe's image-quality
    look, auto-ISO and per-slot menu settings into --slot; --recipe-dir configures
    every c1..c7 slot from a directory in one pass. The whole-file checksum is
    recomputed so the file stays internally valid (see FUJI_BLOB_FORMAT.md), and
    'fuji-settings restore' writes it back to the X-T5. Take a fresh
    'fuji-settings backup' before any restore so you can always put the camera back.
    This path reaches per-slot fields the live PTP recipe path cannot (auto-ISO and
    the AF/drive/shutter menu settings); validate the result against a fresh camera
    backup, since the menu-field encodings come from single controlled diffs
    (FUJI_BLOB_FORMAT.md).
    """
    if name is None and recipe is None and recipe_dir is None:
        logging.error("nothing to edit; pass --name, --recipe, or --recipe-dir")
        sys.exit(1)
    if recipe_dir is not None and (recipe is not None or name is not None):
        logging.error(
            "--recipe-dir configures whole slots; do not combine it with --recipe/--name"
        )
        sys.exit(1)
    if recipe_dir is None and slot is None:
        logging.error("--slot is required with --name/--recipe")
        sys.exit(1)

    try:
        with open(file, "rb") as f:
            data = f.read()
    except OSError as e:
        logging.error(f"could not read {file}: {e}")
        sys.exit(1)

    try:
        header, _ = fuji_backup.open_backup(file, force=force)
    except (OSError, fuji_backup.BackupFormatError) as e:
        logging.error(str(e))
        sys.exit(1)
    if slot is not None and not 1 <= slot <= fuji_backup.NUM_SLOTS:
        logging.error(f"--slot must be between 1 and {fuji_backup.NUM_SLOTS}")
        sys.exit(1)

    import fuji_recipes  # lazy import avoids the fuji_recipes <-> fuji_settings cycle

    # build the edit plan: list of (slot, recipe-dict-or-None); None is name-only
    plan = []
    try:
        if recipe_dir is not None:
            mapping = fuji_recipes.map_recipe_dir(recipe_dir)
            if not mapping:
                logging.error(f"no c1..c7 recipe files found in {recipe_dir}")
                sys.exit(1)
            for s in sorted(mapping):
                plan.append((s, fuji_recipes.load_recipe_file(mapping[s])))
        elif recipe is not None:
            plan.append((slot, fuji_recipes.load_recipe_file(recipe)))
        else:
            plan.append((slot, None))
    except fuji_recipes.RecipeError as e:
        logging.error(str(e))
        sys.exit(1)

    patched = data
    skipped_by_slot = {}
    try:
        for s, rec in plan:
            if rec is not None:
                patched, skipped = fuji_backup.patch_slot_recipe(patched, s, rec)
                if skipped:
                    skipped_by_slot[s] = skipped
                new_name = (
                    name if (name is not None and recipe_dir is None) else rec["name"]
                )
                if new_name:
                    patched = fuji_backup.patch_slot_name(patched, s, new_name)
            else:
                patched = fuji_backup.patch_slot_name(patched, s, name)
    except (fuji_backup.BackupFormatError, ValueError) as e:
        logging.error(str(e))
        sys.exit(1)

    old_sum = fuji_backup.stored_checksum(data)
    new_blob = fuji_backup.apply_checksum(patched)
    new_sum = fuji_backup.stored_checksum(new_blob)

    # safety: in-place edits keep the file length, and the checksum must verify
    if len(new_blob) != len(data):
        logging.error("internal error: edit changed the file length; aborting")
        sys.exit(1)
    if fuji_backup.stored_checksum(new_blob) != fuji_backup.blob_checksum(new_blob):
        logging.error("internal error: checksum did not verify after edit; aborting")
        sys.exit(1)

    if output is None:
        root, ext = os.path.splitext(file)
        output = f"{root}-edited{ext or '.bak'}"
    if os.path.abspath(output) == os.path.abspath(file):
        logging.error("refusing to overwrite the input file; pass a different --output")
        sys.exit(1)
    if os.path.exists(output):
        logging.error(f"refusing to overwrite {output}; move it or pass --output")
        sys.exit(1)
    try:
        with open(output, "wb") as f:
            f.write(new_blob)
    except OSError as e:
        logging.error(f"could not write {output}: {e}")
        sys.exit(1)

    before = fuji_backup.locate_records(data)
    after = fuji_backup.locate_records(new_blob)
    print(f"model:  {header['model']}")
    for s, rec in plan:
        old_name = before[s - 1].name
        new_name = after[s - 1].name
        if old_name != new_name:
            print(f"C{s} name: {old_name or '(unnamed)'} -> {new_name or '(unnamed)'}")
        else:
            print(f"C{s}: {new_name or '(unnamed)'}")
        if rec is not None:
            for line in _slot_change_lines(before[s - 1], after[s - 1]):
                print(line)
            if s in skipped_by_slot:
                print(
                    "      not written (no blob offset yet, set via fuji-recipes): "
                    + ", ".join(skipped_by_slot[s])
                )
    print(f"checksum: 0x{old_sum:04X} -> 0x{new_sum:04X} (recomputed at 0xE8)")
    print(f"wrote {len(new_blob)} bytes to {output}")
    print(
        "restore it with 'helios fuji-settings restore "
        f"{output}'; take a fresh backup first. The checksum is recomputed, but "
        "validate the result against a fresh camera backup (see FUJI_BLOB_FORMAT.md)."
    )


def _flip(cur, lo, hi):
    """A guaranteed-different value in [lo, hi]: step up unless already at the top."""
    return cur + 1 if cur < hi else cur - 1


def _probe_recipe(record_data):
    """A controlled one-slot perturbation for commit-probe.

    Flips a handful of integer fields spread across the record body (wb shift R at
    +0x06, high-ISO NR at +0x22, sharpness at +0x61) plus the slot name at +0x1CF,
    so whatever a per-record integrity token happens to cover is disturbed.
    Returns (recipe_dict, marker_name). The fields are film-sim-independent, so the
    perturbation encodes on any slot.
    """
    cur = fuji_backup.decode_recipe_fields(record_data)
    recipe = {
        "wb_shift_r": _flip(int(cur.get("wb_shift_r", 0)), -9, 9),
        "high_iso_nr": _flip(int(cur.get("high_iso_nr", 0)), -4, 4),
        "sharpness": _flip(int(cur.get("sharpness", 0)), -4, 4),
    }
    marker = "probe" + datetime.datetime.now().strftime("%H%M%S")
    return recipe, marker


def _print_probe_bucket(title, entries):
    if not entries:
        return
    print(title)
    for off, o, e, b, label in entries:
        print(f"    +0x{off:04x}  orig {o:02x}  sent {e:02x}  camera {b:02x}   {label}")


@app.command("commit-probe")
def commit_probe(
    ctx: typer.Context,
    slot: Annotated[int, typer.Option(help="Slot to perturb, 1-7 (C1..C7)")] = 7,
    out_dir: Annotated[
        str,
        typer.Option(
            help="Where to write the three probe blobs; defaults to <library>/settings/probes"
        ),
    ] = None,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    yes: Annotated[
        bool,
        typer.Option(
            "--yes", help="Skip the write confirmation (not the power-cycle pause)"
        ),
    ] = False,
):
    """Show which bytes the camera re-stamps on save (reverse-engineering aid).

    Backs up the camera, edits ONE slot (a controlled perturbation across the
    record body), restores it, waits for you to power-cycle, backs up again, and
    three-way diffs the result. Bytes the camera changed that helios never wrote
    fall into two groups: any inside the edited record (a per-slot field the camera
    manages, worth understanding before trusting a write there) and global state it
    refreshes on every save (the lens block, save counter, checksum). Used
    2026-07-16 to show there is no per-slot integrity token in the record, which is
    part of why every slot's look commits in a single restore (see
    FUJI_WRITE_SURFACE.md, "Restoring many slots at once"). The three blobs are written
    to OUT_DIR so you can re-diff later with 'fuji-settings diff'. This WRITES one
    slot to the camera; the pristine backup it takes first is your restore point.
    """
    if not 1 <= slot <= fuji_backup.NUM_SLOTS:
        logging.error(f"--slot must be between 1 and {fuji_backup.NUM_SLOTS}")
        sys.exit(1)
    if not sys.stdin.isatty():
        logging.error(
            "commit-probe is interactive (it pauses for a power cycle); run it in a terminal"
        )
        sys.exit(1)

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    if out_dir is None:
        out_dir = settings_dir(ctx, "probes")
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as e:
        logging.error(f"could not create {out_dir}: {e}")
        sys.exit(1)
    p_orig = os.path.join(out_dir, f"probe-{stamp}-original.bak")
    p_edit = os.path.join(out_dir, f"probe-{stamp}-edited.bak")
    p_read = os.path.join(out_dir, f"probe-{stamp}-readback.bak")

    ptp = None
    try:
        ptp, model = open_camera(device)
        if model not in fuji_backup.SUPPORTED_MODELS:
            logging.error(
                f"commit-probe only knows the {', '.join(fuji_backup.SUPPORTED_MODELS)} "
                f"record layout; connected camera is {model!r}"
            )
            sys.exit(1)

        # phase 1: pristine backup, one-slot edit, restore
        original = ptp.read_backup()
        with open(p_orig, "wb") as f:
            f.write(original)
        records = fuji_backup.locate_records(original)
        recipe, marker = _probe_recipe(records[slot - 1].data)
        patched, _ = fuji_backup.patch_slot_recipe(original, slot, recipe)
        patched = fuji_backup.patch_slot_name(patched, slot, marker)
        edited = fuji_backup.apply_checksum(patched)
        if edited == original:
            logging.error("internal error: the probe edit did not change the blob")
            sys.exit(1)
        with open(p_edit, "wb") as f:
            f.write(edited)

        before = fuji_backup.locate_records(original)
        after = fuji_backup.locate_records(edited)
        print(f"Camera: {model}")
        print(f"Probe edit on C{slot} (name -> {marker!r}):")
        for line in _slot_change_lines(before[slot - 1], after[slot - 1]):
            print(line)
        print(f"Pristine backup saved to {p_orig} (your restore point).")
        if not yes and not typer.confirm(
            f"Restore this one-slot edit to C{slot} on the camera?"
        ):
            logging.info("aborted, nothing was written")
            sys.exit(0)
        ptp.write_backup(edited)
        ptp.close()
        ptp = None

        print(
            "\nRestore sent. Now power cycle the camera, re-enter USB RAW CONV./"
            "BACKUP RESTORE mode, and reconnect the USB cable so the edit commits."
        )
        input("Press Enter when the camera is back and reconnected... ")

        # phase 2: fresh backup, three-way diff
        ptp, model = open_camera(device)
        readback = ptp.read_backup()
        with open(p_read, "wb") as f:
            f.write(readback)
        ptp.close()
        ptp = None

        if not (len(original) == len(edited) == len(readback)):
            print(
                f"note: blob lengths differ (original {len(original)}, sent {len(edited)}, "
                f"readback {len(readback)}); comparing the common prefix"
            )
        buckets, _ = fuji_backup.classify_commit_probe(original, edited, readback, slot)

        print(f"\nreadback saved to {p_read}")
        print(f"re-diff any time: helios fuji-settings diff {p_edit} {p_read}\n")
        _print_probe_bucket(
            "edit committed (camera kept our value):", buckets["committed"]
        )
        _print_probe_bucket(
            "edit NOT kept (camera reverted to original) -- blob-restore does not "
            "commit these fields:",
            buckets["reverted"],
        )
        _print_probe_bucket(
            "edit changed to a third value by the camera:", buckets["changed"]
        )
        _print_probe_bucket(
            f"camera-stamped bytes IN C{slot}'s record helios never wrote "
            "(per-slot fields the camera manages):",
            buckets["stamped"],
        )
        _print_probe_bucket(
            "camera-refreshed GLOBAL state helios never wrote (not per-slot; lens "
            "block etc.):",
            buckets["stamped_global"],
        )
        _print_probe_bucket(
            "global bookkeeping the camera always rewrites (expected):",
            buckets["bookkeeping"],
        )

        print()
        if buckets["stamped"]:
            print(
                f"VERDICT: the camera re-stamped bytes inside C{slot} that helios left\n"
                "unchanged. Understand these before trusting a write to that offset; decode\n"
                "them and, if they are content, add them to patch_slot_recipe."
            )
        else:
            print(
                f"VERDICT: the camera changed nothing inside C{slot} that helios did not\n"
                "write; only global state (lens block, save counter, checksum) moved, and it\n"
                "was accepted stale on restore. The record is fully helios-authored."
            )
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except (RuntimeError, fuji_backup.BackupFormatError, ValueError) as e:
        logging.error(f"{e}")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


def _print_auto_iso(record, indent="    "):
    banks = fuji_backup.decode_auto_iso(record.data)
    if not banks:
        return
    for i, b in enumerate(banks, start=1):
        print(
            f"{indent}AUTO{i}  default {b['default']}, max {b['max']}, "
            f"min shutter {b['min_shutter']}"
        )


def _print_slot_settings(fields, indent="    "):
    """Print the per-slot menu settings (AF/MF, drive, shutter, image quality),
    the values to copy into a recipe. Confirmed fields show their menu name;
    unconfirmed fields show the raw byte (0/1) the recipe expects back. `fields`
    is a decode_slot() dict (see BLOB_SLOT_FIELDS / IMAGE_QUALITY_VALUES).
    """
    keys = [*fuji_backup.SLOT_FIELD_KEYS, "image_quality", "detection", "af_mf"]
    present = [(k, fields[k]) for k in keys if k in fields]
    if not present:
        return
    print(f"{indent}settings: " + ", ".join(f"{k}={v}" for k, v in present))


def _format_blob_recipe(fields):
    """One-line summary of the image-quality fields decoded from the blob."""
    parts = [str(fields.get("film_simulation", "?"))]
    dr = fields.get("dynamic_range")
    if dr is not None:
        parts.append("DR Auto" if dr == "Auto" else f"DR{dr}")
    grain = fields.get("grain")
    if grain:
        parts.append(f"grain {grain}")
    for key, label in (("color_chrome", "CC"), ("color_chrome_fx_blue", "CCB")):
        value = fields.get(key)
        if value and value != "Off":
            parts.append(f"{label} {value}")
    wb = fields.get("white_balance")
    if wb:
        temp = fields.get("wb_color_temp")
        parts.append(f"WB {wb} {temp}K" if temp else f"WB {wb}")
    for key, label in (("wb_shift_r", "R"), ("wb_shift_b", "B")):
        value = fields.get(key)
        if value:
            parts.append(f"{label}{value:+g}")
    for key, label in (
        ("color", "color"),
        ("sharpness", "sharp"),
        ("highlight_tone", "H"),
        ("shadow_tone", "S"),
        ("clarity", "clarity"),
        ("high_iso_nr", "NR"),
        ("mono_wc", "WC"),
        ("mono_mg", "MG"),
    ):
        value = fields.get(key)
        if value:
            parts.append(f"{label}{value:+g}")
    skin = fields.get("smooth_skin")
    if skin and skin != "Off":
        parts.append(f"skin {skin}")
    if fields.get("long_exposure_nr") == "off":
        parts.append("LE-NR off")
    return ", ".join(parts)


@app.command()
def inspect(
    file: str,
    raw: Annotated[
        bool, typer.Option("--raw", help="Also dump each slot record as hex")
    ] = False,
    force: Annotated[
        bool,
        typer.Option("--force", help="Parse even if the model is not one we verified"),
    ] = False,
):
    """Parse a settings backup file and show its per-slot custom settings.

    Offline: reads a .bak/.DAT, no camera needed. Decodes what we have reverse
    engineered of the blob (see FUJI_BLOB_FORMAT.md), currently the per-slot
    auto-ISO banks; the rest of each record is shown by name only.
    """
    try:
        header, records = fuji_backup.open_backup(file, force=force)
    except (OSError, fuji_backup.BackupFormatError) as e:
        logging.error(str(e))
        sys.exit(1)

    print(f"model:   {header['model']}")
    print(f"version: {header['version']}")
    print(f"serial:  {header['serial']}")
    for r in records:
        print(f"C{r.index}  {r.name or '(unnamed)'}")
        fields = fuji_backup.decode_slot(r)
        if fields:
            print(f"    {_format_blob_recipe(fields)}")
        _print_auto_iso(r)
        _print_slot_settings(fields)
        if raw:
            for off in range(0, len(r.data), 16):
                chunk = r.data[off : off + 16]
                print(f"    +{off:03x}  " + " ".join(f"{b:02x}" for b in chunk))


def _diff_pair(label, ra, rb):
    n = min(len(ra.data), len(rb.data))
    diffs = [
        (rel, ra.data[rel], rb.data[rel])
        for rel in range(n)
        if ra.data[rel] != rb.data[rel]
    ]
    if not diffs:
        print(f"{label}: identical")
        return
    print(f"{label}: {len(diffs)} differing byte(s)")
    for rel, a, b in diffs:
        print(f"    +{rel:03x}  {a:02x} -> {b:02x}   {fuji_backup.field_label(rel)}")
    auto = fuji_backup.REL_AUTOISO
    if any(auto <= rel < auto + fuji_backup.AUTOISO_LEN for rel, _, _ in diffs):
        ba = fuji_backup.decode_auto_iso(ra.data)
        bb = fuji_backup.decode_auto_iso(rb.data)
        if ba and bb:
            print("    auto-ISO decode:")
            for i in range(3):
                print(f"      AUTO{i + 1}  {ba[i]} -> {bb[i]}")


def _diff_whole_file(records_a, data_a, data_b):
    n = min(len(data_a), len(data_b))
    diffs = [(o, data_a[o], data_b[o]) for o in range(n) if data_a[o] != data_b[o]]
    if len(data_a) != len(data_b):
        print(f"(files differ in length: {len(data_a)} vs {len(data_b)} bytes)")
    if not diffs:
        print("whole file: identical")
        return
    print(f"whole file: {len(diffs)} differing byte(s)")
    for off, a, b in diffs:
        print(
            f"    0x{off:05x}  {a:02x} -> {b:02x}   {fuji_backup.describe_offset(records_a, off)}"
        )


@app.command()
def diff(
    file_a: str,
    file_b: Annotated[
        str,
        typer.Argument(help="Second backup; omit to diff two slots via --slots"),
    ] = None,
    slots: Annotated[
        str,
        typer.Option(help="Two slot numbers to compare within one file, e.g. 1,2"),
    ] = None,
    whole_file: Annotated[
        bool,
        typer.Option(
            "--whole-file",
            help="Diff every byte of two files, not just the record bodies, "
            "labeling each change by slot, preamble, trailer or global. Catches "
            "preamble and global fields the per-slot body diff misses.",
        ),
    ] = False,
    force: Annotated[
        bool,
        typer.Option("--force", help="Parse even if the model is not one we verified"),
    ] = False,
):
    """Diff per-slot records to reveal which bytes a setting change moved.

    Two files: compares matching slots (C1 vs C1, ...) across them. One file
    with --slots i,j: compares slot i against slot j. Add --whole-file to compare
    every byte with slot/preamble/global attribution. Differing bytes are printed
    with the field they fall in, so a controlled backup (change one known setting,
    re-backup) maps that setting to its bytes.
    """
    try:
        _, records_a = fuji_backup.open_backup(file_a, force=force)
    except (OSError, fuji_backup.BackupFormatError) as e:
        logging.error(str(e))
        sys.exit(1)

    if whole_file:
        if file_b is None:
            logging.error("--whole-file needs a second FILE")
            sys.exit(1)
        if slots is not None:
            logging.error("--whole-file cannot be combined with --slots")
            sys.exit(1)
        try:
            with open(file_a, "rb") as fa, open(file_b, "rb") as fb:
                _diff_whole_file(records_a, fa.read(), fb.read())
        except OSError as e:
            logging.error(str(e))
            sys.exit(1)
        return

    if file_b is not None:
        if slots is not None:
            logging.error("pass either a second FILE or --slots, not both")
            sys.exit(1)
        try:
            _, records_b = fuji_backup.open_backup(file_b, force=force)
        except (OSError, fuji_backup.BackupFormatError) as e:
            logging.error(str(e))
            sys.exit(1)
        for ra, rb in zip(records_a, records_b):
            _diff_pair(f"C{ra.index}", ra, rb)
        return

    if slots is None:
        logging.error("pass a second FILE, or --slots i,j to diff within one file")
        sys.exit(1)
    try:
        i, j = (int(s) for s in slots.split(","))
    except ValueError:
        logging.error(f"--slots must be two numbers like 1,2 (got {slots!r})")
        sys.exit(1)
    if not (1 <= i <= fuji_backup.NUM_SLOTS and 1 <= j <= fuji_backup.NUM_SLOTS):
        logging.error(f"--slots must be between 1 and {fuji_backup.NUM_SLOTS}")
        sys.exit(1)
    _diff_pair(f"C{i} vs C{j}", records_a[i - 1], records_a[j - 1])


def _truth_from_recipes(recipes):
    """Per-field known-value vectors across slots, for fuji_backup.correlate."""

    def get(key):
        return [None if r is None else r.get(key) for r in recipes]

    def grain_part(idx):
        parts = []
        for r in recipes:
            grain = None if r is None else r.get("grain")
            parts.append(grain.split("/")[idx] if grain and "/" in grain else None)
        return parts

    return {
        "film_simulation": get("film_simulation"),
        "dynamic_range": get("dynamic_range"),
        "color": get("color"),
        "sharpness": get("sharpness"),
        "highlight_tone": get("highlight_tone"),
        "shadow_tone": get("shadow_tone"),
        "color_chrome": get("color_chrome"),
        "color_chrome_fx_blue": get("color_chrome_fx_blue"),
        "grain_strength": grain_part(0),
        "grain_size": grain_part(1),
        "white_balance": get("white_balance"),
        "wb_shift_r": get("wb_shift_r"),
        "wb_shift_b": get("wb_shift_b"),
        "high_iso_nr": get("high_iso_nr"),
        "clarity": get("clarity"),
    }


@app.command()
def correlate(
    ctx: typer.Context,
    file: str,
    recipes: Annotated[
        str,
        typer.Option(
            help="Directory of c1..c7 recipe files with known values, defaults "
            "to <library>/settings/recipes"
        ),
    ] = None,
    force: Annotated[
        bool,
        typer.Option("--force", help="Parse even if the model is not one we verified"),
    ] = False,
):
    """Locate blob offsets for known settings by correlating against recipes.

    Reverse-engineering aid: point it at a backup whose slots hold recipes you
    already have as files (e.g. from 'helios fuji-recipes backup'). For each
    known field it prints the byte offset and encoding that reproduces every
    slot. An affine hit (value = a + b*raw) is a solved encoding; a "partition"
    hit only matched the equality pattern and needs a second capture to confirm.
    This is how the packed recipe struct was mapped; see FUJI_BLOB_FORMAT.md.
    """
    import fuji_recipes  # lazy import avoids the fuji_recipes <-> fuji_settings cycle

    try:
        _, records = fuji_backup.open_backup(file, force=force)
    except (OSError, fuji_backup.BackupFormatError) as e:
        logging.error(str(e))
        sys.exit(1)

    if recipes is None:
        recipes = settings_dir(ctx, "recipes")
    try:
        mapping = fuji_recipes.map_recipe_dir(recipes)
        loaded = [
            fuji_recipes.load_recipe_file(mapping[slot]) if slot in mapping else None
            for slot in range(1, fuji_backup.NUM_SLOTS + 1)
        ]
    except fuji_recipes.RecipeError as e:
        logging.error(str(e))
        sys.exit(1)

    truth = _truth_from_recipes(loaded)
    record_bytes = [r.data for r in records]
    found = fuji_backup.correlate(record_bytes, truth)

    for field, hits in found.items():
        if not hits:
            distinct = len({v for v in truth[field] if v is not None})
            if distinct < 2:
                print(f"{field}: constant or absent across these slots (no signal)")
            else:
                print(
                    f"{field}: varies ({distinct} values) but no single-offset match "
                    "-- likely multi-byte or a different encoding; needs a controlled diff"
                )
            continue
        # solved (affine) encodings first, then single-byte over wider reads
        # that merely overlap the same field, then by offset
        hits.sort(key=lambda h: (h[2] == "partition", "16" in h[1], h[0]))
        shown = ", ".join(
            f"+{off:03x}/{interp} [{note}]" for off, interp, note in hits[:6]
        )
        more = "" if len(hits) <= 6 else f"  (+{len(hits) - 6} more)"
        known = fuji_backup.field_label(hits[0][0])
        tag = f"  <- already mapped as '{known}'" if known != "unknown" else ""
        print(f"{field}: {shown}{more}{tag}")


def _sweep_codes(start, end, full):
    """Property codes to probe. Default is the whole device-property space:
    standard 0x5000-0x5FFF and Fuji vendor 0xD000-0xDFFF (device properties only
    live in those two windows). --full probes every u16; --start/--end give a
    custom window."""
    if full:
        return range(0x0000, 0x10000)
    if start is not None or end is not None:
        lo = int(start, 0) if start else 0x0000
        hi = int(end, 0) if end else 0xFFFF
        return range(lo, hi + 1)
    return list(range(0x5000, 0x6000)) + list(range(0xD000, 0xE000))


@app.command("device-info")
def device_info_cmd(
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode check")
    ] = False,
):
    """Dump the camera's advertised operations and properties (DeviceInfo).

    This is the DeviceInfo the camera returns in the current USB mode. It answers
    whether the operations the restore path needs (SendObjectInfo 0x100C,
    SendObject 0x100D) are even advertised in RAW CONV./BACKUP RESTORE mode, and
    surfaces any vendor operations (>= 0x9000) we do not use. Pure read; nothing
    is written to the camera.
    """
    ptp = None
    try:
        ptp, model = open_camera(device, force=force)
        ops = sorted(ptp.supported_ops)
        props = sorted(ptp.supported_props)
        print(f"{model}: {len(ops)} operations, {len(props)} properties advertised")

        print("operations:")
        for op in ops:
            name = OP_NAMES.get(op) or ("vendor" if op >= 0x9000 else "")
            print(f"  0x{op:04X}  {name}")

        print("restore-path operations:")
        needed = (
            (OC_GET_OBJECT_INFO, "GetObjectInfo"),
            (OC_GET_OBJECT, "GetObject"),
            (OC_SEND_OBJECT_INFO, "SendObjectInfo"),
            (OC_SEND_OBJECT, "SendObject"),
        )
        for op, nm in needed:
            state = "advertised" if op in ptp.supported_ops else "NOT advertised"
            print(f"  0x{op:04X}  {nm:16}  {state}")

        vendor_ops = [op for op in ops if op >= 0x9000]
        if vendor_ops:
            print("vendor operations: " + " ".join(f"0x{op:04X}" for op in vendor_ops))

        print("properties: " + " ".join(f"0x{op:04X}" for op in props))
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


@app.command("sweep-props")
def sweep_props(
    ctx: typer.Context,
    start: Annotated[
        str, typer.Option(help="First property code (hex), e.g. 0xD000")
    ] = None,
    end: Annotated[
        str, typer.Option(help="Last property code (hex), e.g. 0xD4FF")
    ] = None,
    full: Annotated[
        bool, typer.Option("--full", help="Probe the whole 0x0000-0xFFFF space (slow)")
    ] = False,
    writable_only: Annotated[
        bool, typer.Option("--writable-only", help="Only list read/write properties")
    ] = False,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode check")
    ] = False,
):
    """Sweep the PTP device-property space and report which are writable.

    Reads each property's descriptor (GetDevicePropDesc) to learn its type and
    whether the camera declares it read-only or read/write, then reads its
    current value. This is a pure read: nothing is written to the camera. The
    declared read/write flag is what the camera advertises; a property can still
    reject a specific value in its current state (clarity 0xD1A2 on the X-T5 does
    exactly that), so use 'fuji-recipes dump-props' or a controlled write to
    confirm an actual write is accepted.
    """
    import fuji_recipes  # lazy import for the property-name table

    ptp = None
    try:
        ptp, model = open_camera(device, force=force)
        if ptp.supported_ops and OC_GET_DEVICE_PROP_DESC not in ptp.supported_ops:
            logging.warning(
                "camera does not advertise GetDevicePropDesc (0x1014); "
                "writability flags may be missing"
            )
        codes = _sweep_codes(start, end, full)
        logging.info(f"probing {len(codes)} property codes on {model}...")

        rows = []
        for i, code in enumerate(codes):
            try:
                desc = ptp.get_prop_desc(code)
            except PtpError:
                continue  # property not supported by this body
            except (RuntimeError, usb.core.USBError) as e:
                logging.debug(f"0x{code:04X}: descriptor read failed ({e})")
                continue
            if desc is None:
                continue
            try:
                raw = ptp.get_prop(code)
                value = raw[:8].hex() if raw else ""
            except (PtpError, RuntimeError, usb.core.USBError):
                value = ""
            rows.append((code, desc, value))
            if i and i % 1024 == 0:
                logging.info(f"  ...{i} codes probed, {len(rows)} present so far")

        writable = [r for r in rows if r[1]["writable"]]
        print(f"{model}: {len(rows)} properties present, {len(writable)} writable")
        print("  code    type   mode  adv  value             name")
        for code, desc, value in rows:
            if writable_only and not desc["writable"]:
                continue
            mode = "RW" if desc["writable"] else "R"
            adv = "*" if code in ptp.supported_props else " "
            tname = PTP_TYPES.get(desc["data_type"], f"0x{desc['data_type']:04X}")
            name = fuji_recipes.PROP_NAMES.get(code, "")
            print(f"  0x{code:04X}  {tname:5} {mode:4}  {adv}   {value:16}  {name}")
        print("  mode RW = declared read/write; adv * = advertised in DeviceInfo")
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


def _parse_only(only):
    codes = []
    for token in only.split(","):
        token = token.strip()
        if not token:
            continue
        try:
            codes.append(int(token, 0))
        except ValueError:
            logging.error(f"--only value {token!r} is not a number like 0xD029")
            sys.exit(1)
    return codes


@app.command("test-writable")
def test_writable(
    ctx: typer.Context,
    only: Annotated[
        str,
        typer.Option(
            help="Comma-separated property codes to test (hex), e.g. 0xD029,0xD030; "
            "default is every advertised setting property"
        ),
    ] = None,
    yes: Annotated[
        bool, typer.Option("--yes", help="Skip the confirmation prompt")
    ] = False,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode check")
    ] = False,
):
    """Find which PTP properties accept a write, by writing each value back to itself.

    The X-T5 exposes no property descriptors (see sweep-props), so writability is
    only knowable empirically. For each property this reads the current value and
    writes the SAME bytes back, recording whether the camera accepts (writable) or
    refuses it. Writing the same value changes nothing, but it is still a real
    write, so action/mode properties (USB mode, the raw-conversion flow) are
    refused, the active slot is saved and restored, and the sweep stops on the
    first USB error. Take a 'helios fuji-settings backup' first as a safety net.
    """
    import fuji_recipes  # lazy import for the property-name table

    ptp = None
    try:
        ptp, model = open_camera(device, force=force)

        if only:
            requested = _parse_only(only)
            candidates = [p for p in requested if p not in WRITE_TEST_DENYLIST]
            skipped = [p for p in requested if p in WRITE_TEST_DENYLIST]
        else:
            advertised = [p for p in ptp.supported_props if p >= 0xD000]
            candidates = sorted(p for p in advertised if p not in WRITE_TEST_DENYLIST)
            skipped = sorted(p for p in advertised if p in WRITE_TEST_DENYLIST)

        if not candidates:
            logging.error("no properties to test after applying the denylist")
            sys.exit(1)

        print(f"Camera: {model}")
        print(
            f"Will write each property's CURRENT value back to itself "
            f"({len(candidates)} properties). This changes no values, but it is a "
            "real write. Take a backup first:  helios fuji-settings backup"
        )
        if skipped:
            print(
                "Refusing to write these action/mode properties: "
                + " ".join(f"0x{p:04X}" for p in skipped)
            )
        print("Testing: " + " ".join(f"0x{p:04X}" for p in candidates))
        if not yes:
            if not sys.stdin.isatty():
                logging.error(
                    "no interactive terminal for the confirmation prompt; re-run "
                    "with --yes after reviewing the property list above"
                )
                sys.exit(1)
            try:
                confirmed = typer.confirm("Proceed with the write test?")
            except typer.Abort:
                confirmed = False
            if not confirmed:
                logging.info("aborted, nothing was written")
                sys.exit(0)

        original_slot = None
        if ACTIVE_SLOT_PROP in ptp.supported_props:
            try:
                original_slot = ptp.get_prop(ACTIVE_SLOT_PROP)
            except (PtpError, RuntimeError):
                logging.debug("could not read the active slot to restore it later")

        results = []
        aborted = None
        prop = None
        try:
            for prop in candidates:
                try:
                    raw = ptp.get_prop(prop)
                except (PtpError, RuntimeError) as e:
                    results.append((prop, "read-failed", str(e)[:32]))
                    continue
                if not raw:
                    results.append((prop, "read-failed", "no data"))
                    continue
                try:
                    ptp.set_prop(prop, raw)
                    results.append((prop, "writable", raw[:8].hex()))
                except PtpError as e:
                    results.append((prop, "rejected", f"0x{e.code:04X}"))
        except usb.core.USBError as e:
            aborted = f"USB error while testing 0x{prop:04X}: {e}"
        finally:
            if original_slot is not None:
                try:
                    ptp.set_prop(ACTIVE_SLOT_PROP, original_slot)
                except (PtpError, RuntimeError, usb.core.USBError):
                    logging.warning(
                        "could not restore the active slot; check it on the camera"
                    )

        accepted = [r for r in results if r[1] == "writable"]
        print(f"\n{len(accepted)}/{len(results)} tested properties accepted a write")
        for prop, status, detail in results:
            name = fuji_recipes.PROP_NAMES.get(prop, "")
            print(f"  0x{prop:04X}  {status:11} {detail:18} {name}")
        if aborted:
            logging.error(
                aborted + " -- stopped early; power-cycle the camera if unresponsive"
            )
            sys.exit(1)
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


if __name__ == "__main__":
    app()

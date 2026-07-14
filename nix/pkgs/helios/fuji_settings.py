import datetime
import logging
import os
import struct
import sys

import typer
import usb.core
import usb.util
from typing_extensions import Annotated

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
OC_GET_DEVICE_PROP_VALUE = 0x1015
OC_SET_DEVICE_PROP_VALUE = 0x1016

RC_OK = 0x2001
RC_SESSION_ALREADY_OPEN = 0x201E

PROP_USB_MODE = 0xD16E
USB_MODE_BACKUP_RESTORE = 6
# StartRawConversion, RawConvProfile, PresetSlot: only advertised in RAW
# CONV./BACKUP RESTORE mode, the fallback signal on bodies like the X-T5
# that do not expose the USB mode property at all
RAW_CONV_MODE_PROPS = (0xD183, 0xD185, 0xD18C)

FUJI_BACKUP_FORMAT = 0x5000
BACKUP_HANDLE = 0
# libfuji refuses larger files; real backups are tens of KB
MAX_RESTORE_SIZE = 100000
OBJECTINFO_SIZE = 1088

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
        manufacturer, model, props = parse_device_info(
            self.transaction(OC_GET_DEVICE_INFO)
        )
        self.supported_props = props
        return manufacturer, model

    def get_prop(self, prop):
        return self.transaction(OC_GET_DEVICE_PROP_VALUE, (prop,))

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
        info = struct.pack("<IHHI", 0, FUJI_BACKUP_FORMAT, 0, len(blob))
        info = info.ljust(OBJECTINFO_SIZE, b"\x00")
        self.transaction(OC_SEND_OBJECT_INFO, (0, 0), data=info)
        self.transaction(OC_SEND_OBJECT, data=blob)


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
        # OperationsSupported and EventsSupported: u16 arrays
        for _ in range(2):
            off = skip_ptp_array(data, off, 2)
        props, off = read_ptp_u16_array(data, off)  # DevicePropertiesSupported
        # CaptureFormats and ImageFormats: u16 arrays
        for _ in range(2):
            off = skip_ptp_array(data, off, 2)
        manufacturer, off = read_ptp_string(data, off)
        model, off = read_ptp_string(data, off)
        return manufacturer, model, frozenset(props)
    except (IndexError, struct.error, UnicodeDecodeError) as e:
        logging.warning(f"could not parse the camera DeviceInfo ({e})")
        return "unknown", "unknown", frozenset()


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


if __name__ == "__main__":
    app()

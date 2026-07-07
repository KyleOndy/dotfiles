import argparse
import asyncio
import shutil
import subprocess
import sys
import tempfile
import tkinter as tk
from pathlib import Path

from bleak import BleakScanner
from PIL import Image, ImageTk

TARGET_WIDTH, TARGET_HEIGHT = 1260, 840
TARGET_RATIO = TARGET_WIDTH / TARGET_HEIGHT
MAX_BYTES = 337920
MAX_JPEG_QUALITY = 80
MIN_JPEG_QUALITY = 30


async def discover_device_names():
    devices = await BleakScanner.discover(5.0, return_adv=True)
    names = []
    for device, (_adv_device, adv_data) in devices.items():
        name = adv_data.local_name or ""
        if name.upper().startswith("INSTAX-") and name.upper().endswith("(IOS)"):
            names.append(name)
    return names


def resolve_device_name(explicit_name):
    if explicit_name:
        return explicit_name
    names = asyncio.run(discover_device_names())
    if len(names) == 1:
        print(f"Found printer: {names[0]}")
        return names[0]
    if not names:
        sys.exit("No Instax printer found nearby. Pass --device-name explicitly.")
    sys.exit(
        "Multiple Instax printers found, pass --device-name explicitly:\n"
        + "\n".join(f"  {n}" for n in names)
    )


class CropWindow:
    def __init__(self, image):
        self.image = image
        self.result = None

        self.root = tk.Tk()
        self.root.title(
            "Crop for Instax Wide "
            "(drag=move, scroll=resize, [ ]=rotate, Enter=confirm, Esc=cancel)"
        )

        self.canvas = tk.Canvas(self.root)
        self.canvas.pack()

        self.canvas.bind("<ButtonPress-1>", self._on_press)
        self.canvas.bind("<B1-Motion>", self._on_drag)
        self.canvas.bind("<MouseWheel>", self._on_scroll)
        self.canvas.bind("<Button-4>", lambda e: self._resize(1.05))
        self.canvas.bind("<Button-5>", lambda e: self._resize(1 / 1.05))
        self.root.bind("<Return>", lambda e: self._confirm())
        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.root.bind("<Key-bracketright>", lambda e: self._rotate(clockwise=True))
        self.root.bind("<Key-bracketleft>", lambda e: self._rotate(clockwise=False))

        self._drag_start = None
        self._load_image(image)

    def _load_image(self, image):
        self.image = image
        self.scale = min(1000 / image.width, 700 / image.height, 1.0)
        self.disp_w = int(image.width * self.scale)
        self.disp_h = int(image.height * self.scale)

        display_image = image.resize((self.disp_w, self.disp_h), Image.LANCZOS)
        self.photo = ImageTk.PhotoImage(display_image)

        self.canvas.config(width=self.disp_w, height=self.disp_h)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor=tk.NW, image=self.photo)

        box_h = self.disp_h
        box_w = box_h * TARGET_RATIO
        if box_w > self.disp_w:
            box_w = self.disp_w
            box_h = box_w / TARGET_RATIO
        self.box_w, self.box_h = box_w, box_h
        self.box_x = (self.disp_w - box_w) / 2
        self.box_y = (self.disp_h - box_h) / 2

        self.rect = self.canvas.create_rectangle(
            *self._bounds(), outline="red", width=3
        )

    def _rotate(self, clockwise):
        angle = -90 if clockwise else 90
        self._load_image(self.image.rotate(angle, expand=True))

    def _bounds(self):
        return (
            self.box_x,
            self.box_y,
            self.box_x + self.box_w,
            self.box_y + self.box_h,
        )

    def _clamp_position(self):
        self.box_x = max(0, min(self.box_x, self.disp_w - self.box_w))
        self.box_y = max(0, min(self.box_y, self.disp_h - self.box_h))

    def _redraw(self):
        self.canvas.coords(self.rect, *self._bounds())

    def _on_press(self, event):
        self._drag_start = (event.x, event.y, self.box_x, self.box_y)

    def _on_drag(self, event):
        if self._drag_start is None:
            return
        sx, sy, ox, oy = self._drag_start
        self.box_x = ox + (event.x - sx)
        self.box_y = oy + (event.y - sy)
        self._clamp_position()
        self._redraw()

    def _on_scroll(self, event):
        self._resize(1.05 if event.delta > 0 else 1 / 1.05)

    def _resize(self, factor):
        cx, cy = self.box_x + self.box_w / 2, self.box_y + self.box_h / 2
        new_w = max(50, min(self.disp_w, self.box_w * factor))
        new_h = new_w / TARGET_RATIO
        if new_h > self.disp_h:
            new_h = self.disp_h
            new_w = new_h * TARGET_RATIO
        self.box_w, self.box_h = new_w, new_h
        self.box_x, self.box_y = cx - new_w / 2, cy - new_h / 2
        self._clamp_position()
        self._redraw()

    def _confirm(self):
        box = (
            self.box_x / self.scale,
            self.box_y / self.scale,
            (self.box_x + self.box_w) / self.scale,
            (self.box_y + self.box_h) / self.scale,
        )
        self.result = self.image.crop(box).resize(
            (TARGET_WIDTH, TARGET_HEIGHT), Image.LANCZOS
        )
        self.root.destroy()

    def run(self):
        self.root.mainloop()
        return self.result


def prepare_image(src_path):
    image = Image.open(src_path)
    image = image.convert("RGB")

    final = CropWindow(image).run()
    if final is None:
        sys.exit("Crop cancelled.")

    return final


def save_within_size_limit(image, out_path):
    for quality in range(MAX_JPEG_QUALITY, MIN_JPEG_QUALITY - 1, -5):
        image.save(out_path, "JPEG", quality=quality)
        size = out_path.stat().st_size
        if size <= MAX_BYTES:
            print(f"Saved at quality={quality}, {size} bytes.")
            return
    sys.exit(
        f"Could not compress under {MAX_BYTES} bytes even at quality={MIN_JPEG_QUALITY}."
    )


def main():
    parser = argparse.ArgumentParser(
        description="Crop/resize an image and print it to an Instax Link WIDE"
    )
    parser.add_argument("-i", "--image-path", required=True, type=Path)
    parser.add_argument("-n", "--device-name")
    parser.add_argument("-d", "--debug", action="store_true")
    args = parser.parse_args()

    device_name = resolve_device_name(args.device_name)
    final_image = prepare_image(args.image_path)

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir) / "instax-print.jpg"
        save_within_size_limit(final_image, tmp_path)

        cmd = [
            shutil.which("instax-link") or "instax-link",
            "-n",
            device_name,
            "-i",
            str(tmp_path),
        ]
        if args.debug:
            cmd.append("-d")
        subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()

"""Stretch a binary STL along Z at a constant-section band.

Every vertex at or below z0 moves down by amount, so the part gets longer
without scaling anything else. z0 must sit in a band whose cross-section does
not change, or the stretch distorts whatever it crosses.

Usage: stretch.py SRC DST Z0_MM AMOUNT_MM
"""

import struct
import sys

src, dst, z0, amount = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
data = open(src, "rb").read()
n = struct.unpack("<I", data[80:84])[0]

out = bytearray(data[:84])
moved = 0
for i in range(n):
    off = 84 + 50 * i
    v = list(struct.unpack_from("<12f", data, off))
    attr = struct.unpack_from("<H", data, off + 48)[0]
    for k in range(3):
        if v[5 + 3 * k] <= z0:
            v[5 + 3 * k] -= amount
            moved += 1
    out += struct.pack("<12fH", *v, attr)

open(dst, "wb").write(bytes(out))
print("vertices shifted: %d / %d" % (moved, 3 * n))

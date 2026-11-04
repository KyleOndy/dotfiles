"""Run the clamp slots of the +40 mm tool hub deeper.

Usage: deepen.py SRC DST
"""

import math
import sys

import numpy as np
import trimesh

SRC, DST = sys.argv[1], sys.argv[2]

W = math.radians(2.01)  # slot half-width; model is 2.000, 0.01 over for a clean boolean
R0, R1 = 45.0, 62.0  # spans the 50.15..55.30 wall with margin
Z_BOT = -64.0  # inside the existing straight slot, below its old vee at -63.50
Z_V = -23.50  # where the new vee starts
Z_TOP = -21.95  # vee point, same height above the flange as the original

pts = []
for z in (Z_BOT, Z_V):
    for s in (-1.0, 1.0):
        for r in (R0, R1):
            pts.append((r * math.cos(s * W), r * math.sin(s * W), z))
pts += [(R0, 0.0, Z_TOP), (R1, 0.0, Z_TOP)]
one = trimesh.PointCloud(np.array(pts)).convex_hull

cutters = []
for k in range(8):
    c = one.copy()
    c.apply_transform(
        trimesh.transformations.rotation_matrix(k * math.pi / 4, [0, 0, 1])
    )
    cutters.append(c)
cutter = trimesh.util.concatenate(cutters)
print("cutter: %d bodies, watertight=%s" % (cutter.body_count, cutter.is_watertight))

mesh = trimesh.load(SRC)
mesh.merge_vertices()
print(
    "input : %d tris, watertight=%s, volume=%.1f mm3"
    % (len(mesh.faces), mesh.is_watertight, mesh.volume)
)

out = trimesh.boolean.difference([mesh, cutter], engine="manifold")
out.merge_vertices()
print(
    "output: %d tris, watertight=%s, volume=%.1f mm3"
    % (len(out.faces), out.is_watertight, out.volume)
)
print(
    "removed: %.1f mm3 (%.2f%%)   bodies=%d"
    % (
        mesh.volume - out.volume,
        100 * (mesh.volume - out.volume) / mesh.volume,
        out.body_count,
    )
)
print("bbox:", np.round(out.bounds, 3).tolist())
out.export(DST)
print("wrote", DST)

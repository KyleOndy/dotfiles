# KeKap tool hub, extended

Our changes to the 4 in Tool Hub (`PN 4D`) from KeKap's Quick-Lock Modular Dust
Collection & Fume Fittings. That was a paid
[MakerWorld crowdfunding campaign](https://makerworld.com/crowdfunding/139), so
the meshes stay out of this public repo. These scripts rebuild our versions from
the purchased STL, which lives in
`~/Documents/3d-prints/kekap-dust-collection/adapter-4in/`.

The campaign link comes from the pledge email. The page refuses scripted
requests, so we have not read its license terms.

## Requirements

- Make the collar about 40 mm longer to fit over a longer port.
- Keep the ribs, chamfer, flange and bore as designed.
- Make the hub slide over the matching male fitting.

## Rebuilding

From this directory, with the purchased STL at `$HUB`:

```bash
python3 stretch.py "$HUB" hub-40mm.stl -17.0 40.0

nix shell --impure --expr 'with import <nixpkgs> {}; python3.withPackages
  (p: [ p.trimesh p.manifold3d p.numpy p.scipy p.networkx ])' \
  -c python3 deepen.py hub-40mm.stl hub-40mm-long-slots.stl
```

We checked both against the saved meshes. `stretch.py` matches byte for byte, and
`deepen.py` matches on size and volume (140 x 140 x 84 mm, 166812 mm³).

## Decisions

- **Stretch instead of scale**: Bambu Studio cannot stretch one region, and
  scaling would distort the ribs, chamfer and flange. `stretch.py` moves every
  vertex below a constant-section band, which took the height from 44 to 84 mm
  with the diameter unchanged.
- **Cut the slots with a boolean**: stretching through the slotted zone would have
  widened the 8.4 mm clamp groove to 48 mm and let the clamp wander. `deepen.py`
  cuts new slots matching the originals: 8 slots, 4 degrees wide, on 45 degree
  centers, ending in a vee.
- **Slots from 22 to 62 mm deep**: the printed +40 mm hub would not slide on, and
  the longer fingers should give about 20x more. They stop 10 mm short of the
  flange.
- **Bore stays 100.29 mm**: if it's still tight, open the bore rather than cutting
  more slots.

## Printing

SUNLU PETG, 6 walls, 25% grid, from our saved +40 mm project.

## State

- **+40 mm**: printed, and too tight to slide on.
- **+40 mm long-slots**: no print confirmed.

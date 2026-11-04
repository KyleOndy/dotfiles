# Oneida cyclone wall spacer

A stabilizing spacer between the motor housing of our Oneida Super Cyclone and
the wall. The arc scoop sits against the housing and the flange screws to the
wall.

The source is the
[Onshape Part Studio](https://cad.onshape.com/documents/684f8a357ea83e1cdb38c9cc/w/eb0aa5e3d9021ec86670cda7/e/12907ee6bbae3653cbd3b905).
The variables below drive all of it. `oneida-cyclone-wall-spacer.3mf` is the
Bambu project we saved, and its mesh matches the final Onshape export.

This one is in use.

## Requirements

- Cradle a cylinder 4 ft in circumference.
- Hold the nearest point of the cylinder 1 7/8 in from the wall.
- Screw to the wall from every side.
- Stay at most 130 mm tall and fit the A1 mini's 180 mm bed.

## Variables

| Variable           | Value                                                            | Notes                                          |
| ------------------ | ---------------------------------------------------------------- | ---------------------------------------------- |
| `#length`          | 130 mm                                                           | Block width. Overall is this plus 2 overhangs  |
| `#circumference`   | 4 ft                                                             | Of the cylinder being cradled                  |
| `#flangeThickness` | 6 mm                                                             | Backplate                                      |
| `#standoff`        | 1.875 in                                                         | Wall face to the nearest point of the cylinder |
| `#depth`           | `#standoff - #flangeThickness + R - sqrt(R^2 - (#length / 2)^2)` | Derived, R is `#circumference / (2 * PI)`      |
| `#height`          | 90 mm                                                            | Block height. Overall is this plus 2 overhangs |
| `#flangeOverhang`  | 20 mm                                                            | Backplate oversail on every side               |
| `#screwClearance`  | 0.1935 in                                                        | #8 free-fit hole                               |
| `#screwInset`      | 10 mm                                                            | Hole center to backplate edge                  |
| `#filletRadius`    | 6 mm                                                             | Block-to-flange blend                          |

That comes out to 170 x 58.8 x 130 mm overall.

## Decisions

- **Real arc cut**: the scoop is cut from a circle sized by `#circumference`, so
  a different cylinder is one variable away.
- **Flange on all four sides**: a single lip would leave screws on one side only.
  The perimeter backplate takes a #8 at each corner.
- **`#depth` is derived, not typed**: widening the block deepens the scoop, which
  pulls the cylinder toward the wall. Deriving it holds the 1 7/8 in standoff at
  any width.
- **`#length` of 130 mm**: `#length` plus the overhangs has to fit the bed, so it
  tops out at 140 mm.
- **6 mm fillet at the block-to-flange corner**: that corner takes the peak
  stress. `#depth` is the moment arm, so cutting it does more than a bigger
  fillet. A fillet past about 20 mm runs off the overhang.

## Printing

Saved in the project: A1 mini, Bambu PLA Basic, 0.20 mm layers, 2 walls, 15% grid,
no supports.

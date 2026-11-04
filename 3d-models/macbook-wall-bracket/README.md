# MacBook wall bracket

Two mirrored brackets that hold a MacBook Pro 16" or a MacBook Air 15" against
the wall, lid out, standing on its front edge. They replace a MakerWorld
MacBook Air mount (Ace's Designs, "MacBook Air Wall Mount") that the Pro does
not fit.

## Requirements

- Hold either laptop, one at a time, on the same two brackets.
- The Air cannot fall out, even slid all the way to one side.
- Mount into drywall anchors with enough screw in each anchor.
- Keep the 3-hole pattern at 30 mm pitch. This is a nice-to-have. The distance
  between the brackets is free.
- Print on the A1 mini without supports.
- Use less plastic than the mount it replaces.

## Laptops

| Laptop                                                           | Width    | Depth    | Thickness | Weight  |
| ---------------------------------------------------------------- | -------- | -------- | --------- | ------- |
| [MacBook Pro 16" (2024)](https://support.apple.com/en-us/121554) | 355.7 mm | 248.1 mm | 16.8 mm   | 2.14 kg |
| [MacBook Air 15" (M5)](https://support.apple.com/en-us/126321)   | 340.4 mm | 237.6 mm | 11.5 mm   | 1.51 kg |

## Mounting

- **Hole columns**: 388 mm apart, center to center. Keep them level with each
  other, because any offset tilts the laptop.
- **Holes**: 3 per bracket, 30 mm apart, 20, 50 and 80 mm above the bracket's
  bottom edge.
- **Wall space**: 408 mm from one flange edge to the other.
- **Screws**: 4.5 mm holes clear #6, #8 and M4. The countersink opens to 9 mm,
  so flat and pan heads both seat.
- **Screw length**: reach past the back of the bracket is screw length minus
  5 mm. That should be at least the anchor's length, so a 25 mm anchor wants a
  32 mm (1-1/4 in) screw or longer.

## Printing

The 3MF is a Bambu Studio project, so it carries these settings and the plate.
It is already in print orientation, ledge on the bed.

- A1 mini, SUNLU PLA+ 2.0, 0.20 mm layers, no supports
- 3 walls, 10% gyroid
- 96 g and 2h17 for the pair, from a Bambu Studio slice

After changing the source, export a fresh mesh from this directory:

```bash
nix shell nixpkgs#openscad-unstable -c openscad-unstable \
  --backend=manifold --hardwarnings \
  -o /tmp/macbook-wall-bracket.3mf macbook-wall-bracket.scad
```

Import that into the project in place of the old mesh. Exporting over the
project file would lose its settings.

The `assert`s in the source fail the build if a change stops the Pro fitting or
drops the Air below 20 mm of lip.

## Decisions

- **New model instead of a scaled one**: scaling the old mount's depth to 120%
  fit the Pro, but it stretched the screw path from 19 to 22.8 mm and the
  screws stopped reaching the anchors. Deepening the wells fixed that and left
  a 27.6 mm back plate doing nothing. We started over.
- **Screws outside the side walls**: the head sits on a 5 mm flange instead of
  down a well behind the laptop. That gives the most reach, a clear path for
  the driver, and no screw head near the laptop. The cost is 408 mm of wall,
  and the old anchors can only carry one of the brackets.
- **30 mm hole pitch**: kept from the old mount so one bracket can stay on its
  existing anchors. A wider pitch would be slightly better in drywall, but not
  enough to give that up.
- **Side walls 360 mm apart**: 4.3 mm of total play for the Pro, which absorbs
  hand-drilled holes.
- **40 mm lips and a 55 mm ledge**: the Air has 19.6 mm of slack. Slid fully to
  one side, it keeps 20.4 mm of lip and 35.4 mm of ledge on the far bracket.
  The old lip was 20 mm on a laptop that fit snugly, so that was our target.
- **19 mm slot**: 2.2 mm over the Pro. The Air gets 7.5 mm of front-to-back
  play. It just rests on the lip or the back plate, so we did not add a spacer.
- **100 mm tall**: down from 130 mm. The laptop cannot tip past a lip this
  height, and a shorter side wall saves plastic and should stay below the
  ports.
- **Hook at the bottom of the lip**: it holds the laptop lower down and avoids a
  sharp corner where the lip meets the ledge.
- **Flared top of the slot**: 2 mm per side over the top 8 mm, so the laptop
  drops in without lining up both edges exactly.
- **3 walls, 10% gyroid**: each bracket carries about 10 N, so infill is not the
  limit. The walls are thin enough that 3 perimeters nearly fill them, and the
  flange under the screw heads is where the strength matters. 2 walls would
  save 25 g, but we kept the third for that flange.

## Not checked yet

- Nothing has been printed or hung.
- Whether Apple's 16.8 mm includes the rubber feet. The feet sit on the wall
  side of the slot, so if they stick out past that figure they eat into the
  2.2 mm of margin.
- Whether the Pro's lowest side port clears the 100 mm side wall.

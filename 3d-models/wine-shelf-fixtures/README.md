# Wine shelf fixtures

Printed jigs for the 15 brass stemware hangers under the wine shelf. They bend,
trim, lay out and glue the hangers. The hanger design itself stays in the `wood`
repo, in `wine-shelf/hangers.md` and `wine-shelf/drawings/`.

Each `.fs` file is the FeatureScript source for a Feature Studio in the Onshape
document
[wine rack spacer](https://cad.onshape.com/documents/4d62c609a52e4df37a2b2844/w/0bd51db71181deb18c227807/e/4711f87b6c58a2c59e71fc8b).
Onshape holds a pasted copy, and the file here wins if they disagree.

Each print has its version debossed on its +y side face, like `TRIM v2`, and the
Onshape part name matches. Prints from before the marks went on have none.

| Fixture       | Current | Source             | Print file                   | Onshape part                                                     |
| ------------- | ------- | ------------------ | ---------------------------- | ---------------------------------------------------------------- |
| Trim block    | v3      | `trim-block.fs`    | `trim-block-v3.stl`          | "Trim block v3" in the Trim block studio                         |
| Glue cradle   | v1      | `glue-cradle.fs`   | `glue-cradle.3mf`            | "Glue cradle v1" in Part Studio 1                                |
| Step template | v2      | `step-template.fs` | `step-template.3mf`          | "Step template v2" in the Step template studio                   |
| Bend plate    | v4      | `bend-plate.fs`    | `bend-plate.3mf`             | "Bend plate v4" and "Bend stop v4" in the Bend plate studio      |
| Pin coupons   | v1      | `bend-plate.fs`    | `pin-coupon-<clearance>.stl` | "Pin coupon 0.05" to "Pin coupon 0.20" in the Pin coupons studio |

## Requirements

- Every hanger comes out the same, without measuring each one. That is 15
  hangers, 60 leg holes and 68 saw cuts.
- Tell any printed fixture apart in hand.
- Fit the A1 mini's 180 mm bed.
- When a real measurement changes a dimension, the record shows what we measured
  and why.

## Decisions

These cover every fixture. The version log below holds the reasons for each
change to a single fixture.

- **FeatureScript in Onshape**: OpenSCAD was the other option. The `.fs` keeps
  every dimension as a named constant, so the file alone describes a version.
- **Debossed `MARK` on every print**: an unmarked jig on the bench could be any
  version.
- **PLA**: the clearances were tuned on it, so a filament swap means new
  coupons. The trim block also stays PLA because saw teeth scrape it instead of
  smearing it. The bend plate only moves to PETG if PLA cracks.
- **Breakaway fins on the glue cradle**: three 1.2 mm fins per side snap outward
  after the epoxy cures. We are fine destroying a cradle to get it out, and it
  stays clear of the holes so it cannot get glued to the shelf.
- **Pin coupons before the plate**: about 9 cm³ each against 158 for the plate,
  so a clearance guess costs almost nothing.

## Printing

All PLA on the A1 mini at 0.20 mm layers, no supports.

| Fixture       | Walls | Top layers | Infill        | Why                                                                    |
| ------------- | ----- | ---------- | ------------- | ---------------------------------------------------------------------- |
| Trim block    | 4     | 6 or more  | 40% gyroid    | It takes 68 saw cuts. No Bambu project saved, slice the STL.           |
| Glue cradle   | 2     | 7          | 10% lightning | Nothing pushes on the sides. The top layers stop the rod seat sagging. |
| Step template | 2     | 5          | 15% grid      | Saved in the project.                                                  |
| Bend plate    | 6     | 5          | 25% grid      | Saved in the project with the stop, filling the bed at 24.5 deg.       |

## State

These come from what we said in our sessions, since Bambu Studio's logs are
encrypted.

- **Trim block**: v1 printed. v3 exported, print not confirmed.
- **Glue cradle**: project saved, print not confirmed.
- **Step template**: printed, almost certainly v2.
- **Bend plate**: v2 printed and fit. v4 project saved 2026-10-22, print not
  confirmed.
- **Pin coupons**: printed and tried on the bender.

## Versions

### Trim block

- **v3** (2026-10-19): drill guide for a 3/32 cross hole through the leg, 3/16
  below the cut line, straight across the block through both side faces. Epoxy
  in the hole keys the leg into the shelf. The guide is 3/32 plus 0.1 mm a side,
  pointed on top so it prints without support. Marked `TRIM v3`.
- **v2** (2026-10-19): 0.3 mm clearance per side, so the bore and channel are
  6.95 mm for the 1/4 (6.35 mm) rod. Marked `TRIM v2`.
- **v1** (2026-10-19): 0.2 mm clearance per side, 6.75 mm bore. The print was a
  hair tight getting the rod through. No mark.

### Glue cradle

- **v1** (2026-10-19): 0.125 mm clearance per side, rods 1 1/4 apart on centers,
  1 3/8 drop. Marked `CRADLE v1`.

### Step template

- **v2** (2026-10-20): both rows step off from the same end. v1 stepped them
  from opposite ends, which turned pitch error into 14 times as much skew
  between each hanger's front and back legs, and keeping that inside the 1/32 of
  play around a leg meant holding the pitch to 0.05 mm. Now both rows share the
  error and it only slides the hangers along the shelf. INDEX and NEXT are A and
  B, the back row pins through B, and BACK START sits past B, which takes the
  plate to 151.8 mm. The fence drops 24 mm below the shelf face, up from 12, for
  more bearing on the long face. Marked `STEP v2`.
- **v1** (2026-10-20): 1/8 bit guides at 0, 1 1/4, 3 7/8 and 4 1/2 on a line 3/4
  off the fence, plus FRONT START and BACK START for the first move off each
  end. 0.1 mm clearance a side. Replaces a tape pull and an awl for the 60 leg
  hole centers. Marked `STEP v1`.

### Bend plate

- **v4** (2026-10-22): 0.2 mm a side on the pins, from the pin coupons. 0.15 took
  force to seat, and the plate goes on and off the pins a few times for every
  side. The stop is unchanged. Both parts marked `BEND v4`.
- **v3** (2026-10-22): v2 printed and fit, with a little play on the pins.
  - **Angle fins:** three fins hang 1.5 mm over the rod, each 2 mm beside where a
    leg lies at exactly 90, R 45 or L 45, with a window to see the leg through.
    Bending to them replaces the handle stops, which the vise made hard to rig.
  - **Notches:** closed round holes, walls down to 1.5 mm over the rod except
    over the leg's bend. v2's open mouth let the leg lean away from the pins, and
    its walls only held the top 20 mm of it.
  - **Stop:** a lip over the leg at the stop face, 0.4 mm clear, so the front leg
    stays flat and the back leg bends in the same plane. It's a roof the leg
    slides under, not v1's step on the floor's edge.
  - **Pins:** 0.15 mm a side, down from 0.3. The play let the plate turn up to
    about a degree, which is too much for the fins.
  - **Bed:** the plate fills the A1 mini's 180 bed less 1 mm a side, turned 24.5
    degrees, and the fins run until the bed edge trims them. The stop prints on
    its own.

  Both parts marked `BEND v3`.

- **v2** (2026-10-20): the stop has no lip. The 12 bar runs about 2 1/2 past the
  stop face, right over the slot, so the front leg couldn't drop in from above.
  Getting in meant sliding over the 4 mm lip with 0.4 mm under the bar, and none
  with a bar a hair over 3/4. The floor now runs 14 mm out from the stop face
  with a 1.5 mm chamfer on its outboard edge, and the leg slides in flat with 4.4
  mm under the bar. The plate is the same as v1. Both parts marked `BEND v2`.
- **v1** (2026-10-20): plate that sits on the Huth bender's center and backing
  pin tops, with R and L notches for the flare and a channel for a 3/4 square
  bar, plus a stop that rides the bar for the back-leg 90. Pin geometry measured
  on the bender: 12.70 pins, 29.15 center to backing and 23.15 center to swing on
  centers (gauge blocks), all three tops 31.8 above the arm. 0.3 mm a side on the
  pins, 0.2 on the notches. Both parts marked `BEND v1`.

### Pin coupons

The bend plate's center pocket and backing slot alone, built by the Pin coupons
feature in `bend-plate.fs` from the same constants. Print them before the plate,
try each on the bender's pins, and set `PIN_CLEARANCE` to the snuggest one that
drops on and lifts off without binding. Each carries its clearance a side
instead of a version mark.

- **v1** (2026-10-22): 0.05, 0.10, 0.15 and 0.20 mm a side, about 9 cm³ each
  against the plate's 158. BEND v2 had a little play at 0.3. On the bender, 0.20
  drops on snug and 0.15 seats with a bit of force, which set BEND v4.

## Changing a fixture

Anything that changes the print bumps the version, whether it's in the `.fs` or a
parameter on the Onshape feature.

1. Change the geometry and `MARK` in the `.fs`.
2. Paste the `.fs` into its Feature Studio. The feature parameters in Onshape
   stay on the `.fs` defaults, so the file alone describes each version.
3. Rename the part in Onshape to match the mark.
4. Add a line here with what changed and what we measured that called for it,
   then commit.

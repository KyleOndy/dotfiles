# Jumper wire trays

Six trays for the ELEGOO EL-CP-0059 kit: M-M, M-F and F-F, each at 10 cm and
20 cm. The kit ships as six 40-pin ribbons in 10 colors, four wires per color.
A tray holds eight per color, so a second kit fits.

```bash
nix run .#jumper-trays                    # every part, to out/<part>.3mf
nix run .#jumper-trays -- fit-test        # only the named parts
nix run .#jumper-trays -- edit fit-test   # OpenSCAD GUI, redraws on every save
```

The tooling is a copy of the domestique case's
([render.sh](../../keyboard/domestique-pad/case/render.sh)), including the
bed-size check.

## Criteria

- Sort by type, length and color, so one grab gets the right wire.
- Live in a drawer between builds and on the desk during one.
- Put a wire back as easily as taking it out. The ribbon already sorts by
  color, but a used wire never goes back on it.
- Fit the A1 mini's 180 mm bed.

## Decisions

- **Loose wires, not ribbons**: we pull ribbons apart as we go anyway.
- **Wires lie straight between two combs**: a U-fold is smaller on the desk
  but the 20 cm wires would need about 11 cm of drawer height.
- **One tray per type and length**: three type rows side by side would be about
  50 cm wide, and stepped rows bury the lower ones. Six trays also means taking
  out only what a build needs.
- **Deep slots, one wire wide and eight high**: the wires in a slot are
  identical, so the top one is always the right one. A pocket four wires wide
  lets one or two wires slide around. Gravity holds them, since the trays sit
  level and rarely move.
- **Rejected, a lip at the slot mouth**: the fit test's lips were 0.15 to 0.25
  mm a side and none of them caught a housing. The plain 2.7 slots held fine,
  so we dropped it rather than make it bigger.
- **Combs and rails as separate parts**: a 20 cm tray is about 230 mm long and
  too wide to fit the bed even diagonally. A rail up to about 20 mm wide does, so
  rails print diagonally and are saved already turned 45 degrees. The 10 cm
  trays use the same parts with shorter rails.
- **Debossed labels**: the type ("M-F") on the comb and a resistor color code
  digit under each slot, so an empty slot still says which color goes there.
  Debossed rather than raised so a Sharpie fill stays put.
- **Stacking pins**: two stacks of three in the drawer.
- **Rejected, buying one**: nothing off the shelf sorts by type, length and
  color. The printable designs we looked at were either slot-per-wire combs
  for one length or Gridfinity bins, which need a baseplate.

## Fit test

Print `fit-test.3mf` in the filament the trays will use. Each piece has its
value engraved. The first print gave the values now in `params.scad`.

- **Slot widths** (2.7 to 3.1 mm): load wires into each and keep the narrowest
  one they drop into without a push. 2.7 held them well.
- **Rail sockets** (0.05 to 0.20 mm a side): push a stub into each and keep the
  one that holds without glue or a mallet. 0.15.
- **Stack sockets** (0.1 to 0.3 mm a side): keep the loosest one that doesn't
  rattle on the pin tab. The pin went into 0.3.
- **Label strip**: digits at the comb's real pitch in two sizes and a type
  label. Fill them with a Sharpie and keep the size that reads. 3 mm.

## Still needed before the comb

- The gap between the plastic ends of one wire from each ribbon, since the
  comb spacing comes from the shortest.
- The body length of a male and a female housing, to check `pocket`.
- The color order along a ribbon, which sets the digit order.

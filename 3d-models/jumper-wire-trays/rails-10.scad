// All six 10 cm rails, two per tray.
include <params.scad>
use <shapes.scad>

for (i = [0 : 5])
    translate([i * (rail_width + 6), 0, 0]) rail(wire_gap_10);

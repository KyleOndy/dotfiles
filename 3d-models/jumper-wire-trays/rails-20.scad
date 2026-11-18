// Three of the six 20 cm rails, so print it twice. Turned 45 degrees because a
// rail is longer than the bed.
include <params.scad>
use <shapes.scad>

rotate([0, 0, 45])
    for (i = [0 : 2])
        translate([i * (rail_width + 6), 0, 0]) rail(wire_gap_20);

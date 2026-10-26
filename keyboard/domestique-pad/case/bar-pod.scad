// Two keys stacked across the base bar, facing forward. A strap holds a saddle
// cut to the taped bar against its front.
include <params.scad>

// From the plate top: 5 of switch housing and 3.3 of pins, then room to solder
// a wire on and bend it out through either open end of the bay.
switch_depth = 12;
plate_thickness = 5;
wall = 2;
// The cap face prints on the bed, and the chamfer keeps first-layer squish out
// of the cutout.
chamfer = 0.4;
// Width along the bar and thickness: a 1/2" velcro strap, or two zip ties up
// to 4.8 mm wide side by side.
strap = [14, 3];
skin = 1.2;
// Degrees either side of the bar's front that the saddle wraps.
wrap = 55;

r = bar_diameter / 2;
width = 2 * key_pitch + 2 * wall;
depth = key_pitch + 2 * wall;
back = r * cos(wrap);
floor_top = r + skin + strap[1] + skin;
plate_top = floor_top + switch_depth;

$fn = 128;

module switch_hole() {
    base = plate_top - plate_thickness;
    translate([-switch_cutout / 2, -switch_cutout / 2, base - 1])
        cube([switch_cutout, switch_cutout, plate_thickness + 2]);
    translate([-switch_relief / 2, -switch_relief / 2, base - 1])
        cube([switch_relief, switch_relief, plate_thickness - switch_plate + 1]);
    translate([0, 0, plate_top - chamfer])
        linear_extrude(chamfer + 0.01, scale = (switch_cutout + 2 * chamfer) / switch_cutout)
            square(switch_cutout, center = true);
}

// Modeled as mounted: the bar's center on the origin, running along y, keys
// facing forward along +z.
module pod() {
    difference() {
        union() {
            translate([-width / 2, -depth / 2, back])
                cube([width, depth, floor_top - back]);
            // Two outer walls and a rib between the switches.
            for (x = [-width / 2, -wall / 2, width / 2 - wall])
                translate([x, -depth / 2, floor_top]) cube([wall, depth, switch_depth]);
            translate([-width / 2, -depth / 2, plate_top - plate_thickness])
                cube([width, depth, plate_thickness]);
        }
        rotate([90, 0, 0]) cylinder(r = r, h = depth + 2, center = true);
        translate([-width / 2 - 1, -strap[0] / 2, r + skin])
            cube([width + 2, strap[0], strap[1]]);
        for (x = [-key_pitch / 2, key_pitch / 2])
            translate([x, 0, 0]) switch_hole();
    }
}

// Upside down to print: cap face on the bed, saddle up.
translate([0, 0, plate_top]) rotate([0, 180, 0]) pod();

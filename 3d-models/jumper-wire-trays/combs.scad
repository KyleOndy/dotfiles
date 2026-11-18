// All twelve combs, a front and a back for each of the six trays.
include <params.scad>
use <shapes.scad>

types = ["M-M", "M-F", "F-F"];
lengths = [10, 20];
type_size = 4;
gap = 6;

$fn = 64;

pitch = slot_width + slot_wall;
side = rail_width + 2 * rail_clearance + 2 * socket_wall;
width = colors * pitch + slot_wall + 2 * side;
depth = pocket + stop;
// Clears the stack socket below it.
rail_floor = stack_pin_height + 2;

function slot_x(i) = side + slot_wall + slot_width / 2 + i * pitch;

// Outer face at y = 0, the span toward +y. The back comb faces the other way,
// so its digits run backwards to keep each color on one line across the tray.
module comb(type, length, back) {
    difference() {
        union() {
            cube([width, depth, comb_height]);
            translate([0, -ledge, 0]) cube([width, ledge, comb_base]);
            for (x = [side / 2, width - side / 2])
                translate([x, depth / 2, comb_height]) pin();
        }
        for (i = [0 : colors - 1]) {
            translate([slot_x(i), 0, 0]) slot_void(slot_width);
            translate([slot_x(i), -ledge / 2, comb_base - label_depth])
                label_text(str(back ? colors - 1 - i : i), digit_size);
        }
        for (x = [side / 2, width - side / 2]) {
            translate([x - rail_width / 2 - rail_clearance, depth - rail_socket_depth,
                       rail_floor - rail_clearance])
                cube([rail_width + 2 * rail_clearance, rail_socket_depth + 1,
                      rail_height + 2 * rail_clearance]);
            translate([x, depth / 2, -1])
                cylinder(d = stack_pin + 2 * stack_clearance, h = stack_pin_height + 1.5);
        }
        // On the outer face, which is what shows on a stack.
        for (end = [[side / 2, type], [width - side / 2, str(length)]])
            translate([end[0], label_depth, comb_height / 2])
                rotate([90, 0, 0]) label_text(end[1], type_size);
    }
}

for (c = [0 : len(lengths) - 1], r = [0 : len(types) - 1], back = [0, 1])
    translate([c * (width + gap), ledge + (2 * r + back) * (depth + ledge + gap), 0])
        comb(types[r], lengths[c], back == 1);

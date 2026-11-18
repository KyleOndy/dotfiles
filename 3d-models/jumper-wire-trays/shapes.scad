// Shapes the fit test and the real parts share, so the parts get what the
// test print measured.
include <params.scad>

// Centered on x = 0. The outer face is y = 0 and the pocket opens through it;
// the stop runs from y = pocket to pocket + stop, with the wire slit through
// it. Open at the top.
module slot_void(width) {
    translate([-width / 2, -1, comb_base])
        cube([width, pocket + 1, comb_height - comb_base + 1]);
    translate([-wire_slit / 2, pocket - 1, comb_base])
        cube([wire_slit, stop + 2, comb_height - comb_base + 1]);
}

module label_text(t, size = 3) {
    linear_extrude(label_depth + 0.01)
        text(t, size = size, font = label_font,
             halign = "center", valign = "center");
}

module pin() {
    chamfer = 0.4;
    cylinder(d = stack_pin, h = stack_pin_height - chamfer, $fn = 64);
    translate([0, 0, stack_pin_height - chamfer])
        cylinder(d1 = stack_pin, d2 = stack_pin - 2 * chamfer, h = chamfer, $fn = 64);
}

// gap is a wire's measured gap between housings. Seated in both sockets, the
// rail puts the stops' pocket faces gap - gap_slack apart.
function rail_length(gap) = gap - gap_slack - 2 * stop + 2 * rail_socket_depth;

module rail(gap) {
    cube([rail_width, rail_length(gap), rail_height]);
}

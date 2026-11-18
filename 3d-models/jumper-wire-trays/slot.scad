// The space one slot cuts from a comb. The fit test and the comb both use it,
// so the comb gets the slot the test print measured.
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

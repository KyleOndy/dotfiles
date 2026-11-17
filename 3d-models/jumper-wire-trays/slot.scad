// The space one slot cuts from a comb. The fit test and the comb both use it,
// so the comb gets the slot the test print measured.
include <params.scad>

// Centered on x = 0. The outer face is y = 0 and the pocket opens through it;
// the stop runs from y = pocket to pocket + stop, with the wire slit through
// it. Open at the top.
module slot_void(width, mouth) {
    lip = (width - mouth) / 2;
    lip_base = comb_base + stack_height;
    difference() {
        translate([-width / 2, -1, comb_base])
            cube([width, pocket + 1, comb_height - comb_base + 1]);
        // A ridge on each wall, chamfered both ways so a housing snaps past
        // it going in and coming out.
        if (lip > 0)
            for (side = [-1, 1])
                translate([0, pocket + 1, 0])
                    rotate([90, 0, 0])
                        linear_extrude(pocket + 2)
                            polygon([
                                [side * (width / 2 + 0.01), lip_base],
                                [side * (width / 2 - lip), lip_base + lip_height / 2],
                                [side * (width / 2 + 0.01), lip_base + lip_height],
                            ]);
    }
    translate([-wire_slit / 2, pocket - 1, comb_base])
        cube([wire_slit, stop + 2, comb_height - comb_base + 1]);
}

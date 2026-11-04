// Left and right wall brackets that hold a MacBook Pro 16" or MacBook Air 15"
// standing on edge. All dimensions in mm. Z runs up the wall, Y out from it,
// X toward the laptop. Print orientation: ledge on the bed, no supports.

pro = [355.7, 16.8];  // width, thickness
air = [340.4, 11.5];

side_spacing = 360;  // between the inner faces of the two side walls
slot_gap = 19;
back_t = 3;
lip_t = 4;
side_t = 4;
ledge_t = 5;
lip_reach = 40;    // from the side wall's inner face
hook_reach = 55;
hook_h = 22;
height = 100;
lead_h = 8;

flange_w = 20;
flange_t = 5;
hole_d = 4.5;      // clears #6, #8 and M4
head_d = 9;        // countersink mouth, pan heads seat on it too
hole_z = [20, 50, 80];

depth = back_t + slot_gap + lip_t;
hole_x = -side_t - flange_w / 2;
air_slack = side_spacing - air[0];

assert(side_spacing > pro[0] && slot_gap > pro[1]);
assert(lip_reach - air_slack >= 20, "Air slid to one side must keep 20 mm of lip");
echo(hole_columns_apart = side_spacing - 2 * hole_x);
echo(air_lip_overlap_worst = lip_reach - air_slack);
echo(air_ledge_overlap_worst = hook_reach - air_slack);

$fn = 64;

module reach_outline() {
    root = -side_t / 2;
    intersection() {
        offset(r = 3) offset(delta = -3)
        offset(r = -8) offset(delta = 8)
        union() {
            translate([root, -10]) square([lip_reach - root, height + 10]);
            translate([root, -10]) square([hook_reach - root, hook_h + 10]);
        }
        translate([root, 0]) square([hook_reach - root, height]);
    }
}

module reach_plate(y, t) {
    translate([0, y + t, 0]) rotate([90, 0, 0]) linear_extrude(t) reach_outline();
}

module spine() {
    linear_extrude(height)
    offset(r = 1.5) offset(delta = -1.5)
    offset(r = -4) offset(delta = 4)
    union() {
        translate([-side_t, 0]) square([side_t, depth]);
        translate([-side_t - flange_w, 0]) square([flange_w + side_t, flange_t]);
    }
}

module ledge() {
    linear_extrude(ledge_t)
    translate([-side_t / 2, 0]) square([side_t / 2 + hook_reach, depth]);
}

// Prism along +Y that cuts `inset` into the +X side of a face at x = 0.
module wedge(inset, len) {
    translate([0, len, height - lead_h]) rotate([90, 0, 0]) linear_extrude(len)
        polygon([[-1, 0], [0, 0], [inset, lead_h], [inset, lead_h + 1], [-1, lead_h + 1]]);
}

// Flares the top of the slot so the laptop drops in without exact alignment.
module lead_in() {
    reach = lip_reach + 1;
    translate([0, back_t, 0]) mirror([1, 0, 0]) wedge(2, slot_gap);
    translate([reach, back_t + slot_gap, 0]) rotate(90) wedge(2, reach + 1);
    translate([0, back_t, 0]) rotate(-90) wedge(1.5, reach);
}

module screw_hole(z) {
    translate([hole_x, -1, z]) rotate([-90, 0, 0]) {
        cylinder(d = hole_d, h = flange_t + 2);
        translate([0, 0, flange_t + 1 - (head_d - hole_d) / 2])
            cylinder(d1 = hole_d, d2 = head_d, h = (head_d - hole_d) / 2 + 0.01);
        translate([0, 0, flange_t + 1]) cylinder(d = head_d, h = 1);
    }
}

module bracket() {
    difference() {
        union() {
            spine();
            ledge();
            reach_plate(0, back_t);
            reach_plate(back_t + slot_gap, lip_t);
        }
        lead_in();
        for (z = hole_z) screw_hole(z);
    }
}

plate_gap = 10;
offset_x = (hook_reach - side_t - flange_w) / 2;
translate([-offset_x, plate_gap / 2, 0]) bracket();
translate([offset_x, -plate_gap / 2 - depth, 0]) mirror([1, 0, 0]) bracket();

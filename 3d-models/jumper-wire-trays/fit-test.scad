// One plate of fit tests, printed before any comb or rail. The value that fits
// best on each piece goes into params.scad.
include <params.scad>
use <slot.scad>

slot_widths = [2.7, 2.8, 2.9, 3.0, 3.1];
// Each on a slot_width slot; the first has no lip.
slot_mouths = [slot_width, 2.6, 2.5, 2.4];
// Per side.
rail_clearances = [0.05, 0.10, 0.15, 0.20];
stack_clearances = [0.1, 0.2, 0.3];

// Wider than a comb's real pitch so each value fits under its slot.
test_pitch = 10;
ledge = 7;
socket_wall = 2;
stub_length = 30;
gap = 6;

$fn = 64;

// places is 1 or 2.
function fmt(v, places) =
    let(scale = pow(10, places), n = round(v * scale),
        whole = floor(n / scale), frac = n - whole * scale)
    str(whole, ".", places == 2 && frac < 10 ? "0" : "", frac);

module label_text(t, size = 3) {
    linear_extrude(label_depth + 0.01)
        text(t, size = size, font = label_font,
             halign = "center", valign = "center");
}

// One slot between its own two walls, so each wall flexes as a comb's would.
module test_slot(width, mouth) {
    w = width + 2 * slot_wall;
    difference() {
        translate([-w / 2, 0, 0])
            cube([w, pocket + stop, comb_height]);
        slot_void(width, mouth);
    }
}

// Load each slot with four wires: the right width drops a housing in without
// rattling side to side.
module slot_strip(widths, mouths, labels) {
    n = len(widths);
    difference() {
        translate([0, -ledge, 0])
            cube([n * test_pitch, ledge + pocket + stop, comb_base]);
        for (i = [0 : n - 1])
            translate([(i + 0.5) * test_pitch, -ledge / 2, comb_base - label_depth])
                label_text(labels[i]);
    }
    for (i = [0 : n - 1])
        translate([(i + 0.5) * test_pitch, 0, 0])
            test_slot(widths[i], mouths[i]);
}

// Printed as the comb will be, so each socket's roof is a bridge.
module rail_sockets() {
    n = len(rail_clearances);
    cell = 14;
    depth = rail_socket_depth + socket_wall;
    height = rail_height + 2 * max(rail_clearances) + 2 * socket_wall;
    difference() {
        cube([n * cell, depth, height]);
        for (i = [0 : n - 1]) {
            c = rail_clearances[i];
            translate([(i + 0.5) * cell - rail_width / 2 - c, -1, socket_wall - c])
                cube([rail_width + 2 * c, rail_socket_depth + 1, rail_height + 2 * c]);
            translate([(i + 0.5) * cell, depth / 2, height - label_depth])
                label_text(fmt(c, 2));
        }
    }
}

module rail_stub() {
    cube([rail_width, stub_length, rail_height]);
}

// Sockets open downward, as under a comb.
module stack_sockets() {
    n = len(stack_clearances);
    cell = 12;
    height = stack_pin_height + 0.5 + 2;
    difference() {
        cube([n * cell, cell, height]);
        for (i = [0 : n - 1]) {
            translate([(i + 0.5) * cell, cell / 2, -1])
                cylinder(d = stack_pin + 2 * stack_clearances[i], h = stack_pin_height + 1.5);
            translate([(i + 0.5) * cell, cell / 2, height - label_depth])
                label_text(fmt(stack_clearances[i], 1));
        }
    }
}

module stack_pin_tab() {
    chamfer = 0.4;
    translate([-5, -5, 0]) cube([10, 10, 2]);
    translate([0, 0, 2]) {
        cylinder(d = stack_pin, h = stack_pin_height - chamfer);
        translate([0, 0, stack_pin_height - chamfer])
            cylinder(d1 = stack_pin, d2 = stack_pin - 2 * chamfer, h = chamfer);
    }
}

// Digits at the comb's real pitch in two sizes, and a type label, to fill
// with a Sharpie and see which reads.
module label_strip() {
    pitch = slot_width + slot_wall;
    length = colors * pitch + 6;
    difference() {
        cube([length, 24, comb_base]);
        for (i = [0 : colors - 1]) {
            x = 3 + (i + 0.5) * pitch;
            translate([x, 4, comb_base - label_depth]) label_text(str(i), 2.5);
            translate([x, 10, comb_base - label_depth]) label_text(str(i), 3);
        }
        translate([length / 2, 18, comb_base - label_depth]) label_text("M-F", 5);
    }
}

row1 = ledge;
row2 = ledge + pocket + stop + gap;

translate([0, row1, 0])
    slot_strip(slot_widths, slot_widths, [for (w = slot_widths) fmt(w, 1)]);
translate([len(slot_widths) * test_pitch + gap, row1, 0])
    slot_strip([for (m = slot_mouths) slot_width], slot_mouths,
               [for (m = slot_mouths) fmt(m, 1)]);
translate([(len(slot_widths) + len(slot_mouths)) * test_pitch + 2 * gap, 0, 0])
    label_strip();

translate([0, row2, 0]) rail_sockets();
translate([len(rail_clearances) * 14 + gap, row2, 0]) stack_sockets();
translate([len(rail_clearances) * 14 + len(stack_clearances) * 12 + 2 * gap + 5, row2 + 5, 0])
    stack_pin_tab();
for (i = [0 : 1])
    translate([len(rail_clearances) * 14 + len(stack_clearances) * 12 + 3 * gap + 10
               + i * (rail_width + gap), row2, 0])
        rail_stub();

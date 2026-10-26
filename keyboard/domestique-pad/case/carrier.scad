// The KB2040 in a box that snaps under a straight stretch of one extension,
// USB-C toward the base bar. A pod plugs into the JST XH header in its front
// face, so the board's own wiring is soldered once and stays put.
include <params.scad>

// Adafruit KB2040 (5302), from its board file: the PCB, and how far the USB-C
// receptacle hangs past the PCB's end and stands above it.
board = [33.02, 17.78, 1.6];
usb_overhang = 1.21;
usb_width = 8.94;
usb_height = 3.3;
// BOOT (SW3) and RESET (SW2) centers, from the PCB's USB-C end and from its
// D-pin edge, and their footprint along and across the board.
buttons = [[30.226, 3.8735], [30.226, 13.843]];
button = [4.6, 2.8];

// Top-entry B5B-XH-A, from JST's XH datasheet: across the pins, along the
// mating axis, and deep. GND and GP4 through GP7, for up to four keys.
xh_pins = 5;
xh_pitch = 2.5;
xh = [(xh_pins - 1) * xh_pitch + 4.9, 7, 5.75];
// The pin row sits 2.35 from one face and 3.4 from the other, so the slots
// take the header either way up.
xh_row = [2.35, 3.4];
pin_slot = 1.2;
// The header's tails go through this like through a PCB, and the solder on
// them holds the header in when a plug is pulled.
plate = 1.6;

clearance = 0.2;
stop = 1.5;
// Wires run forward here, beside the D-pin edge, not over the board's buttons.
channel = 5;
// Open on the lid side: room for the iron at every tail.
bay = 25;
// Snapped on and held at clip_mouth.
clip_length = 50;
// Along the board on either side of the buttons, for a fingernail.
reach = 3;
lid_thickness = 1.6;
groove = 1;
lip = 1;
front_lip = 1;
gap = 6;

r = tube_bore / 2;
inset = sqrt(r * r - (clip_mouth / 2) * (clip_mouth / 2));
pocket_width = board[1] + 2 * clearance;
inner = channel + pocket_width;
depth = board[2] + usb_height + clearance;
header_depth = xh[2] + 2 * clearance;
slot_height = lid_thickness + 2 * clearance;
// z of the board's floor (toward the tube), the lid's face, and the header's
// floor, deeper than the board's so the lid closes right under the USB-C.
ceiling = -(r + clip_floor);
opening = ceiling - depth;
header_top = opening + header_depth;
bottom = opening - slot_height - lip;
d_edge = -inner / 2 + channel + clearance;

// The receptacle ends flush with the back.
rear_wall = usb_overhang;
board_end = rear_wall + board[0] + 2 * clearance;
plate_y = board_end + stop + bay;
length = plate_y + plate + xh[1];

// Centered on the lid, so it lands over both buttons with either face up.
window_center = rear_wall + buttons[0][0];
window_length = button[0] + 2 * reach;
window_half = max([for (b = buttons) abs(d_edge + b[1]) + button[1] / 2]) + 1;

$fn = 128;

// Modeled as mounted and printed: the tube's center on the origin, running
// along y, the base bar toward -y, the mouth up.
module carrier() {
    difference() {
        union() {
            translate([-clip_width / 2, 0, bottom])
                cube([clip_width, length, -r - bottom]);
            translate([-clip_width / 2, (length - clip_length) / 2, bottom])
                cube([clip_width, clip_length, inset - bottom]);
        }
        translate([0, -1, 0]) rotate([-90, 0, 0]) cylinder(r = r, h = length + 2);
        translate([-inner / 2 + channel, rear_wall, opening])
            cube([pocket_width, plate_y - rear_wall, depth]);
        // Stops at the PCB's top, so the board's edge rests against the step.
        translate([-inner / 2, rear_wall, opening])
            cube([channel, plate_y - rear_wall, depth - board[2]]);
        translate([-inner / 2, board_end, opening])
            cube([inner, bay + stop, depth]);
        translate([d_edge + board[1] / 2 - usb_width / 2 - clearance, -1, bottom - 1])
            cube([usb_width + 2 * clearance, rear_wall + 2, ceiling - board[2] + clearance - bottom + 1]);
        // The lid slides in from the back, and stops short of the front face.
        translate([-inner / 2 - groove, -1, opening - slot_height])
            cube([inner + 2 * groove, length - front_lip + 1, slot_height]);
        translate([-inner / 2, -1, bottom - 1])
            cube([inner, length - front_lip + 1, opening - slot_height - bottom + 1]);
        translate([-xh[0] / 2 - clearance, plate_y + plate, opening])
            cube([xh[0] + 2 * clearance, xh[1] + 1, header_depth]);
        for (i = [0 : xh_pins - 1])
            translate([(i - (xh_pins - 1) / 2) * xh_pitch - pin_slot / 2, plate_y - 1,
                       header_top - xh_row[1] - pin_slot / 2])
                cube([pin_slot, plate + 2, xh_row[1] - xh_row[0] + pin_slot]);
    }
    // As tall as the PCB, so the wires in the channel pass under it.
    translate([-inner / 2, board_end, ceiling - board[2]])
        cube([inner, stop, board[2]]);
}

module lid() {
    width = inner + 2 * groove - 2 * clearance;
    difference() {
        cube([width, length - front_lip - clearance, lid_thickness]);
        translate([width / 2 - window_half, window_center - window_length / 2, -1])
            cube([2 * window_half, window_length, lid_thickness + 2]);
    }
}

translate([0, 0, -bottom]) carrier();
translate([clip_width / 2 + gap, 0, 0]) lid();

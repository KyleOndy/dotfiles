// Every part includes this file. All lengths in mm, clearances per side.

// A 40-pin ribbon is 4 runs of 10 colors, so each slot stacks one color's four.
housing = 2.54;
wires_per_slot = 4;
colors = 10;

// Unmeasured: fit-test.scad prints a range around each of these four.
slot_width = 2.9;
// Below slot_width leaves a lip the top housing snaps under; equal is no lip.
slot_mouth = 2.9;
rail_clearance = 0.10;
stack_clearance = 0.2;

slot_wall = 1.6;
// Clears 24 AWG insulation and stops a housing.
wire_slit = 1.9;
// Shorter than a housing, so male pins stick out past the outer face.
pocket = 12;
stop = 2;
comb_base = 2;
// The 0.3 keeps the top housing below the lip.
stack_height = wires_per_slot * housing + 0.3;
lip_height = 0.8;
comb_height = comb_base + stack_height + lip_height;

rail_width = 8;
rail_height = 5;
rail_socket_depth = 10;

stack_pin = 4;
stack_pin_height = 3;

label_depth = 0.6;
label_font = "Liberation Sans:style=Bold";

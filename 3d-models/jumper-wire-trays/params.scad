// Every part includes this file. All lengths in mm, clearances per side.

// A 40-pin ribbon is 4 runs of 10 colors; a slot stacks 8, room for two kits.
housing = 2.54;
wires_per_slot = 8;
colors = 10;

// Fit test: the narrowest slot held flat, a stub took the 0.15 rail socket,
// the pin the 0.3 stack socket, and 3 mm digits read better than 2.5.
slot_width = 2.7;
rail_clearance = 0.15;
stack_clearance = 0.3;
digit_size = 3;

slot_wall = 1.6;
// Clears 24 AWG insulation and stops a housing.
wire_slit = 1.9;
// Shorter than a housing, so male pins stick out past the outer face.
pocket = 12;
stop = 2;
comb_base = 2;
stack_height = wires_per_slot * housing + 0.3;
comb_height = comb_base + stack_height;

rail_width = 8;
rail_height = 5;
rail_socket_depth = 10;

stack_pin = 4;
stack_pin_height = 3;

label_depth = 0.6;
label_font = "Liberation Sans:style=Bold";

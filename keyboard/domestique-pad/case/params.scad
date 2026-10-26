// Every part includes this file, so a fit measured on a test print changes in
// one place. All lengths in mm.

// Snap clip around an aerobar extension. The bore and the 30 mm block across
// the tube are the Onshape V8 crossbar's, which clips onto the Profile Design
// Airstryke extensions.
tube_bore = 22.3;
clip_width = 30;
// Solid between the top of the bore and the clip's closed face.
clip_floor = 6;
// The tightest of the fit test's 20.6, 21.0 and 21.4, and the best grip in PLA
// on a 10 mm slice. A full-length clip grips harder.
clip_mouth = 20.6;
// Over the tape where the bar pod sits: a paper strip's wrap length / pi.
bar_diameter = 32;

key_pitch = 19.05;

// Every fit-test cutout from 13.9 to 14.1 held a switch, so the middle one
// leaves margin either way.
switch_cutout = 14.0;
// MX switch clips latch under a lip this thick, and need a wider pocket below
// it to spring back out into.
switch_plate = 1.5;
switch_relief = 15.0;

m3_clearance = 3.4;
// Nominal M3 nuts are 2.4 thick and 5.5 across the flats.
m3_nut_depth = 2.6;

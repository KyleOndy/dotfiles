// One plate of fit tests, printed in the case's own filament before any full
// part. The value that fits best on each piece becomes the one in params.scad.
include <params.scad>

// The middle mouth is V8's: its bore center sits 3.75 below the open face.
clip_mouths = [20.6, 21.0, 21.4];
switch_cutouts = [13.9, 14.0, 14.1];
nut_flats = [5.6, 5.8];

slice_length = 10;
strip_thickness = 5;
label_band = 7;
rail_thickness = 4;
slot_length = 30;
// An M3x12 through the rail ends flush with the top of the foot, so its last
// threads are the ones inside the nut.
foot_height = 12 - rail_thickness;
screw_spacing = 15;

label_depth = 0.6;
gap = 6;

$fn = 128;

function label(v) = str(floor(v), ".", round((v - floor(v)) * 10));

module label_text(t) {
    linear_extrude(label_depth + 0.01)
        text(t, size = 3.5, font = "Liberation Sans:style=Bold",
             halign = "center", valign = "center");
}

// A slice of the clip, printed as the bridge will be: tube axis flat, mouth
// up. The mouth is the chord the bore cuts through the open face, so the bore
// center sits sqrt(r^2 - (mouth/2)^2) below that face.
module clip_slice(mouth) {
    r = tube_bore / 2;
    inset = sqrt(r * r - (mouth / 2) * (mouth / 2));
    height = clip_floor + r + inset;
    difference() {
        translate([-clip_width / 2, 0, 0])
            cube([clip_width, slice_length, height]);
        translate([0, -1, clip_floor + r])
            rotate([-90, 0, 0]) cylinder(r = r, h = slice_length + 2);
        translate([0, label_depth, clip_floor / 2])
            rotate([90, 0, 0]) label_text(label(mouth));
    }
}

module switch_strip() {
    depth = key_pitch + label_band;
    difference() {
        cube([len(switch_cutouts) * key_pitch, depth, strip_thickness]);
        for (i = [0 : len(switch_cutouts) - 1]) {
            s = switch_cutouts[i];
            cx = (i + 0.5) * key_pitch;
            cy = label_band + key_pitch / 2;
            translate([cx - s / 2, cy - s / 2, -1])
                cube([s, s, strip_thickness + 2]);
            translate([cx - switch_relief / 2, cy - switch_relief / 2, -1])
                cube([switch_relief, switch_relief, strip_thickness - switch_plate + 1]);
            translate([cx, label_band / 2, strip_thickness - label_depth])
                label_text(label(s));
        }
    }
}

module rail() {
    width = 16;
    difference() {
        translate([-(slot_length + 14) / 2, -width / 2, 0])
            cube([slot_length + 14, width, rail_thickness]);
        hull() for (x = [-slot_length / 2, slot_length / 2])
            translate([x, 0, -1])
                cylinder(d = m3_clearance, h = rail_thickness + 2, $fn = 32);
    }
}

// Each pocket is a different nut fit. The nut drops in from the top and the
// screw, coming up through the rail, pulls it down onto the pocket floor.
module foot() {
    width = 18;
    difference() {
        translate([-(screw_spacing + 15) / 2, -width / 2, 0])
            cube([screw_spacing + 15, width, foot_height]);
        for (i = [0 : 1]) {
            x = (i - 0.5) * screw_spacing;
            translate([x, 0, -1])
                cylinder(d = m3_clearance, h = foot_height + 2, $fn = 32);
            // A 6-sided cylinder's diameter is across the corners.
            translate([x, 0, foot_height - m3_nut_depth])
                cylinder(d = nut_flats[i] / cos(30), h = m3_nut_depth + 1, $fn = 6);
            translate([x, -6, foot_height - label_depth])
                label_text(label(nut_flats[i]));
        }
    }
}

for (i = [0 : len(clip_mouths) - 1])
    translate([clip_width / 2 + i * (clip_width + gap), 0, 0])
        clip_slice(clip_mouths[i]);

translate([0, slice_length + gap, 0]) switch_strip();

translate([(slot_length + 14) / 2, slice_length + key_pitch + label_band + 2 * gap + 8, 0])
    rail();

translate([(slot_length + 14) + gap + (screw_spacing + 15) / 2,
           slice_length + key_pitch + label_band + 2 * gap + 9, 0])
    foot();

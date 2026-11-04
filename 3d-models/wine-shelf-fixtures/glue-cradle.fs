FeatureScript 3095;
import(path : "onshape/std/common.fs", version : "3095.0");

// Glue-up cradle for one brass hanger, see wood's wine-shelf/hangers.md. Modeled in print
// orientation: z = 0 sits on the upturned shelf underside, x = 0 is the back
// leg centers with +x toward the front edge, y = 0 is the hanger centerline.

const ROD_BOUNDS = { (meter) : [0.001, 0.00635, 0.025], (millimeter) : 6.35, (inch) : 0.25 } as LengthBoundSpec;
const SPACING_BOUNDS = { (meter) : [0.01, 0.03175, 0.1], (millimeter) : 31.75, (inch) : 1.25 } as LengthBoundSpec;
const DROP_BOUNDS = { (meter) : [0.02, 0.034925, 0.1], (millimeter) : 34.925, (inch) : 1.375 } as LengthBoundSpec;
const CLEARANCE_BOUNDS = { (meter) : [0, 0.000125, 0.002], (millimeter) : 0.125, (inch) : 0.005 } as LengthBoundSpec;
const CONTACT_BOUNDS = { (meter) : [0.005, 0.02, 0.05], (millimeter) : 20, (inch) : 0.8 } as LengthBoundSpec;
// Max keeps the whole part on a 180 mm A1 mini bed.
const BODY_BOUNDS = { (meter) : [0.05, 0.15, 0.158], (millimeter) : 150, (inch) : 5.9 } as LengthBoundSpec;

// The back bend ends 3/8 in ahead of the leg center (1/4 inside radius plus half the rod).
const BODY_START = 15 * millimeter;
const FORK_TAIL = 1 * millimeter;
const SHOULDER = 3.8 * millimeter;
// Rib and fins sink this far into the body so the union has overlap to work with.
const EMBED = 1 * millimeter;
const RIB_HEIGHT = 4 * millimeter;
const RIB_CHAMFER = 1 * millimeter;
const FIN_THICKNESS = 1.2 * millimeter;
const FIN_LENGTH = 10 * millimeter;
const FIN_CHAMFER = 0.8 * millimeter;
// Width left at the fin root. A 45 degree notch on the rod side takes out the
// rest, so the fin snaps flush with the floor and leaves no nub for the flared
// rods to catch on when the cradle slides out.
const FIN_NECK = 0.6 * millimeter;
// Debossed on the +y side so a print can be matched to fixtures/README.md.
const MARK = "CRADLE v1";
const MARK_HEIGHT = 7 * millimeter;
const MARK_DEPTH = 0.6 * millimeter;

annotation { "Feature Type Name" : "Glue cradle",
        "Feature Type Description" : "Holds one brass hanger at its drop and stem gap while the epoxy cures" }
export const glueCradle = defineFeature(function(context is Context, id is Id, definition is map)
    precondition
    {
        annotation { "Name" : "Rod diameter" }
        isLength(definition.rodDiameter, ROD_BOUNDS);

        annotation { "Name" : "Rod spacing, center to center" }
        isLength(definition.rodSpacing, SPACING_BOUNDS);

        annotation { "Name" : "Drop, shelf face to rod" }
        isLength(definition.drop, DROP_BOUNDS);

        annotation { "Name" : "Clearance per side" }
        isLength(definition.clearance, CLEARANCE_BOUNDS);

        annotation { "Name" : "Shelf contact, from back leg center" }
        isLength(definition.shelfContact, CONTACT_BOUNDS);

        annotation { "Name" : "Body length" }
        isLength(definition.bodyLength, BODY_BOUNDS);

        annotation { "Name" : "Breakaway fins", "Default" : true }
        definition.fins is boolean;
    }
    {
        const halfSlot = definition.rodDiameter / 2 + definition.clearance;
        const yIn = definition.rodSpacing / 2 - halfSlot;
        const yOut = definition.rodSpacing / 2 + halfSlot;
        const halfWidth = yOut + SHOULDER;
        const z0 = definition.drop;
        const x1 = BODY_START + definition.bodyLength;
        const xTip = -halfSlot - FORK_TAIL;
        // 1/8 in below the inside of a 1/4 in radius back bend.
        const forkTop = z0 - 3 / 8 * inch;
        const contact = definition.shelfContact;
        const zero = 0 * meter;

        if (contact - xTip >= forkTop)
        {
            throw regenError("Shelf contact is too far forward: the fork would not reach the back legs", ["shelfContact"]);
        }

        // Nothing touches the shelf behind x = contact. The underside rises at
        // 45 degrees from there, so it prints without supports and stays clear
        // of squeeze-out over the holes.
        const side = newSketchOnPlane(context, id + "sideSketch", {
                    "sketchPlane" : plane(vector(zero, halfWidth, zero), vector(0, -1, 0), vector(1, 0, 0))
                });
        skPolyline(side, "outline", {
                    "points" : [
                            vector(xTip, contact - xTip),
                            vector(contact, zero),
                            vector(x1, zero),
                            vector(x1, z0),
                            vector(BODY_START, z0),
                            vector(BODY_START, forkTop),
                            vector(xTip, forkTop),
                            vector(xTip, contact - xTip)
                        ]
                });
        skSolve(side);
        opExtrude(context, id + "side", {
                    "entities" : qSketchRegion(id + "sideSketch"),
                    "direction" : vector(0, -1, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : 2 * halfWidth
                });
        var bodies = [qCreatedBy(id + "side", EntityType.BODY)];

        const ribSketch = newSketchOnPlane(context, id + "ribSketch", {
                    "sketchPlane" : plane(vector(BODY_START, zero, zero), vector(1, 0, 0), vector(0, 1, 0))
                });
        skPolyline(ribSketch, "outline", {
                    "points" : [
                            vector(-yIn, z0 - EMBED),
                            vector(yIn, z0 - EMBED),
                            vector(yIn, z0 + RIB_HEIGHT - RIB_CHAMFER),
                            vector(yIn - RIB_CHAMFER, z0 + RIB_HEIGHT),
                            vector(-yIn + RIB_CHAMFER, z0 + RIB_HEIGHT),
                            vector(-yIn, z0 + RIB_HEIGHT - RIB_CHAMFER),
                            vector(-yIn, z0 - EMBED)
                        ]
                });
        skSolve(ribSketch);
        opExtrude(context, id + "rib", {
                    "entities" : qSketchRegion(id + "ribSketch"),
                    "direction" : vector(1, 0, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : definition.bodyLength
                });
        bodies = append(bodies, qCreatedBy(id + "rib", EntityType.BODY));

        // Fins hold each run against the rib. After cure they snap outward,
        // away from the rod, so the brass never takes the load.
        if (definition.fins)
        {
            const finStarts = [BODY_START + 5 * millimeter,
                    BODY_START + (definition.bodyLength - FIN_LENGTH) / 2,
                    x1 - 5 * millimeter - FIN_LENGTH];
            for (var i = 0; i < size(finStarts); i += 1)
            {
                const finSketch = newSketchOnPlane(context, id + ("finSketch" ~ i), {
                            "sketchPlane" : plane(vector(finStarts[i], zero, zero), vector(1, 0, 0), vector(0, 1, 0))
                        });
                for (var s in [-1, 1])
                {
                    skPolyline(finSketch, s < 0 ? "right" : "left", {
                                "points" : [
                                        vector(s * (yOut + FIN_THICKNESS - FIN_NECK), z0 - EMBED),
                                        vector(s * (yOut + FIN_THICKNESS), z0 - EMBED),
                                        vector(s * (yOut + FIN_THICKNESS), z0 + RIB_HEIGHT),
                                        vector(s * (yOut + FIN_CHAMFER), z0 + RIB_HEIGHT),
                                        vector(s * yOut, z0 + RIB_HEIGHT - FIN_CHAMFER),
                                        vector(s * yOut, z0 + FIN_THICKNESS - FIN_NECK),
                                        vector(s * (yOut + FIN_THICKNESS - FIN_NECK), z0),
                                        vector(s * (yOut + FIN_THICKNESS - FIN_NECK), z0 - EMBED)
                                    ]
                            });
                }
                skSolve(finSketch);
                opExtrude(context, id + ("fin" ~ i), {
                            "entities" : qSketchRegion(id + ("finSketch" ~ i)),
                            "direction" : vector(1, 0, 0),
                            "endBound" : BoundingType.BLIND,
                            "endDepth" : FIN_LENGTH
                        });
                bodies = append(bodies, qCreatedBy(id + ("fin" ~ i), EntityType.BODY));
            }
        }

        const cradle = qUnion(bodies);
        opBoolean(context, id + "union", {
                    "tools" : cradle,
                    "operationType" : BooleanOperationType.UNION
                });

        // Slots are open toward the back so the cradle slides forward off the
        // legs. Their closed ends stop on the front of the back legs, which is
        // what holds the shelf contact clear of the holes.
        const slotSketch = newSketchOnPlane(context, id + "slotSketch", {
                    "sketchPlane" : plane(vector(zero, zero, -1 * millimeter), vector(0, 0, 1), vector(1, 0, 0))
                });
        skRectangle(slotSketch, "left", {
                    "firstCorner" : vector(xTip - 1 * millimeter, yIn),
                    "secondCorner" : vector(halfSlot, yOut)
                });
        skRectangle(slotSketch, "right", {
                    "firstCorner" : vector(xTip - 1 * millimeter, -yIn),
                    "secondCorner" : vector(halfSlot, -yOut)
                });
        skSolve(slotSketch);
        opExtrude(context, id + "slots", {
                    "entities" : qSketchRegion(id + "slotSketch"),
                    "direction" : vector(0, 0, 1),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : forkTop + 2 * millimeter
                });

        // Sketch x runs along -x so the text reads upright from the +y side.
        const markSketch = newSketchOnPlane(context, id + "markSketch", {
                    "sketchPlane" : plane(vector(zero, halfWidth, zero), vector(0, 1, 0), vector(-1, 0, 0))
                });
        const markBottom = (z0 - MARK_HEIGHT) / 2;
        skText(markSketch, "mark", {
                    "text" : MARK,
                    "fontName" : "OpenSans-Bold.ttf",
                    "firstCorner" : vector(10 * millimeter - x1, markBottom),
                    "secondCorner" : vector(-contact, markBottom + MARK_HEIGHT)
                });
        skSolve(markSketch);
        opExtrude(context, id + "mark", {
                    "entities" : qSketchRegion(id + "markSketch", true),
                    "direction" : vector(0, -1, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : MARK_DEPTH
                });

        opBoolean(context, id + "cut", {
                    "tools" : qUnion([qCreatedBy(id + "slots", EntityType.BODY), qCreatedBy(id + "mark", EntityType.BODY)]),
                    "targets" : cradle,
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        opDeleteBodies(context, id + "cleanup", {
                    "entities" : qSketchFilter(qCreatedBy(id, EntityType.BODY), SketchObject.YES)
                });
    });

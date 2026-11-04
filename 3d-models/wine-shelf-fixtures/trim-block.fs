FeatureScript 3095;
import(path : "onshape/std/common.fs", version : "3095.0");

// Trim block for one bent hanger leg, see wood's wine-shelf/hangers.md. Modeled in print
// orientation: z = 0 is the bench the bent side lies on, x = 0 is the leg
// center with +x along the rod leaving the leg, y = 0 is the rod centerline.
// The top face is the cut line; saw flush across it.

const ROD_BOUNDS = { (meter) : [0.001, 0.00635, 0.025], (millimeter) : 6.35, (inch) : 0.25 } as LengthBoundSpec;
// Bench to leg end: 1/2 in the hole with the rod top 1 3/8 under the shelf.
const TRIM_BOUNDS = { (meter) : [0.0254, 0.053975, 0.1016], (millimeter) : 53.975, (inch) : 2.125 } as LengthBoundSpec;
const RADIUS_BOUNDS = { (meter) : [0.001, 0.00635, 0.025], (millimeter) : 6.35, (inch) : 0.25 } as LengthBoundSpec;
const CLEARANCE_BOUNDS = { (meter) : [0, 0.0003, 0.002], (millimeter) : 0.3, (inch) : 0.012 } as LengthBoundSpec;
// Max must stay short of where the flare arc starts, measured along the run from
// the front leg center (1.70 in on the layout in wood's wine-shelf/drawings/hangers.py).
const REACH_BOUNDS = { (meter) : [0.0127, 0.034925, 0.0356], (millimeter) : 34.925, (inch) : 1.375 } as LengthBoundSpec;
const CROSS_DRILL_BOUNDS = { (meter) : [0.001, 0.00238125, 0.004], (millimeter) : 2.38125, (inch) : 0.09375 } as LengthBoundSpec;
// Cut line to cross hole center. Max keeps the hole inside the 1/2 that goes in the shelf.
const CROSS_DEPTH_BOUNDS = { (meter) : [0.003, 0.0047625, 0.01], (millimeter) : 4.7625, (inch) : 0.1875 } as LengthBoundSpec;

const HALF_WIDTH = 0.5 * inch;
// Wall behind the leg, on the side away from the rod.
const BACK = 0.5 * inch;
const FOOT_LENGTH = 1 * inch;
const FOOT_THICKNESS = 0.25 * inch;
// Debossed on the +y side so a print can be matched to fixtures/README.md.
const MARK = "TRIM v3";
const MARK_HEIGHT = 7 * millimeter;
const MARK_DEPTH = 0.6 * millimeter;
// Per side, on the drill. Small printed holes come out undersize, so the bit
// gets run through once to size the guide.
const CROSS_CLEARANCE = 0.1 * millimeter;

annotation { "Feature Type Name" : "Trim block",
        "Feature Type Description" : "Sets the cut line on a bent hanger leg; saw flush across the top" }
export const trimBlock = defineFeature(function(context is Context, id is Id, definition is map)
    precondition
    {
        annotation { "Name" : "Rod diameter" }
        isLength(definition.rodDiameter, ROD_BOUNDS);

        annotation { "Name" : "Leg height, bench to cut" }
        isLength(definition.trimHeight, TRIM_BOUNDS);

        annotation { "Name" : "Bend inside radius" }
        isLength(definition.bendRadius, RADIUS_BOUNDS);

        annotation { "Name" : "Clearance per side" }
        isLength(definition.clearance, CLEARANCE_BOUNDS);

        annotation { "Name" : "Reach along the rod" }
        isLength(definition.reach, REACH_BOUNDS);

        annotation { "Name" : "Clamp foot", "Default" : true }
        definition.foot is boolean;

        annotation { "Name" : "Cross hole guide", "Default" : true }
        definition.crossHole is boolean;

        if (definition.crossHole)
        {
            annotation { "Name" : "Cross hole drill" }
            isLength(definition.crossDrill, CROSS_DRILL_BOUNDS);

            annotation { "Name" : "Cross hole below the cut" }
            isLength(definition.crossDepth, CROSS_DEPTH_BOUNDS);
        }
    }
    {
        const d = definition.rodDiameter;
        const c = definition.clearance;
        const h = definition.trimHeight;
        const halfSlot = d / 2 + c;
        const zero = 0 * meter;
        const x0 = definition.foot ? -BACK - FOOT_LENGTH : -BACK;

        var outline = [vector(x0, zero), vector(definition.reach, zero), vector(definition.reach, h), vector(-BACK, h)];
        if (definition.foot)
        {
            outline = append(outline, vector(-BACK, FOOT_THICKNESS));
            outline = append(outline, vector(x0, FOOT_THICKNESS));
        }
        outline = append(outline, outline[0]);
        const side = newSketchOnPlane(context, id + "sideSketch", {
                    "sketchPlane" : plane(vector(zero, HALF_WIDTH, zero), vector(0, -1, 0), vector(1, 0, 0))
                });
        skPolyline(side, "outline", { "points" : outline });
        skSolve(side);
        opExtrude(context, id + "body", {
                    "entities" : qSketchRegion(id + "sideSketch"),
                    "direction" : vector(0, -1, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : 2 * HALF_WIDTH
                });

        const boreSketch = newSketchOnPlane(context, id + "boreSketch", {
                    "sketchPlane" : plane(vector(zero, zero, -1 * millimeter), vector(0, 0, 1), vector(1, 0, 0))
                });
        skCircle(boreSketch, "bore", { "center" : vector(zero, zero), "radius" : halfSlot });
        skSolve(boreSketch);
        opExtrude(context, id + "bore", {
                    "entities" : qSketchRegion(id + "boreSketch"),
                    "direction" : vector(0, 0, 1),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : h + 2 * millimeter
                });

        // The channel ceiling traps the rod against the bench. Its 45 degree
        // chamfer clears the inside of the leg bend up to 1.5x the nominal radius.
        const zTrap = d + c;
        const k = 1.5 * d + 1.5 * definition.bendRadius + c;
        const xOut = definition.reach + 1 * millimeter;
        const zLow = -1 * millimeter;
        const channelSketch = newSketchOnPlane(context, id + "channelSketch", {
                    "sketchPlane" : plane(vector(zero, halfSlot, zero), vector(0, -1, 0), vector(1, 0, 0))
                });
        skPolyline(channelSketch, "outline", {
                    "points" : [
                            vector(-halfSlot, zLow),
                            vector(xOut, zLow),
                            vector(xOut, zTrap),
                            vector(k - zTrap, zTrap),
                            vector(-halfSlot, k + halfSlot),
                            vector(-halfSlot, zLow)
                        ]
                });
        skSolve(channelSketch);
        opExtrude(context, id + "channel", {
                    "entities" : qSketchRegion(id + "channelSketch"),
                    "direction" : vector(0, -1, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : 2 * halfSlot
                });

        // Sketch x runs along -x so the text reads upright from the +y side.
        const markSketch = newSketchOnPlane(context, id + "markSketch", {
                    "sketchPlane" : plane(vector(zero, HALF_WIDTH, zero), vector(0, 1, 0), vector(-1, 0, 0))
                });
        const markBottom = (h - MARK_HEIGHT) / 2;
        skText(markSketch, "mark", {
                    "text" : MARK,
                    "fontName" : "OpenSans-Bold.ttf",
                    "firstCorner" : vector(3 * millimeter - definition.reach, markBottom),
                    "secondCorner" : vector(BACK - 2 * millimeter, markBottom + MARK_HEIGHT)
                });
        skSolve(markSketch);
        opExtrude(context, id + "mark", {
                    "entities" : qSketchRegion(id + "markSketch", true),
                    "direction" : vector(0, -1, 0),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : MARK_DEPTH
                });

        // Drill guide for a hole straight across the leg, through both side
        // faces. Epoxy fills it and keys the leg into the shelf hole. The point on top lets the horizontal hole print without
        // support; the bit rides in the round lower half.
        if (definition.crossHole)
        {
            const r = definition.crossDrill / 2 + CROSS_CLEARANCE;
            const zc = h - definition.crossDepth;
            const t = r / sqrt(2);
            const crossSketch = newSketchOnPlane(context, id + "crossSketch", {
                        "sketchPlane" : plane(vector(zero, HALF_WIDTH + 1 * millimeter, zero), vector(0, -1, 0), vector(1, 0, 0))
                    });
            skArc(crossSketch, "round", { "start" : vector(-t, zc + t), "mid" : vector(zero, zc - r), "end" : vector(t, zc + t) });
            skLineSegment(crossSketch, "right", { "start" : vector(t, zc + t), "end" : vector(zero, zc + r * sqrt(2)) });
            skLineSegment(crossSketch, "left", { "start" : vector(zero, zc + r * sqrt(2)), "end" : vector(-t, zc + t) });
            skSolve(crossSketch);
            opExtrude(context, id + "cross", {
                        "entities" : qSketchRegion(id + "crossSketch"),
                        "direction" : vector(0, -1, 0),
                        "endBound" : BoundingType.BLIND,
                        "endDepth" : 2 * HALF_WIDTH + 2 * millimeter
                    });
        }

        opBoolean(context, id + "cut", {
                    "tools" : qUnion([qCreatedBy(id + "bore", EntityType.BODY), qCreatedBy(id + "channel", EntityType.BODY),
                            qCreatedBy(id + "mark", EntityType.BODY), qCreatedBy(id + "cross", EntityType.BODY)]),
                    "targets" : qCreatedBy(id + "body", EntityType.BODY),
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        opDeleteBodies(context, id + "cleanup", {
                    "entities" : qSketchFilter(qCreatedBy(id, EntityType.BODY), SketchObject.YES)
                });
    });

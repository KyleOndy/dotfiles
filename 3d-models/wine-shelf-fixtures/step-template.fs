FeatureScript 3095;
import(path : "onshape/std/common.fs", version : "3095.0");

// Step template for the leg holes, see wood's wine-shelf/hangers.md. It lies on the shelf's
// underside with its fence on a long face, which puts the guide line 3/4 off
// that face. A 1/8 drill bit is both the punch and the index pin: twist it in
// a guide to dimple the wood, then drop it through the trailing end guide into
// the last dimple to move one channel along.
//
// Both rows step off from the same end of the shelf, so pitch error moves a
// hanger's front and back legs together instead of skewing one against the
// other. With the fence on the front face, A trails. Turned around on the
// back face, B trails.
//
// Modeled in print orientation, top face on the bed. Geometry goes through
// at(), which takes use coordinates: x along the shelf from A toward B, y into
// the shelf from the fence's inside face, z up from the shelf surface.

// Leg hole layout from wood's wine-shelf/drawings/hangers.py. Guides sit these distances from
// A: the back pair, the front pair, and the channel pitch.
const BACK_PAIR = 1.25 * inch;
const FRONT_PAIR = 3.875 * inch;
const PITCH = 4.5 * inch;
const ROW = 0.75 * inch;
// Each row's first hole, from the end of the shelf.
const FRONT_FIRST = 2.5625 * inch;
const BACK_FIRST = 3.875 * inch;

const BIT = 0.125 * inch;
// Per side. Small printed holes come out undersize, so the bit gets run
// through once to size each guide.
const CLEARANCE = 0.1 * millimeter;
// 45 degree chamfer on the top of each guide, which also takes off the
// elephant's foot.
const LEAD_IN = 0.5 * millimeter;

const PLATE = 6 * millimeter;
const MARGIN = 10 * millimeter;
const PLATE_Y = 50 * millimeter;
const START_Y = 35 * millimeter;
const FENCE = 4 * millimeter;
// Below the shelf surface.
const FENCE_DROP = 24 * millimeter;

const LABEL_HEIGHT = 3.5 * millimeter;
// Hole center to label center.
const LABEL_OFFSET = 7 * millimeter;
const DEBOSS = 0.6 * millimeter;
// Debossed on the +y side so a print can be matched to fixtures/README.md.
const MARK = "STEP v2";
const MARK_HEIGHT = 7 * millimeter;

annotation { "Feature Type Name" : "Step template",
        "Feature Type Description" : "Dimples the leg hole centers one channel at a time, indexed off the last dimple" }
export const stepTemplate = defineFeature(function(context is Context, id is Id, definition is map)
    precondition
    {
    }
    {
        const zero = 0 * inch;
        const frontStart = PITCH - FRONT_FIRST - BIT / 2;
        const backStart = BACK_FIRST + BACK_PAIR + BIT / 2;
        const x0 = -MARGIN;
        const x1 = backStart + MARGIN;
        cuboid(context, id + "body" + "plate", at(x0, zero, zero), at(x1, PLATE_Y, PLATE));
        cuboid(context, id + "body" + "fence", at(x0, -FENCE, -FENCE_DROP), at(x1, zero, PLATE));
        opBoolean(context, id + "join", {
                    "tools" : qCreatedBy(id + "body", EntityType.BODY),
                    "operationType" : BooleanOperationType.UNION
                });

        // A bit through a START hole hangs past the start end with its side
        // on the end grain. FRONT START puts B on the front row's first hole,
        // and BACK START puts BACK and A on the back row's first two.
        const endY = ROW + LABEL_OFFSET;
        const rowY = ROW - LABEL_OFFSET;
        const startY = START_Y + LABEL_OFFSET;
        const guides = [
                { "x" : zero, "y" : ROW, "label" : "A", "labelX" : zero, "labelY" : endY },
                { "x" : BACK_PAIR, "y" : ROW, "label" : "BACK", "labelX" : BACK_PAIR, "labelY" : rowY },
                { "x" : FRONT_PAIR, "y" : ROW, "label" : "FRONT", "labelX" : FRONT_PAIR, "labelY" : rowY },
                { "x" : PITCH, "y" : ROW, "label" : "B", "labelX" : PITCH, "labelY" : endY },
                { "x" : frontStart, "y" : START_Y, "label" : "FRONT START", "labelX" : frontStart, "labelY" : startY },
                // Pulled in from its hole so the label stays on the plate.
                { "x" : backStart, "y" : START_Y, "label" : "BACK START", "labelX" : backStart - MARGIN, "labelY" : startY }
            ];
        const r = BIT / 2 + CLEARANCE;
        for (var i = 0; i < size(guides); i += 1)
        {
            const g = guides[i];
            fCylinder(context, id + "cut" + ("bore" ~ i), {
                        "bottomCenter" : at(g.x, g.y, -1 * millimeter),
                        "topCenter" : at(g.x, g.y, PLATE + 1 * millimeter),
                        "radius" : r
                    });
            fCone(context, id + "cut" + ("leadIn" ~ i), {
                        "bottomCenter" : at(g.x, g.y, PLATE - LEAD_IN),
                        "bottomRadius" : r,
                        "topCenter" : at(g.x, g.y, PLATE + LEAD_IN),
                        "topRadius" : r + 2 * LEAD_IN
                    });
            deboss(context, id + "cut" + ("label" ~ i), g.label, at(g.labelX, g.labelY, PLATE), vector(0, 0, -1), LABEL_HEIGHT);
        }
        deboss(context, id + "cut" + "mark", MARK, at((x0 + x1) / 2, -FENCE, (PLATE - FENCE_DROP) / 2), vector(0, 1, 0), MARK_HEIGHT);

        opBoolean(context, id + "subtract", {
                    "tools" : qSketchFilter(qCreatedBy(id + "cut", EntityType.BODY), SketchObject.NO),
                    "targets" : qCreatedBy(id + "body", EntityType.BODY),
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        opDeleteBodies(context, id + "cleanup", {
                    "entities" : qSketchFilter(qCreatedBy(id, EntityType.BODY), SketchObject.YES)
                });
    });

// Use coordinates to print coordinates: flipped over the x axis so the top
// face lands on the bed.
function at(x is ValueWithUnits, y is ValueWithUnits, z is ValueWithUnits) returns Vector
{
    return vector(x, -y, PLATE - z);
}

function cuboid(context is Context, id is Id, a is Vector, b is Vector)
{
    fCuboid(context, id, {
                "corner1" : vector(min(a[0], b[0]), min(a[1], b[1]), min(a[2], b[2])),
                "corner2" : vector(max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]))
            });
}

// Text centered on center, cut DEBOSS deep. It reads upright to someone facing
// the face along -normal, with x running along print +x.
function deboss(context is Context, id is Id, text is string, center is Vector, normal is Vector, height is ValueWithUnits)
{
    const sketch = newSketchOnPlane(context, id + "sketch", {
                "sketchPlane" : plane(center, normal, vector(1, 0, 0))
            });
    skText(sketch, "text", {
                "text" : text,
                "fontName" : "OpenSans-Bold.ttf",
                "firstCorner" : vector(0, 0) * meter,
                "secondCorner" : vector(0.62 * size(splitIntoCharacters(text)) * height, height)
            });
    skSolve(sketch);
    opExtrude(context, id + "body", {
                "entities" : qSketchRegion(id + "sketch", true),
                "direction" : -normal,
                "endBound" : BoundingType.BLIND,
                "endDepth" : DEBOSS
            });
    const bounds = evBox3d(context, { "topology" : qCreatedBy(id + "body", EntityType.BODY), "tight" : true });
    var shift = center - (bounds.minCorner + bounds.maxCorner) / 2;
    shift = shift - dot(shift, normal) * normal;
    opTransform(context, id + "center", {
                "bodies" : qCreatedBy(id + "body", EntityType.BODY),
                "transform" : transform(shift)
            });
}

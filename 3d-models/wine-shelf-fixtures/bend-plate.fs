FeatureScript 3095;
import(path : "onshape/std/common.fs", version : "3095.0");

// Bend plate for the hanger sides, see wood's wine-shelf/hangers.md. It sits on the tops of
// the Huth bender's two base pins, the center pin the arm pivots on and the
// backing pin, so its stops locate off the same pins that form the bend.
// Every bend holds the front of the rod and swings the rest, and every stop
// catches the front leg:
//
// - Back leg 90: a 3/4 square bar screws up under the plate, and the stop
//   block slides along it. The front leg slides in flat under the bar, onto
//   the block's floor and under its lip, which keeps it flat so the back leg
//   bends in the same plane.
// - Flare: the front leg stands up through the R notch (arm swings
//   clockwise, right-hand sides) or the L notch (counterclockwise, left-hand
//   sides), a closed round hole that holds it upright.
//
// The rod pulls toward the pins as it bends, so the leg bears on the side of
// each slot or notch nearest the pins, and that face sets the distance.
//
// Fins hang from the plate where each leg lies when its bend is exactly 90 or
// 45, to bend to by eye in place of a stop on the handle.
//
// Geometry goes through at() and blockAt(), which take use coordinates:
// origin on the center pin's axis at the top of the arm, x along the rod
// toward the swing pin when the arm swings clockwise, y toward the backing
// pin, z up. The plate prints top face down, turned to fill the bed, and the
// block on its side.

// Bender, measured 2026-10-20. Pin centers by gauge block.
const PIN = 12.70 * millimeter;
const CENTER_TO_BACKING = 29.15 * millimeter;
const CENTER_TO_SWING = 23.15 * millimeter;
const ARM_WIDTH = 25.57 * millimeter;
// All three pin tops, above the arm.
const PIN_TOP = 31.8 * millimeter;
const ROD = 6.34 * millimeter;

// From wood's wine-shelf/drawings/hangers.py: front leg center to where the rod meets the
// center pin, for the flare and the back leg.
const FLARE_HOLD = 1.7008 * inch;
const BACK_HOLD = 11.2775 * inch;

// Per side. On the pin coupons 0.15 takes force to seat and 0.2 drops on
// snug, so printed pockets come out under size. At 0.3 the plate rocks on
// the pins, which swings the fins off their angles. 0.3 slides on a 1/4 rod
// in TRIM v2; the notches and the stop's lip hold the leg to 0.2.
const PIN_CLEARANCE = 0.2 * millimeter;
const NOTCH_CLEARANCE = 0.2 * millimeter;
// Between the plate and the swing pin, anywhere the arm can take it.
const SWING_CLEARANCE = 1.5 * millimeter;

const CAP = 4 * millimeter;
const TOP = PIN_TOP + CAP;
const WEB = 6 * millimeter;
const POCKET = 18 * millimeter;
const WALL = 3 * millimeter;
// Along the line between the pins, for the gauge block spacing to be off.
const SLOT_PLAY = 1 * millimeter;
// Wall beside each notch, and how far the boss runs outboard of the leg's
// center.
const NOTCH_SIDE = 5 * millimeter;
const NOTCH_RUN = 16 * millimeter;
const LEAD_IN = 1.5 * millimeter;
// Over the front leg's bend the notch bosses stop this far above its top.
const BEND_CLEARANCE = 3.3 * millimeter;
// The notch walls and the fins stop this far above a rod lying on the arm.
const ROD_CLEARANCE = 1.5 * millimeter;

// Angle fins. Each hangs beside the path a leg takes when its bend is exactly
// 90 (both 90s, clockwise) or 45 (the flare, R or L), and the leg shows
// through a window in the plate beside it. The bend is on angle when the gap
// between leg and fin is even along the fin.
const FIN = 2.4 * millimeter;
// Plan gap between a leg on its exact angle and its fin.
const FIN_GAP = 2 * millimeter;
// Along each leg from where it leaves the center pin. The fins start clear of
// the swing pin, and out to WINDOW_START the plate covers every leg and ties
// the fins together.
const FIN_START = 32 * millimeter;
const WINDOW_START = 40 * millimeter;
// The 90's window runs this far past the leg, on the side away from its fin.
const WINDOW_VIEW = 8 * millimeter;
// Web outboard of the R fin.
const FLANGE = 10 * millimeter;

// Bambu A1 mini, less 1 mm a side. The plate prints turned BED_ANGLE about z
// with BED_CENTER on the middle of the bed, which fits all of it and runs each
// fin about 123 mm out from the center pin before the bed edge trims it.
// wood's wine-shelf/drawings/bending.py checks the fit.
const BED = 178 * millimeter;
const BED_ANGLE = 24.5 * degree;
const BED_CENTER = vector(-15.6, -36.4) * millimeter;

// Hardwood, ripped to slide snug in the channel.
const BAR = 0.75 * inch;
const BAR_Y = -22 * millimeter;
const BAR_CLEARANCE = 0.3 * millimeter;
const CHANNEL_WALL = 4 * millimeter;
const CHANNEL_DEPTH = 12 * millimeter;
const CHANNEL_START = -41 * millimeter;
// Stop face to the outboard end of the channel, for the first setting.
const SET = 6.75 * inch;
const SCREW = 4.5 * millimeter;
const SCREW_HEAD = 8.9 * millimeter;

const BLOCK_WALL = 4 * millimeter;
const BLOCK_LENGTH = 30 * millimeter;
const STOP_WALL = 6 * millimeter;
const FLOOR = 3 * millimeter;
// Floor outboard of the stop face, open on top: the bar runs on past the
// stop, and the leg slides in flat under it.
const FLOOR_RUN = 14 * millimeter;

// Pin coupons: the plate's two pin pockets alone, one coupon per clearance a
// side, to find the snuggest that still drops on the pins before printing
// the plate. Each is debossed with its clearance.
const COUPON_CLEARANCES = [0.05 * millimeter, 0.1 * millimeter, 0.15 * millimeter, 0.2 * millimeter];
const COUPON_PITCH = 25 * millimeter;

const DEBOSS = 0.6 * millimeter;
// Debossed on the top face so a print can be matched to fixtures/README.md.
const MARK = "BEND v4";
const MARK_HEIGHT = 5 * millimeter;
const LABEL_HEIGHT = 3.5 * millimeter;

annotation { "Feature Type Name" : "Bend plate",
        "Feature Type Description" : "Stops and angle fins for the back-leg 90 and the flare, located off the bender's base pins" }
export const bendPlate = defineFeature(function(context is Context, id is Id, definition is map)
    precondition
    {
    }
    {
        const zero = 0 * millimeter;
        const pinR = PIN / 2;
        const rodR = ROD / 2;
        const off = pinR + rodR;
        const pocketR = pinR + PIN_CLEARANCE;
        const bossR = pocketR + WALL;

        const backing = backingCenter();
        const toBacking = backing / CENTER_TO_BACKING;
        const across = vector(-toBacking[1], toBacking[0]);

        // The arm can swing every way but into the backing pin, so the swing
        // pin sweeps a ring round the center pin except the wedge toward the
        // backing pin. A rod laid along the other side of the pins is this
        // layout mirrored across the line between them.
        const reach = asin((ARM_WIDTH / 2 + pinR) / CENTER_TO_BACKING);
        const backAngle = atan2(backing[1], backing[0]) - reach;
        const capA = CENTER_TO_SWING * vector(cos(backAngle), sin(backAngle));
        const capB = reflect(capA, toBacking);
        const keepR = pinR + SWING_CLEARANCE;

        const notchR = rodR + NOTCH_CLEARANCE;
        const notchEnd = vector(-(FLARE_HOLD + NOTCH_CLEARANCE), off);
        const bossIn = notchEnd[0] + notchR + WALL + 1 * millimeter;
        const bossOut = -FLARE_HOLD - NOTCH_RUN;
        const bossLo = off - notchR - NOTCH_SIDE;
        const bossHi = off + notchR + NOTCH_SIDE;
        const bossRight = [vector(bossOut, bossLo), vector(bossIn, bossLo), vector(bossIn, bossHi), vector(bossOut, bossHi)];
        const bossLeft = reflectAll(bossRight, toBacking);
        const arcTop = ROD + pinR;
        const notchBottom = arcTop + BEND_CLEARANCE;
        const wallBottom = ROD + ROD_CLEARANCE;
        const pocketBottom = PIN_TOP - POCKET;

        const stopFace = -(BACK_HOLD - rodR);
        const channelEnd = stopFace + SET;
        const barHalf = BAR / 2 + BAR_CLEARANCE;
        const channelLo = BAR_Y - barHalf - CHANNEL_WALL;
        const channelHi = BAR_Y + barHalf + CHANNEL_WALL;
        const webBottom = TOP - WEB;

        // Each leg leaves the center pin at "start" and runs along "dir", and
        // its fin is to its "side".
        const c45 = vector(cos(45 * degree), sin(45 * degree));
        var legs = [
            { "label" : "90", "start" : vector(off, zero), "dir" : vector(0, -1), "side" : vector(-1, 0) },
            { "label" : "R 45", "start" : c45 * off, "dir" : vector(c45[0], -c45[1]), "side" : c45 }
        ];
        legs = append(legs, { "label" : "L 45", "start" : reflect(legs[1].start, toBacking),
                    "dir" : reflect(legs[1].dir, toBacking), "side" : reflect(legs[1].side, toBacking) });
        const finFace = rodR + FIN_GAP;
        const finBack = finFace + FIN;
        // Past the bed edge, and short of where the R and L fin faces meet.
        const finEnd = BED;

        const web = [
                vector(channelEnd, channelLo),
                vector(CHANNEL_START, channelLo),
                vector(bossIn, -15 * millimeter),
                bossRight[1],
                backing + vector(-8, -5) * millimeter,
                backing + vector(2, 7) * millimeter,
                bossLeft[1], bossLeft[0], bossLeft[3], bossLeft[2],
                bossRight[3], bossRight[0],
                vector(channelEnd, channelHi)
            ];
        extrudePlan(context, id + "plate" + "web", web, webBottom, TOP);
        extrudePlan(context, id + "plate" + "bridge", [
                    across * 6 * millimeter, backing + across * 6 * millimeter,
                    backing - across * 6 * millimeter, -across * 6 * millimeter
                ], pocketBottom, TOP);
        pillar(context, id + "plate" + "centerBoss", vector(zero, zero), bossR, pocketBottom, TOP);
        stadium(context, id + "plate" + "backingBoss", backing, toBacking, bossR, pocketBottom, TOP);
        extrudePlan(context, id + "plate" + "notchBossR", bossRight, wallBottom, TOP);
        extrudePlan(context, id + "plate" + "notchBossL", bossLeft, wallBottom, TOP);
        // Under the fins: from the channel round the swing pin's reach to the
        // web outboard of the R fin. The inner corners fall where the swing pin
        // goes and get cut away.
        const inner = 24 * millimeter;
        extrudePlan(context, id + "plate" + "quadrant", [
                    vector(channelEnd, channelLo),
                    vector(CHANNEL_START, channelLo),
                    vector(bossIn, -15 * millimeter),
                    inner * vector(cos(-120 * degree), sin(-120 * degree)),
                    inner * vector(cos(-60 * degree), sin(-60 * degree)),
                    inner * vector(cos(-15 * degree), sin(-15 * degree)),
                    legAt(legs[1], FIN_START, finBack + FLANGE),
                    legAt(legs[1], finEnd, finBack + FLANGE),
                    vector(finEnd, -2 * finEnd),
                    vector(channelEnd, -2 * finEnd)
                ], webBottom, TOP);
        const channelBottom = webBottom - CHANNEL_DEPTH;
        extrudePlan(context, id + "plate" + "channelLo", [
                    vector(channelEnd, channelLo), vector(CHANNEL_START, channelLo),
                    vector(CHANNEL_START, channelLo + CHANNEL_WALL), vector(channelEnd, channelLo + CHANNEL_WALL)
                ], channelBottom, webBottom);
        extrudePlan(context, id + "plate" + "channelHi", [
                    vector(channelEnd, channelHi - CHANNEL_WALL), vector(CHANNEL_START, channelHi - CHANNEL_WALL),
                    vector(CHANNEL_START, channelHi), vector(channelEnd, channelHi)
                ], channelBottom, webBottom);
        extrudePlan(context, id + "plate" + "channelEnd", [
                    vector(CHANNEL_START - CHANNEL_WALL, channelLo), vector(CHANNEL_START, channelLo),
                    vector(CHANNEL_START, channelHi), vector(CHANNEL_START - CHANNEL_WALL, channelHi)
                ], channelBottom, webBottom);
        opBoolean(context, id + "plateJoin", {
                    "tools" : qSketchFilter(qCreatedBy(id + "plate", EntityType.BODY), SketchObject.NO),
                    "operationType" : BooleanOperationType.UNION
                });

        const below = wallBottom - 1 * millimeter;
        const above = TOP + 1 * millimeter;
        pillar(context, id + "plateCut" + "centerPocket", vector(zero, zero), pocketR, below, PIN_TOP);
        stadium(context, id + "plateCut" + "backingPocket", backing, toBacking, pocketR, below, PIN_TOP);

        // Notch: a round hole the leg stands up through. Its walls come down
        // to just over the run, except over the leg's bend, where a relief the
        // rod's width keeps the boss above it. A chamfer at the bottom leads
        // the leg in as the plate comes down over it.
        const relief = [
                vector(notchEnd[0], off - notchR), vector(bossIn + 1 * millimeter, off - notchR),
                vector(bossIn + 1 * millimeter, off + notchR), vector(notchEnd[0], off + notchR)
            ];
        const leadIn = wallBottom + LEAD_IN;
        const holes = [["R", notchEnd, relief], ["L", reflect(notchEnd, toBacking), reflectAll(relief, toBacking)]];
        for (var h in holes)
        {
            pillar(context, id + "plateCut" + ("notch" ~ h[0]), h[1], notchR, below, above);
            extrudePlan(context, id + "plateCut" + ("relief" ~ h[0]), h[2], below, notchBottom);
            fCone(context, id + "plateCut" + ("lead" ~ h[0]), {
                        "bottomCenter" : at(h[1], below), "bottomRadius" : notchR + leadIn - below,
                        "topCenter" : at(h[1], leadIn), "topRadius" : notchR
                    });
        }

        // Windows down onto each leg past WINDOW_START. The R and L legs run
        // close enough to share one.
        const view = -(rodR + WINDOW_VIEW);
        extrudePlan(context, id + "plateCut" + "window90", [
                    legAt(legs[0], WINDOW_START, finFace), legAt(legs[0], finEnd, finFace),
                    legAt(legs[0], finEnd, view), legAt(legs[0], WINDOW_START, view)
                ], below, above);
        extrudePlan(context, id + "plateCut" + "window45", [
                    legAt(legs[2], WINDOW_START, finFace), legAt(legs[2], finEnd, finFace),
                    legAt(legs[1], finEnd, finFace), legAt(legs[1], WINDOW_START, finFace)
                ], below, above);

        // Swing pin keep-out: the long arc from one end of its reach to the
        // other, through the side away from the backing pin.
        const far = -toBacking;
        const ringIn = CENTER_TO_SWING - keepR;
        const ringOut = CENTER_TO_SWING + keepR;
        const ring = newSketchOnPlane(context, id + "plateCut" + "ring" + "sketch", {
                    "sketchPlane" : plane(vector(zero, zero, TOP - above), vector(0, 0, 1), vector(1, 0, 0))
                });
        const dirA = capA / CENTER_TO_SWING;
        const dirB = capB / CENTER_TO_SWING;
        skArc(ring, "outer", { "start" : inSketch(dirB * ringOut), "mid" : inSketch(far * ringOut), "end" : inSketch(dirA * ringOut) });
        skLineSegment(ring, "endA", { "start" : inSketch(dirA * ringOut), "end" : inSketch(dirA * ringIn) });
        skArc(ring, "inner", { "start" : inSketch(dirA * ringIn), "mid" : inSketch(far * ringIn), "end" : inSketch(dirB * ringIn) });
        skLineSegment(ring, "endB", { "start" : inSketch(dirB * ringIn), "end" : inSketch(dirB * ringOut) });
        skSolve(ring);
        opExtrude(context, id + "plateCut" + "ring" + "body", {
                    "entities" : qSketchRegion(id + "plateCut" + "ring" + "sketch"),
                    "direction" : vector(0, 0, 1),
                    "endBound" : BoundingType.BLIND,
                    "endDepth" : above - below
                });
        pillar(context, id + "plateCut" + "capA", capA, keepR, below, above);
        pillar(context, id + "plateCut" + "capB", capB, keepR, below, above);

        // Screws go down through the top into the bar.
        const screws = [vector(CHANNEL_START - 15 * millimeter, BAR_Y), vector(channelEnd + 12 * millimeter, BAR_Y)];
        for (var i = 0; i < size(screws); i += 1)
        {
            countersunk(context, id + "plateCut" + ("screw" ~ i), at(screws[i], TOP), vector(0, 0, -1), WEB);
        }

        deboss(context, id + "plateCut" + "mark", MARK, at(vector((screws[0][0] + screws[1][0]) / 2, BAR_Y), TOP),
            vector(0, 0, -1), along(vector(1, 0)), MARK_HEIGHT);
        const labelR = vector((bossOut + notchEnd[0]) / 2 + 2 * millimeter, (off + notchR + bossHi) / 2);
        deboss(context, id + "plateCut" + "labelR", "R CW", at(labelR, TOP), vector(0, 0, -1), along(vector(1, 0)),
            LABEL_HEIGHT);
        deboss(context, id + "plateCut" + "labelL", "L CCW", at(reflect(labelR, toBacking), TOP), vector(0, 0, -1),
            along(reflect(vector(1, 0), toBacking)), LABEL_HEIGHT);
        deboss(context, id + "plateCut" + "center", "CENTER", at(vector(zero, zero), TOP), vector(0, 0, -1),
            along(vector(1, 0)), 2.8 * millimeter);
        for (var i = 0; i < size(legs); i += 1)
        {
            deboss(context, id + "plateCut" + ("fin" ~ i), legs[i].label,
                at(legAt(legs[i], WINDOW_START + 12 * millimeter, finBack + FLANGE / 2), TOP), vector(0, 0, -1),
                along(legs[i].dir), LABEL_HEIGHT);
        }

        opBoolean(context, id + "plateSubtract", {
                    "tools" : qSketchFilter(qCreatedBy(id + "plateCut", EntityType.BODY), SketchObject.NO),
                    "targets" : qSketchFilter(qCreatedBy(id + "plate", EntityType.BODY), SketchObject.NO),
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        // Fins go on after the windows are cut, so the windows run right up
        // to them.
        for (var i = 0; i < size(legs); i += 1)
        {
            extrudePlan(context, id + "fin" + ("leg" ~ i), [
                        legAt(legs[i], FIN_START, finFace), legAt(legs[i], finEnd, finFace),
                        legAt(legs[i], finEnd, finBack), legAt(legs[i], FIN_START, finBack)
                    ], wallBottom, TOP);
        }
        const plate = qSketchFilter(qUnion([qCreatedBy(id + "plate", EntityType.BODY), qCreatedBy(id + "fin", EntityType.BODY)]),
            SketchObject.NO);
        opBoolean(context, id + "finJoin", {
                    "tools" : plate,
                    "operationType" : BooleanOperationType.UNION
                });

        // Trim to the bed, which is square on the print axes.
        const half = BED / 2;
        const big = 1 * meter;
        const outside = [[-big, -big, -half, big], [half, -big, big, big], [-big, -big, big, -half], [-big, half, big, big]];
        for (var i = 0; i < size(outside); i += 1)
        {
            const o = outside[i];
            fCuboid(context, id + "bed" + ("side" ~ i), {
                        "corner1" : vector(o[0], o[1], -1 * millimeter),
                        "corner2" : vector(o[2], o[3], TOP + 1 * millimeter)
                    });
        }
        opBoolean(context, id + "bedTrim", {
                    "tools" : qCreatedBy(id + "bed", EntityType.BODY),
                    "targets" : plate,
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        // Stop block. The leg lies on the floor against the stop face, under
        // a lip that holds it flat; the sleeve rides the bar. The outboard
        // edges of the floor and the lip are chamfered so the leg rides in
        // between them.
        const yLo = BAR_Y - barHalf - BLOCK_WALL;
        const yHi = BAR_Y + barHalf + BLOCK_WALL;
        const barBottom = webBottom - BAR;
        const sleeveLo = barBottom - BAR_CLEARANCE - BLOCK_WALL;
        const sleeveHi = webBottom + BAR_CLEARANCE + BLOCK_WALL;
        const floorOut = stopFace - FLOOR_RUN;
        blockPrism(context, id + "block" + "floor", [
                    vector(floorOut, -FLOOR), vector(stopFace, -FLOOR), vector(stopFace, zero),
                    vector(floorOut + LEAD_IN, zero), vector(floorOut, -LEAD_IN)
                ], yLo, yHi, stopFace);
        const lipBottom = ROD + 2 * NOTCH_CLEARANCE;
        const lipTop = barBottom - BAR_CLEARANCE;
        blockPrism(context, id + "block" + "lip", [
                    vector(stopFace - ROD, lipBottom + LEAD_IN), vector(stopFace - ROD + LEAD_IN, lipBottom),
                    vector(stopFace, lipBottom), vector(stopFace, lipTop), vector(stopFace - ROD, lipTop)
                ], yLo, yHi, stopFace);
        blockBox(context, id + "block" + "wall", stopFace, stopFace + STOP_WALL, yLo, yHi, -FLOOR, sleeveHi, stopFace);
        blockBox(context, id + "block" + "sleeve", stopFace, stopFace + BLOCK_LENGTH, yLo, yHi, sleeveLo, sleeveHi, stopFace);
        opBoolean(context, id + "blockJoin", {
                    "tools" : qSketchFilter(qCreatedBy(id + "block", EntityType.BODY), SketchObject.NO),
                    "operationType" : BooleanOperationType.UNION
                });
        blockBox(context, id + "blockCut" + "bar", stopFace - 1 * millimeter, stopFace + BLOCK_LENGTH + 1 * millimeter,
            BAR_Y - barHalf, BAR_Y + barHalf, barBottom - BAR_CLEARANCE, webBottom + BAR_CLEARANCE, stopFace);
        const screwAt = blockAt(stopFace + BLOCK_LENGTH * 0.6, yHi, (barBottom + webBottom) / 2, stopFace);
        countersunk(context, id + "blockCut" + "screw", screwAt, vector(0, 0, 1), BLOCK_WALL);
        deboss(context, id + "blockCut" + "mark", MARK,
            blockAt(stopFace + BLOCK_LENGTH / 2 + 1 * millimeter, yHi, sleeveHi - BLOCK_WALL / 2 - 2.5 * millimeter, stopFace),
            vector(0, 0, 1), vector(-1, 0, 0), 4 * millimeter);
        opBoolean(context, id + "blockSubtract", {
                    "tools" : qSketchFilter(qCreatedBy(id + "blockCut", EntityType.BODY), SketchObject.NO),
                    "targets" : qSketchFilter(qCreatedBy(id + "block", EntityType.BODY), SketchObject.NO),
                    "operationType" : BooleanOperationType.SUBTRACTION
                });

        opDeleteBodies(context, id + "cleanup", {
                    "entities" : qSketchFilter(qCreatedBy(id, EntityType.BODY), SketchObject.YES)
                });
    });

annotation { "Feature Type Name" : "Pin coupons",
        "Feature Type Description" : "The bend plate's center and backing pin pockets alone, at several clearances" }
export const pinCoupons = defineFeature(function(context is Context, id is Id, definition is map)
    precondition
    {
    }
    {
        const pinR = PIN / 2;
        const backing = backingCenter();
        const toBacking = backing / CENTER_TO_BACKING;
        const across = vector(-toBacking[1], toBacking[0]);
        const pocketBottom = PIN_TOP - POCKET;
        for (var i = 0; i < size(COUPON_CLEARANCES); i += 1)
        {
            const clearance = COUPON_CLEARANCES[i];
            const at0 = across * i * COUPON_PITCH;
            const pocketR = pinR + clearance;
            const bossR = pocketR + WALL;
            const coupon = id + ("coupon" ~ i);
            pillar(context, coupon + "body" + "center", at0, bossR, pocketBottom, TOP);
            stadium(context, coupon + "body" + "backing", at0 + backing, toBacking, bossR, pocketBottom, TOP);
            extrudePlan(context, coupon + "body" + "bridge", [
                        at0 + across * 6 * millimeter, at0 + backing + across * 6 * millimeter,
                        at0 + backing - across * 6 * millimeter, at0 - across * 6 * millimeter
                    ], TOP - WEB, TOP);
            opBoolean(context, coupon + "join", {
                        "tools" : qSketchFilter(qCreatedBy(coupon + "body", EntityType.BODY), SketchObject.NO),
                        "operationType" : BooleanOperationType.UNION
                    });
            pillar(context, coupon + "cut" + "center", at0, pocketR, pocketBottom - 1 * millimeter, PIN_TOP);
            stadium(context, coupon + "cut" + "backing", at0 + backing, toBacking, pocketR, pocketBottom - 1 * millimeter,
                PIN_TOP);
            deboss(context, coupon + "cut" + "label", toString(roundToPrecision(clearance / millimeter, 2)), at(at0, TOP),
                vector(0, 0, -1), along(toBacking), LABEL_HEIGHT);
            opBoolean(context, coupon + "subtract", {
                        "tools" : qSketchFilter(qCreatedBy(coupon + "cut", EntityType.BODY), SketchObject.NO),
                        "targets" : qSketchFilter(qCreatedBy(coupon + "body", EntityType.BODY), SketchObject.NO),
                        "operationType" : BooleanOperationType.SUBTRACTION
                    });
        }
        opDeleteBodies(context, id + "cleanup", {
                    "entities" : qSketchFilter(qCreatedBy(id, EntityType.BODY), SketchObject.YES)
                });
    });

// The backing pin's center. The rod runs along y = off, between the center
// pin and the backing pin, which sits 2 * off across from the center pin's.
function backingCenter() returns Vector
{
    const off = (PIN + ROD) / 2;
    return vector(-sqrt(CENTER_TO_BACKING ^ 2 - (2 * off) ^ 2), 2 * off);
}

// Plate use coordinates to print coordinates: turned BED_ANGLE about z, moved
// so BED_CENTER lands on the print origin, and turned over the x axis so the
// top face lands on the bed.
function at(p is Vector, z is ValueWithUnits) returns Vector
{
    const q = inSketch(p);
    return vector(q[0], q[1], TOP - z);
}

// A plan point as it lands in a print-plane sketch.
function inSketch(p is Vector) returns Vector
{
    return turn(p - BED_CENTER);
}

// A plan direction in print coordinates.
function along(d is Vector) returns Vector
{
    const t = turn(d);
    return vector(t[0], t[1], 0);
}

function turn(v is Vector) returns Vector
{
    const c = cos(BED_ANGLE);
    const s = sin(BED_ANGLE);
    return vector(c * v[0] + s * v[1], s * v[0] - c * v[1]);
}

// Point s along a leg's path from where it leaves the center pin, u toward
// its fin.
function legAt(leg is map, s is ValueWithUnits, u is ValueWithUnits) returns Vector
{
    return leg.start + leg.dir * s + leg.side * u;
}

// Block use coordinates to print coordinates: stood on its -y side, stop face
// at print x = -60 mm, off the plate's corner of the bed.
function blockAt(x is ValueWithUnits, y is ValueWithUnits, z is ValueWithUnits, stopFace is ValueWithUnits) returns Vector
{
    return vector(x - stopFace - 60 * millimeter, -z - 100 * millimeter, y - BAR_Y + BAR / 2 + BAR_CLEARANCE + BLOCK_WALL);
}

// Reflection across the line through the center pin along dir.
function reflect(p is Vector, dir is Vector) returns Vector
{
    return 2 * dot(p, dir) * dir - p;
}

function reflectAll(points is array, dir is Vector) returns array
{
    var result = [];
    for (var p in points)
    {
        result = append(result, reflect(p, dir));
    }
    return result;
}

// Plan outline from zLow up to zHigh.
function extrudePlan(context is Context, id is Id, points is array, zLow is ValueWithUnits, zHigh is ValueWithUnits)
{
    const sketch = newSketchOnPlane(context, id + "sketch", {
                "sketchPlane" : plane(vector(0 * meter, 0 * meter, TOP - zHigh), vector(0, 0, 1), vector(1, 0, 0))
            });
    var pts = [];
    for (var p in points)
    {
        pts = append(pts, inSketch(p));
    }
    skPolyline(sketch, "outline", { "points" : append(pts, pts[0]) });
    skSolve(sketch);
    opExtrude(context, id + "body", {
                "entities" : qSketchRegion(id + "sketch"),
                "direction" : vector(0, 0, 1),
                "endBound" : BoundingType.BLIND,
                "endDepth" : zHigh - zLow
            });
}

function pillar(context is Context, id is Id, center is Vector, radius is ValueWithUnits, zLow is ValueWithUnits, zHigh is ValueWithUnits)
{
    fCylinder(context, id, { "bottomCenter" : at(center, zHigh), "topCenter" : at(center, zLow), "radius" : radius });
}

// Pocket or boss SLOT_PLAY long along dir, centered on center.
function stadium(context is Context, id is Id, center is Vector, dir is Vector, radius is ValueWithUnits, zLow is ValueWithUnits, zHigh is ValueWithUnits)
{
    const half = dir * SLOT_PLAY / 2;
    const side = vector(-dir[1], dir[0]) * radius;
    pillar(context, id + "a", center + half, radius, zLow, zHigh);
    pillar(context, id + "b", center - half, radius, zLow, zHigh);
    extrudePlan(context, id + "mid", [center + half + side, center - half + side, center - half - side, center + half - side], zLow, zHigh);
}

function blockBox(context is Context, id is Id, x0 is ValueWithUnits, x1 is ValueWithUnits, y0 is ValueWithUnits, y1 is ValueWithUnits,
    z0 is ValueWithUnits, z1 is ValueWithUnits, stopFace is ValueWithUnits)
{
    const a = blockAt(x0, y0, z0, stopFace);
    const b = blockAt(x1, y1, z1, stopFace);
    fCuboid(context, id, {
                "corner1" : vector(min(a[0], b[0]), min(a[1], b[1]), min(a[2], b[2])),
                "corner2" : vector(max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]))
            });
}

// Block profile in use (x, z), from y0 to y1.
function blockPrism(context is Context, id is Id, profile is array, y0 is ValueWithUnits, y1 is ValueWithUnits,
    stopFace is ValueWithUnits)
{
    const zero = 0 * millimeter;
    const sketch = newSketchOnPlane(context, id + "sketch", {
                "sketchPlane" : plane(vector(zero, zero, blockAt(zero, y0, zero, stopFace)[2]), vector(0, 0, 1), vector(1, 0, 0))
            });
    var pts = [];
    for (var p in profile)
    {
        const q = blockAt(p[0], y0, p[1], stopFace);
        pts = append(pts, vector(q[0], q[1]));
    }
    skPolyline(sketch, "outline", { "points" : append(pts, pts[0]) });
    skSolve(sketch);
    opExtrude(context, id + "body", {
                "entities" : qSketchRegion(id + "sketch"),
                "direction" : vector(0, 0, 1),
                "endBound" : BoundingType.BLIND,
                "endDepth" : y1 - y0
            });
}

// Clearance hole for a #8 flat head, countersunk at face (print coordinates),
// running depth into the part along -normal.
function countersunk(context is Context, id is Id, face is Vector, normal is Vector, depth is ValueWithUnits)
{
    fCylinder(context, id + "hole", {
                "bottomCenter" : face - normal * (depth + 1 * millimeter),
                "topCenter" : face + normal * 1 * millimeter,
                "radius" : SCREW / 2
            });
    fCone(context, id + "sink", {
                "bottomCenter" : face - normal * ((SCREW_HEAD - SCREW) / 2),
                "bottomRadius" : SCREW / 2,
                "topCenter" : face + normal * 0.5 * millimeter,
                "topRadius" : SCREW_HEAD / 2 + 0.5 * millimeter
            });
}

// Text centered on center, cut DEBOSS deep. It reads upright to someone facing
// the face along -normal, running along xDir.
function deboss(context is Context, id is Id, text is string, center is Vector, normal is Vector, xDir is Vector, height is ValueWithUnits)
{
    const sketch = newSketchOnPlane(context, id + "sketch", {
                "sketchPlane" : plane(center, normal, xDir)
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

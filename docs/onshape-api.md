# Onshape API

Field notes from scripting Onshape's REST API and FeatureScript directly,
rather than clicking through the web UI. Onshape's own docs are the
reference for endpoint shapes; this is the stuff that bit us that the docs
don't mention, or mention in a place you won't find until after you've hit
it.

Base API URL: `https://cad.onshape.com/api/v9`.

## Authentication

Onshape signs requests with HMAC-SHA256 over an access key / secret key
pair, generated at the developer portal
(`https://dev-portal.onshape.com`, which redirects to
`https://cad.onshape.com/appstore/dev-portal`). An API key is account-wide
and equivalent to being logged in as that user — treat it like any other
credential in this repo's threat model. See [Known gaps](#known-gaps)
below; it isn't in sops yet.

The signing algorithm
([Onshape API key docs](https://onshape-public.github.io/docs/auth/apikeys/)):

1. Build a base string from, in order: HTTP method, the `On-Nonce` header
   value, the `Date` header value, `Content-Type`, the URL path, and the
   query string (empty string if none). Join with `\n`, **including a
   trailing `\n` after the query string** (six fields means six
   newlines, not five), then lowercase the whole thing. The trailing
   newline isn't mentioned by the prose docs at
   [onshape-public.github.io/docs/auth/apikeys](https://onshape-public.github.io/docs/auth/apikeys/)
   or its Node sample, but it's in the reference Python client's
   `_make_auth()`
   ([onshape-public/apikey](https://github.com/onshape-public/apikey/blob/master/python/apikey/onshape.py)).
   Omit it and every request looks like it's failing on permissions —
   `sessioninfo` returns 204 instead of 401, document reads return 403
   "Resource does not exist, or you do not have permission" — because
   Onshape's document-scoped endpoints return that same masking 403 for
   a garbage `Authorization` header too. The tell: sign a request with a
   deliberately bogus access key/secret and compare — if the response is
   byte-for-byte identical to your "real" request, the real request
   never authenticated either.
2. HMAC-SHA256 the base string with the secret key, base64-encode the
   digest.
3. Send `Authorization: On <accessKey>:HmacSHA256:<signature>`, plus the
   `Date` and `On-Nonce` headers that went into the base string.

`On-Nonce` just needs to be unique per request and at least 16 alphanumeric
characters; `Date` needs to be within 5 minutes of Onshape's clock. stdlib
covers all of it: `hmac`, `hashlib`, `base64`, `urllib`. No `requests`
needed, no SDK needed.

Verify a client works before building anything on it:

```
GET /api/v9/users/sessioninfo
```

A 200 with your user info means the signing is right. Debug signing bugs
here, not against a real document.

## Finding document/workspace/element IDs

Every document URL carries the three IDs almost every other call needs:

```
https://cad.onshape.com/documents/{documentId}/w/{workspaceId}/e/{elementId}
```

`d=`, `w=`, `e=` in API paths map directly to those three segments.

To enumerate what's in a document/workspace:

```
GET /api/v9/documents/d/{did}/w/{wid}/elements
```

Returns each tab (Part Studio, Assembly, Feature Studio, BOM, ...) with its
`id`, `name`, `elementType`, and current `microversionId`. The
microversion bumps every time that element's content changes — it's the
version pin the custom-feature namespace needs, below.

## FeatureScript custom features: the real gotchas

Everything in this section was hit and fixed in one live debugging session
against Onshape's actual compiler, not inferred from docs. The one exception
is the `targetsAndToolsNeedGrouping` flag, which comes from the forum and is
marked unverified where it appears.

### `newSketch` needs an existing planar face, not a constructed plane

`newSketch(context, id, {"sketchPlane": ...})` requires `sketchPlane` to be
a `Query` that resolves to an existing planar face. Pass it a raw
`plane(origin, normal, x)` value and it fails with:

```
Precondition of newSketch failed (value.sketchPlane is Query)
```

To sketch on an arbitrary constructed plane not tied to existing geometry,
use `newSketchOnPlane` instead — same parameter shape, different
precondition.

### `opExtrude`'s depth parameter is `endDepth`, not `depth`

Passing `"depth"` doesn't raise an error about the unknown key. It fails
validation somewhere else, sometimes as `@opExtrude: INVALID_INPUT`, in a
way that doesn't point back at the actual mistake. Always `"endDepth"`.

### `opExtrude`'s ADD/REMOVE operation types are not reliable booleans

`NewBodyOperationType.ADD` and `.REMOVE` frequently do nothing — the
target body comes out with zero volume change, no error, no new body — or
produce a disconnected floating body instead of actually merging or
cutting into the target. Confirmed by hand-testing and independently by
Onshape's own forum: a thread on `opExtrude` REMOVE silently producing a
new part instead of cutting, whose accepted answer is that ADD/REMOVE
don't reliably work and to use `opBoolean` instead.

The pattern that actually works: extrude as a standalone tool body with
`NewBodyOperationType.NEW`, then boolean it in explicitly.

```
opExtrude(context, id + "tool", { ..., "operationType" : NewBodyOperationType.NEW });
opBoolean(context, id + "cut", {
    "tools" : qCreatedBy(id + "tool", EntityType.BODY),
    "targets" : qCreatedBy(id + "targetBody", EntityType.BODY),
    "operationType" : BooleanOperationType.SUBTRACTION
});
```

### `opBoolean` UNION ignores a separate `targets` set

The `tools` + `targets` two-query shape works for SUBTRACTION. For UNION
it silently doesn't: only the `tools` query gets merged, and whatever was
in `targets` is left completely untouched, with no error.

Fix: put everything you want unioned into one `tools` query via
`qUnion([...])` and drop `targets` entirely.

```
opBoolean(context, id + "merge", {
    "tools" : qUnion([qCreatedBy(id + "bodyA", EntityType.BODY), qCreatedBy(id + "bodyB", EntityType.BODY)]),
    "operationType" : BooleanOperationType.UNION
});
```

The Onshape forum also mentions a `"targetsAndToolsNeedGrouping": true`
flag for the tools+targets form of UNION. Not verified here — the
`qUnion` single-set form is what was actually confirmed working.

### After a UNION, requery with the same combined query

The merged body is only reliably found again through the exact same
combined query that created it. Keep it in a variable and reuse it:

```
var mainQ = qUnion([qCreatedBy(idA, EntityType.BODY), qCreatedBy(idB, EntityType.BODY)]);
// ... later, referencing the whole merged body so far:
// use mainQ again, not qCreatedBy(idA, EntityType.BODY) alone
```

Querying by a single original creation id after it has taken part in a
union can fail outright with `CANNOT_RESOLVE_ENTITIES`.

### No compiler error is not proof the geometry is right

A cut extruded in the wrong direction, or a UNION that silently did
nothing, both compile clean. Onshape will happily hand you a wrong result
with zero diagnostics.

Verify with `evVolume(context, {"entities": ...})` and
`evBox3d(context, {"topology": ...})` against hand-calculated expectations.
Volume is the sharper check: a cut that didn't happen leaves volume
exactly unchanged, which is easy to catch against the expected
post-cut number.

## The `/featurescript` endpoint as a test REPL

```
POST /api/v9/partstudios/d/{d}/w/{w}/e/{elementId}/featurescript
{"script": "<code>"}
```

Evaluates arbitrary FeatureScript against a live Part Studio's context
without touching the real document. This is the fast iteration loop —
much cheaper than round-tripping through a Feature Studio push and a real
feature insert for every change.

A few things about it that aren't obvious from the endpoint shape:

- The script has to be a single expression that evaluates to a function.
  A bare `"1 + 1"` fails with `"script does not evaluate to a function"`.
- The function it calls takes **two** arguments, not one. Onshape calls it
  as `function(context is Context, x) { ... }`; a one-argument
  `function(context is Context) {...}` fails with `"Cannot call a function
that takes 1 arguments with 2"`.
- There's no real feature `id` inside that function. Build one with
  `makeId("anything")`, which returns an actual `Id`. The raw second
  argument Onshape passes in is not itself a usable `Id` — a plain string
  fails on anything like `id + "suffix"` with `"Can not add map and
string"`.
- Repeated calls against the same Part Studio element in one session can
  appear to accumulate geometry across calls: a `qEverything(EntityType.BODY)`
  count that creeps up, bounding boxes that don't make sense for what you
  just built. The real Part Studio, checked with a normal
  `GET .../features` or `GET .../parts`, stays at zero features and zero
  parts the whole time. Don't use `qEverything` to verify anything here —
  scope every check to `qCreatedBy(<your test's own ids>, ...)`, which
  isn't affected.
- It evaluates one self-contained function, not a module. No
  `import(...)`, no top-level `export const x = defineFeature(...)`. It's
  good for testing a feature's body logic — the sketch/extrude/boolean
  sequence — but it can't validate the `defineFeature`/`precondition`
  wrapper that actually makes something a custom feature. That only gets
  checked when the code is inserted as a real feature.

## Publishing FeatureScript as a real custom feature

Write it in a Feature Studio element:

```
POST /api/v9/featurestudios/d/{d}/w/{w}                          # create
POST /api/v9/featurestudios/d/{d}/w/{w}/e/{fsId}                 # push source
{"contents": "<full .fs source>"}
```

The push always succeeds at "stored the text," even with a syntax error in
the FeatureScript. Storing is not compiling.

To add an instance of `export const myFeature = defineFeature(...)` to a
Part Studio:

```
POST /api/v9/partstudios/d/{d}/w/{w}/e/{partStudioId}/features
{
  "feature": {
    "btType": "BTMFeature-134",
    "featureType": "myFeature",
    "name": "some display name",
    "namespace": "<see below>",
    "suppressed": false,
    "parameters": [
      {"btType": "BTMParameterQuantity-147", "parameterId": "someLength", "expression": "72 mm", "value": 0.072, "units": "meter", "isInteger": false, "parameterName": ""},
      {"btType": "BTMParameterBoolean-144", "parameterId": "someFlag", "value": true, "parameterName": ""}
    ],
    "returnAfterSubfeatures": false, "subFeatures": [], "parameterLibraries": [], "suppressionState": null
  }
}
```

### `namespace` is where nearly all the debugging time went

Confirmed working format:

```
d<documentId>::v<versionId>::e<featureStudioElementId>::m<microversionId>
```

Literal single-letter prefixes (`d`, `v`, `e`, `m`), raw IDs, joined by
`::`. Three things about it that will burn you:

- `v` has to be a real **Document Version** id, not a workspace
  microversion. Create one with
  `POST /api/v9/documents/d/{did}/versions`,
  `{"name": "...", "workspaceId": "...", "documentId": "..."}`; it returns
  `id`. A Version is an immutable snapshot.
- `m` is the Feature Studio element's _current_ `microversionId` (from the
  elements list endpoint above) at the moment the Version is created.
- **Create the Version after pushing the Feature Studio content you want
  it to reference.** A Version freezes the whole document at that instant.
  Pair an old Version with a newer Feature Studio microversion that didn't
  exist yet when that Version was taken, and the combination doesn't
  correspond to any real snapshot. That doesn't fail at insert time — the
  feature inserts fine — it fails at compute time, with the unhelpful
  runtime error `"<name> did not regenerate properly. The definition of
this custom feature was not found"`. A malformed namespace string
  (wrong shape, bad ids) fails immediately at insert instead, with a 400
  and `"Feature <id> has an invalid namespace"`. Different failure, very
  different point in the workflow — worth knowing which one you're
  looking at.

When the exact working format is in doubt for a given account or
workspace state, don't guess: add one instance of the custom feature by
hand through the Onshape web UI (its own client handles version/namespace
bookkeeping correctly), then `GET .../features` and read back the real
`namespace` string it generated. Reverse-engineer from a known-good
example. This is also the standard advice on Onshape's own forum for this
exact problem.

Existing feature instances don't pick up a Feature Studio edit
automatically — they stay pinned to whatever namespace/microversion they
were created with. To make one recompute against new code, update or
recreate the instance with a fresh namespace (new Version, current
microversion).

## Building features through the REST features API

Everything below came from building a part studio (variables, sketches,
extrudes, a construction plane and a fillet) entirely over
`POST .../features`, with no UI. The failures are all silent: the call
returns 200, the feature reports `OK`, and the model is still wrong.

### Read `featurespecs` before writing any feature JSON

```
GET /api/v9/partstudios/d/{d}/w/{w}/e/{e}/featurespecs
```

Every feature type the part studio accepts, with each parameter's
`parameterId`, `btType`, enum name and legal values. Guessing any of it costs
more time than reading it.

Guessing the feature type itself at least fails loudly:

```
{"message": "Feature has invalid type", "status": 400}
```

The variable feature is `assignVariable`, not `variable`. The construction
plane is `cPlane`.

### Parameters get dropped without an error

A parameter Onshape doesn't want in that position is discarded on the way in.
The POST returns 200 and the feature reports `OK`.

A sketch `DIAMETER` constraint given its value under `length` reads back as:

```
[{"localFirst": "h1"}, {"direction": "MINIMUM"}, {"length": 0.0}, ...]
```

The expression is gone and the value is 0. `RADIUS` accepts `length` in
exactly that shape, which is what makes this easy to miss. Read every
dimension constraint back and confirm `expression` survived.

`assignVariable` has the same problem in reverse. A LENGTH variable stores its
number in `lengthValue`; writing it under `value` alone puts the feature in
`ERROR`. The tree label, though, comes from the spec's name template,
`###name = #value`, which reads the generic `value`. Write both `lengthValue`
and `value` with the same expression.

### Leave `BTMFeature.name` empty

Onshape treats a `#token` in a stored feature name as a variable reference and
substitutes it at render time. Name a variable feature `#length = 130 mm` and
the tree shows:

```
(x) ? = 130 mm
```

The `?` is the substitution failing, because at that row `length` is the
variable being defined and does not exist yet. The `130 mm` is dead literal
text. Edit the value in the UI and the row keeps saying `130 mm` while the
model quietly rebuilds at the new number, which is a worse failure than an
error.

Send `name: ""` and Onshape renders `featureNameTemplate` live instead. It
does not backfill the field, so an empty name stays empty on read. Check
`featureNameTemplate` and `tooltipTemplate` in `featurespecs` to see which
parameters a feature's label actually reads.

### A full circle is `BTMSketchCurve-4`, not a 2\*PI curve segment

A circle written as `BTMSketchCurveSegment-155` with `startParam` 0 and
`endParam` 2\*PI looks right and is not. Its seam endpoints stay free, so the
sketch reports `UNDERDEFINED` however many constraints you add, and the curve
never closes into a region, so any extrude selecting it fails with a bare
`ERROR` and no message.

`BTMSketchCurve-4` takes the same `BTCurveGeometryCircle-115` geometry plus a
`centerId`, with no start or end point ids. Arcs and lines stay
`BTMSketchCurveSegment-155`.

### `sketchSolveStatus` is the only honest answer

`featureStates` reporting `OK` says nothing about whether a sketch is fully
constrained. This does:

```
GET /api/v9/partstudios/d/{d}/w/{w}/e/{e}/sketches?includeGeometry=false
```

Each entry carries `sketchSolveStatus`: `WELL_DEFINED`, `UNDERDEFINED` or
`OVERDEFINED`. Check it after every sketch. An underdefined sketch builds
correct geometry today and moves under you the first time a variable changes.

### `Fix` on a line segment does not pin its endpoints

It pins the line. The endpoints still slide along it, so the segment's length
and its position along that line are both free. A chord `Fix`ed across a face
sits where you drew it, reports `UNDERDEFINED`, and is holding its dimension
by luck.

Anchor to the origin instead. It is available as an external reference under
the deterministic id `IB`:

```json
{
  "btType": "BTMParameterQueryList-148",
  "parameterId": "externalSecond",
  "queries": [
    { "btType": "BTMIndividualQuery-138", "deterministicIds": ["IB"] }
  ]
}
```

### Plain FeatureScript query strings work

Deterministic ids are fine for the origin, which never moves, but they are a
poor way to name anything a rebuild can renumber. A query parameter also takes
a literal FeatureScript string:

```json
{
  "queryString": "query=qCreatedBy(makeId(\"Front\"), EntityType.FACE);",
  "deterministicIds": []
}
```

`Origin`, `Top`, `Front` and `Right` are the default feature ids; any id from
`GET .../features` works the same way. `context` is in scope, so
`getVariable` makes a selection parametric:

```
query=(function(){ var L = getVariable(context, "length");
  return qContainsPoint(edges, vector(-L/2, ...)); })();
```

That is how you select a fillet edge that survives a dimension change.

### `qEverything(EntityType.EDGE)` includes sketch geometry

Sketch curves are edges too, lying exactly on top of the model edges they
generated. `qContainsPoint` against `qEverything` returns three or five hits
where you expect one. Scope it:

```
qOwnedByBody(qBodyType(qEverything(EntityType.BODY), BodyType.SOLID), EntityType.EDGE)
```

### There is no way to insert or reorder a feature

Features append to the end of the list. `rollbackIndex` in the
`POST .../features` body is accepted and ignored, and `/features/updates` and
`/features/reorder` are both 404.

Editing one in place does work, over
`POST .../features/featureid/{featureId}` with the whole feature in the body.
Round-trip it from `GET .../features` rather than writing it fresh, and carry
`serializationVersion` and `sourceMicroversion` from that same read. Every
write moves the microversion, so re-read between writes when updating several.

This matters because a variable must sit above every feature that uses it.
Adding one to an existing part studio means deleting and rebuilding every
feature from its first consumer down. Decide the variable order before writing
any geometry, and keep the whole tree in a build script, because you will run
it more than once.

Variable Studios do not get you out of this. Their
`variableStudioAssignVariable` features append to the end like everything
else.

### Variable Studios

Creation is not under the path you would guess:

```
POST     /api/v9/variables/d/{did}/w/{wid}/variablestudio
GET|POST /api/v9/variables/d/{did}/w/{wid}/e/{eid}/variables
```

`/variablestudios/...` is 404. Contents are a list of blocks, each with a
`variableStudioReference` and a `variables` list. Set them with `expression`;
under `value` they store as null.

Deleting the element over the API returns 403, so an unwanted studio has to go
through the UI. Onshape will warn that deleting it breaks every Part Studio
and Assembly in the document. That comes from the studio's "insert into all
Part Studios and Assemblies" default, not from real references. Check
`variableStudioReference` on the consumer: if it is null everywhere, nothing
is using it. Emptying the variable list first makes the question moot.

### Volume agreement does not prove placement

A part built on a wrong axis assumption can still have exactly the right
volume. Check the bounding box separately:

```
GET /api/v9/parts/d/{d}/w/{w}/e/{e}/partid/{pid}/boundingboxes
```

And for a dimension the model is meant to hold, measure it rather than trust
the arithmetic that produced it. `evDistance` between two faces picked with
`qContainsPoint` is the direct check:

```
evDistance(context, {"side0": backFace, "side1": scoopFace}).distance
```

## Practical workflow

1. Build the signed HTTP client once, stdlib only, reuse it everywhere.
2. Verify auth against `sessioninfo` before touching a real document.
3. Iterate a feature's body logic against the `/featurescript` evaluate
   endpoint. Check `evVolume`/`evBox3d` against hand-calculated numbers,
   not just "it didn't error."
4. Once the logic is solid, push it into a Feature Studio.
5. Get a known-good `namespace` by adding one instance through the UI and
   reading it back, or build it directly per the format above, creating a
   fresh Version whenever you need new instances to pick up code changes.
6. Verify the resulting real parts with `GET .../parts` and
   `GET .../parts/.../boundingboxes` before trusting the geometry.

Building the model over `POST .../features` instead, which is the shorter path
when the geometry needs no custom feature:

1. Pull `featurespecs` and take the `parameterId` and enum names from it.
2. Fix the variable order first. Reordering later means a full rebuild.
3. Keep the whole tree in one build script that deletes and recreates. You
   will run it repeatedly.
4. After each sketch, check `sketchSolveStatus` is `WELL_DEFINED`, and read
   back any dimension constraint to confirm its `expression` survived.
5. Verify with hand-calculated volume, the bounding box, and `evDistance` on
   whatever dimension the model is supposed to hold.

## Known gaps

Onshape API keys aren't in sops yet. Today's session used a key dropped in
a permission-restricted scratch file and shredded after use — fine for a
one-off, not a pattern to repeat. Follow-up: add `onshape_api_key` /
`onshape_api_secret` to `nix/secrets/secrets.yaml`, alongside the repo's
other sops-managed secrets. Not done here; flagging it so it doesn't get
forgotten.

Still not done as of the second session, which used a world-readable key in
`/tmp` and shredded it afterwards. Twice now is a habit, not a one-off.

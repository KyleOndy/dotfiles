# helios import path: correctness, data-safety, and performance

## Context

`helios import filesystem` is now the primary import path. `import camera`
fails on files over 4GB (a PTP GetObject 32-bit limit helios cannot fix),
so cards get mounted and imported directly. A line-by-line review of
`nix/pkgs/helios/import_from.py`, plus a deliberate data-loss and edge-case
pass, found the issues below.

Measured symptom during review: an immediate re-run of
`import filesystem /run/media/kyle/disk/` took 3:54 wall, 80s user CPU.
No files are re-copied on a re-run, but every byte is re-hashed, exiftool
is spawned per MOV/RAF for a timestamp that is computed before the dedup
check and then discarded, and every seen-check is a full table scan on a
fresh sqlite connection.

Decisions already made:

- Scope: import path only (`import_from.py`, `main.py`, `default.nix`,
  README). The fuji modules get their own pass later if wanted.
- Add a metadata (name, size, mtime) pre-hash skip for fast re-imports.
- Remove `--prune` entirely. Unused; cleanup happens out of band. helios
  then never deletes source files, which closes every deletion-based loss
  chain at once.
- Remove `--clobber` entirely. It only fires when the destination provably
  holds different content, so its sole effect is destroying a library
  photo.
- DB default location: keep the code's XDG state path; fix the README,
  which wrongly claims `<library>/helios.db`.

Target: a no-op re-run is walk + stat + one indexed lookup per file
(seconds, not minutes), and an interrupted or power-cut import can never
corrupt the library, strand a photo, or mislead the DB.

All code changes land in `nix/pkgs/helios/import_from.py` unless noted.

## A. Data safety

### A1. Atomic, durable, single-read imports

Today `shutil.copyfile` writes straight to the final name with no fsync,
and the DB is marked afterward. Failure modes: ENOSPC or a crash mid-copy
leaves a permanent half-photo in `_provisional/` under the canonical name.
Power loss after the DB commit but before writeback leaves a truncated
destination that the DB claims is imported, and out-of-band card cleanup
trusts that claim. A crash between copy and DB mark also makes the next
run land a `_md5suffix` duplicate of identical content
(import_from.py:492-503, whose comment wrongly claims the seen-check ruled
this out).

Replace the copy with one streaming helper:

1. Stream the source in large chunks to a hidden temp file `.<name>.part`
   in the destination dir, updating the md5 as it goes. One read of the
   source instead of today's hash-read plus copy-read; a 20GB MOV off an
   SD card is read once, not twice.
2. With the hash known: if seen in `file_imports`, discard the temp and
   return (dedup). If `dst` exists, compare `md5(dst)`; equal means a
   prior crashed run already imported it, so discard the temp, mark,
   return (self-heal, no duplicate). Different content takes the existing
   `_md5suffix` collision rename.
3. `os.fsync` the temp, `os.rename` into place (atomic: the library never
   contains a partial file), fsync the directory, `os.utime` to preserve
   the source mtime (today's copyfile loses it; the move path keeps it).
4. Only then `mark_file_as_imported`. The DB never claims bytes that are
   not durable on disk.
5. Move mode: same-filesystem keeps the fast path (plain `md5()` read,
   seen-check, fsync, `os.rename`, fsync dir, mark); cross-filesystem
   uses the streaming helper and removes the source only after the DB
   mark. Delete temp files in a `finally`; a deterministic temp name
   means a crashed leftover is overwritten on retry.

### A2. Remove --prune

Delete the flag and both branches (import_from.py:430-436, 486-489).
helios no longer contains any `os.remove` of a source file outside move
mode.

### A3. Remove --clobber

Delete the flag and its branch (import_from.py:436-438, 492); A1's
same-content check plus the collision suffix cover every real case. The
internal camera call sites drop the arguments too.

### A4. Camera stranded-photo bug

`mark_camera_file_seen` runs right after download (import_from.py:407),
before the group's library import. A crash in between means future runs
skip the download while the photo never reached the library: a silent
drop until `--force-download`. Fix `check_camera_file_seen` to only skip
when the recorded md5 actually reached the library:

```sql
SELECT EXISTS(
  SELECT 1 FROM camera_files c
  JOIN file_imports i ON i.md5 = c.md5
  WHERE c.serial=? AND c.name=? AND c.size=? AND c.mtime=?)
```

Historical stranded rows self-heal (re-download, md5 dedup).

### A5. Camera per-file download resilience

Wrap `gp_camera_file_get` and `gp_file_save` (import_from.py:401-406) in
`try/except gp.GPhoto2Error`: unlink any partial cache file (otherwise
the group import lands a truncated photo in the library and marks its md5
seen), warn with a note about the PTP 4GB limit for MOVs, and continue.
One oversized MOV no longer strands the whole RAF group.

### A6. Stale camera caches hold real photos

`shutil.rmtree(cache)` only runs on success; a crashed run leaves
`~/.cache/helios/imports/<ts>/` holding photos that may be the only copy
if the card was since formatted. At `camera()` start, warn about leftover
non-empty import dirs with a recovery hint
(`helios import filesystem <dir> --move`, then remove it). Never
auto-delete them.

### A7. Loud accounting

- `filesystem`: hard-error (exit 1) when `src` does not exist or contains
  zero media files. Today a typo'd or unmounted path "succeeds" with 0
  files, and the card gets formatted anyway.
- Unhandled extensions are currently dropped at debug level; a card of
  HEIFs "imports successfully" importing nothing. End every run with a
  summary at info/warning level
  (`imported N, skipped-seen M, skipped-metadata K, unhandled-ext (.hif: 40), failed F`)
  and exit nonzero if any file failed.
- Per-file resilience: guard the stat pass against vanished files and
  dangling symlinks (`os.path.getsize` currently aborts the whole batch);
  wrap the per-file import in `try/except OSError`, warn, count,
  continue.

### A8. Refuse src inside the library

`import filesystem ~/photos` makes every file "seen" (a mass no-op, and
with `--move` a library reshuffle). Refuse with a clear error when
`realpath(src)` is inside `realpath(photo_dir)`.

### A9. README corrections (nix/pkgs/helios/README.md)

- The dedup db defaults to `~/.local/state/helios/helios.db`
  (`main.py:46`), not `<library>/helios.db` as currently claimed.
- Document the metadata skip and its bound: a (name, size, mtime)
  collision across card formats or counter resets would silently skip a
  file. It stays on the card, never deleted, and `--force-hash`
  re-verifies by content.
- Document `--force-hash`; drop any mention of the removed flags.

## B. Correctness

### B1. HEIF support

The X-T5 shoots HEIF (`.HIF`). Add a HEIF group after JPEG (label "HEIF",
extensions `.hif`/`.heic`) with timestamps via exiftool. Pillow cannot
read HEIF, so `get_media_timestamp` keeps routing only `.jpg`/`.jpeg` to
Pillow.

### B2. Dead branches in get_image_timestamp

Root-level EXIF tags are keyed numerically and Exif-IFD tags by name, so
`"DateTime" in tags` and `36867 in tags` (import_from.py:744-756) can
never match as written. Reduce to the reachable branches
("DateTimeOriginal", "DateTimeDigitized", 306).

## C. Performance

### C1. Metadata pre-hash skip for re-imports

New table in the schema:
`filesystem_files(name, size, mtime, md5, imported_at, UNIQUE(name, size, mtime))`
keyed on basename (card mount paths change between runs), byte size, and
`int(st_mtime)`. Skip a file without reading it when the row exists AND
its md5 is in `file_imports` (same join discipline as A4). Record a row
after every successful mark and in the seen-before branch. `--force-hash`
on `filesystem` bypasses it (analog of camera's `--force-download`). The
camera path's internal import records rows too; gphoto2 preserves camera
mtimes on saved files, so a later card-reader import of the same shots
also skips.

### C2. Two-pass structure

Restructure `_run_filesystem_import`:

- Pass 1 (cheap): stat plus the C1 metadata skip for every file; collect
  survivors.
- Pass 2: one batched exiftool call over just the survivors for rating
  and timestamp, then import them via A1 (which handles md5 dedup
  internally).

This also fixes the ordering bug at import_from.py:476 where the
timestamp (a per-file exiftool spawn for MOV/RAF) is computed before the
dedup check and discarded for every already-imported file. That is most
of the measured 80s user CPU.

### C3. One batched exiftool call

Extend `scan_ratings` into `scan_metadata(files)` returning
`{path: (rating, timestamp)}`:

```
exiftool -@ - -j -d "%Y:%m:%d %H:%M:%S" -Rating# -DateTimeOriginal -CreateDate -MediaCreateDate
```

`-Rating#` gives a numeric rating without global `-n`, so `-d` still
formats dates. Pick the first parseable of
DateTimeOriginal/CreateDate/MediaCreateDate (same precedence as today's
`EXIFTOOL_DATE_TAGS`). Feed only media files. Per-file
`get_exiftool_timestamp` stays as a fallback for files missing from the
batch output; a failed batch degrades per-file, never aborts.
Ref: https://exiftool.org/exiftool_pod.html#Input-output-text-formatting

### C4. md5 via hashlib.file_digest

For the remaining standalone hashes (same-fs move fast path, dst
comparison, camera post-download mark): replace the 4096-byte-chunk loop
(import_from.py:805-810) with `hashlib.file_digest(f, "md5")`
(Python 3.11+; nixpkgs python3 is 3.13.12).
Ref: https://docs.python.org/3.13/library/hashlib.html#hashlib.file_digest

### C5. Index plus a single sqlite connection

- Schema: `CREATE INDEX IF NOT EXISTS file_imports_md5 ON
file_imports(md5);` (existing DBs pick it up on next run). Today every
  seen-check is a full table scan.
- Open one `sqlite3.connect` per command and pass the connection through
  instead of reconnecting per file. Keep the per-file `con.commit()`;
  that is the durability guarantee A1 step 4 relies on.

### C6. Minor

Build each group's file list once (dict of label to files) instead of
three `filter_files` passes per group.

## D. Packaging and docs

- `default.nix`: bump `version` (date-stamped scheme).
- This plan lives at `PLANNING.md` (repo root).

## Noted, no code needed

Concurrent runs produce benign suffix-duplicates, not loss. sqlite's
default rollback journal is power-safe for the DB itself. Zero-byte files
all share one md5 and dedupe together (by design). Filenames with
newlines or undecodable bytes degrade to the per-file exiftool fallback
and the per-file error guard.

## Verification

1. `python3 -m py_compile nix/pkgs/helios/*.py`, then build the package.
   `--help` no longer shows `--prune`/`--clobber`; shows `--force-hash`.
2. Scratch-dir end-to-end (`HELIOS_DB_PATH`/`HELIOS_LIBRARY_PATH` at
   scratch): import a tree with a JPEG (real EXIF), a `.mov`, a `.raf`, a
   `.hif`, a dangling symlink, and an unhandled `.xyz`. Expect: media in
   `_provisional/YYYY/...` (or `_unknown`), symlink warned and skipped,
   summary line lists `.xyz`, exit 0, `stat` shows source mtimes
   preserved, no `.part` files left.
3. Re-run with `--log-level DEBUG`: everything skips via the metadata
   check (no hashing, no exiftool), no duplicates. `--force-hash` skips
   via md5 instead. Real-world: `time helios import filesystem
/run/media/kyle/disk/` right after an import; baseline 3:54, expect
   seconds.
4. Crash recovery: delete a file's DB rows but leave its library copy;
   re-import; expect same-content detection, no `_md5suffix` dup, DB row
   restored. Kill the process mid-copy of a large file; expect only a
   `.part` temp (no canonical-name partial), clean re-run.
5. Guards: nonexistent src exits 1;
   `import filesystem $HELIOS_LIBRARY_PATH` refuses.
6. `sqlite3 $HELIOS_DB_PATH .schema`: md5 index and `filesystem_files`
   present.
7. Camera path: logic-reviewed; `helios import camera --help` works. If
   the X-T5 is handy: an import skips already-imported shots (A4 join),
   and a stale-cache warning appears after a simulated interrupted run.

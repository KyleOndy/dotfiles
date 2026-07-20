"""Session state management module.

This module provides the core state management for photo culling sessions,
including photo status tracking and session state.
"""

import bisect
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from PySide6.QtGui import QPixmap
from send2trash import send2trash

from winnow.core.image_cache import ImageCache

# RAW extensions whose sibling file should be deleted alongside a JPEG.
# Fuji writes uppercase .RAF; both cases are checked since some filesystems
# (ext4, most Linux) are case-sensitive. Extend this tuple to support other
# RAW formats.
RAW_EXTENSIONS = (".raf",)


def raw_siblings(jpeg_path: Path) -> list[Path]:
    """Find sibling RAW files for a JPEG, matched by filename stem.

    Fuji (and similar RAW+JPEG workflows) write a RAW file alongside the JPEG
    under the same base name in the same directory, e.g. DSCF1234.JPG next to
    DSCF1234.RAF. This checks both lowercase and uppercase forms of each known
    RAW extension and returns the ones that actually exist on disk.

    On a case-insensitive filesystem (e.g. macOS's default APFS), the
    lowercase and uppercase candidates for a given extension both exist and
    refer to the same on-disk file, so a naive existence check would return
    it twice - and later delete it twice. Results are deduped with
    Path.samefile() (device + inode comparison), which correctly identifies
    "same file on disk" regardless of *why* two path strings collide (case
    folding, a hard link, a bind mount, etc.), unlike comparing resolved path
    strings, which wouldn't reliably collapse a same-file-different-case pair.

    Args:
        jpeg_path: Path to the JPEG file to find RAW siblings for.

    Returns:
        List of existing sibling RAW paths (possibly empty), deduped.
    """
    siblings: list[Path] = []
    for ext in RAW_EXTENSIONS:
        for candidate_ext in (ext, ext.upper()):
            candidate = jpeg_path.with_suffix(candidate_ext)
            if not candidate.exists():
                continue
            if any(candidate.samefile(existing) for existing in siblings):
                continue
            siblings.append(candidate)
    return siblings


class PhotoStatus(Enum):
    """Enumeration of possible photo states during culling.

    Each photo can be in one of three states:
    - UNMARKED: Photo has not been evaluated yet (default state)
    - KEEPER: Photo has been marked as a keeper to retain
    - DELETE: Photo has been marked for deletion
    """

    UNMARKED = "unmarked"
    KEEPER = "keeper"
    DELETE = "delete"


@dataclass
class Session:
    """All session state - nothing persists between runs.

    This is the central state management for the photo culling application.
    It tracks all photos in the directory, their status (keeper/delete/unmarked),
    selection state, filter settings, and cached thumbnails.
    """

    directory: Path
    images: list[Path]

    # Photo status tracking
    keepers: set[Path] = field(default_factory=set)
    deletes: set[Path] = field(default_factory=set)

    # UI state
    selected: list[Path] = field(default_factory=list)

    # Filter state
    show_unmarked: bool = True
    show_keepers: bool = True
    show_deletes: bool = False  # Hide deleted photos by default

    # Thumbnail cache (in-memory only)
    thumbnails: dict[Path, QPixmap] = field(default_factory=dict)

    # Sharpness (focus) scores, populated asynchronously as photos decode -
    # see winnow.core.focus.sharpness_score. Higher is sharper. Purely
    # relative within this directory: there is no absolute "blurry"
    # threshold, so these are only used for sorting/ranking (sort_by_sharpness,
    # sharpness_bucket), never to auto-mark a photo.
    sharpness: dict[Path, float] = field(default_factory=dict)
    sort_by_sharpness: bool = False

    # Full-resolution image cache
    image_cache: ImageCache | None = None

    def __post_init__(self) -> None:
        """Initialize private cache state not part of the dataclass surface."""
        # Sorted snapshot of self.sharpness.values(), recomputed by
        # set_sharpness() and used to look up a score's rank via bisect
        # rather than re-sorting on every sharpness_bucket() call. Kept out
        # of the field list (and so out of __init__'s signature) since it's
        # derived, not caller-supplied state.
        self._sharpness_sorted: list[float] = []

    def get_status(self, path: Path) -> PhotoStatus:
        """Get the status of a photo.

        Args:
            path: Path to the photo file.

        Returns:
            PhotoStatus enum value (DELETE, KEEPER, or UNMARKED).
        """
        if path in self.deletes:
            return PhotoStatus.DELETE
        if path in self.keepers:
            return PhotoStatus.KEEPER
        return PhotoStatus.UNMARKED

    def set_status(self, path: Path, status: PhotoStatus) -> None:
        """Set the status of a photo.

        Removes the photo from other status sets and adds it to the
        appropriate set based on the new status.

        Args:
            path: Path to the photo file.
            status: New status to set (KEEPER, DELETE, or UNMARKED).
        """
        # Remove from other sets
        self.keepers.discard(path)
        self.deletes.discard(path)

        # Add to appropriate set
        if status == PhotoStatus.KEEPER:
            self.keepers.add(path)
        elif status == PhotoStatus.DELETE:
            self.deletes.add(path)

    def filtered_images(self) -> list[Path]:
        """Return images matching current filter settings.

        Filters the images list based on show_unmarked, show_keepers,
        and show_deletes flags, preserving the original order. When
        sort_by_sharpness is set, the filtered result is further sorted
        softest-first by sharpness score - this is the single chokepoint
        the thumbnail strip, navigate(), and gg/G all read from, so sorting
        here reorders the whole cull workflow at once.

        Returns:
            List of Path objects for photos matching filter criteria.
        """
        result = []
        for img in self.images:
            status = self.get_status(img)

            if status == PhotoStatus.DELETE and not self.show_deletes:
                continue
            if status == PhotoStatus.KEEPER and not self.show_keepers:
                continue
            if status == PhotoStatus.UNMARKED and not self.show_unmarked:
                continue

            result.append(img)

        if self.sort_by_sharpness:
            # list.sort is stable, so photos with equal (or no) score keep
            # their relative capture order - unscored photos (not yet
            # decoded, or scoring failed) sort as +inf and sink to the end
            # rather than being mistaken for the softest photos.
            result.sort(key=lambda p: self.sharpness.get(p, float("inf")))

        return result

    def count_deletes(self) -> int:
        """Count photos marked for deletion.

        Returns:
            Number of photos in the deletes set.
        """
        return len(self.deletes)

    def delete_marked_files(self) -> list[Path]:
        """Delete all files marked for deletion, along with any RAW siblings.

        Attempts to delete each file in the deletes set and, for each, any
        sibling RAW file found by raw_siblings(). If a file cannot be deleted
        (permission error, file not found, etc.), it is skipped and added to
        the failed list. The session state is not modified.

        On macOS, files are sent to the Trash (recoverable from Finder)
        instead of being permanently removed, since that's the platform's
        native expectation. Elsewhere, files are unlinked permanently.

        Returns:
            List of paths that failed to delete (empty if all succeeded).
        """
        failed = []
        for path in self.deletes:
            for target in (path, *raw_siblings(path)):
                try:
                    if sys.platform == "darwin":
                        send2trash(target)
                    else:
                        target.unlink()
                except OSError:
                    failed.append(target)
        return failed

    def count_raw_deletes(self) -> int:
        """Count RAW sibling files that will be deleted alongside marked photos.

        Returns:
            Total number of existing RAW siblings across all marked deletes.
        """
        return sum(len(raw_siblings(path)) for path in self.deletes)

    def set_sharpness(self, path: Path, score: float) -> None:
        """Record a photo's focus sharpness score.

        The single write path for sharpness scores - also refreshes the
        sorted snapshot sharpness_bucket() ranks against, so a bucket
        lookup is a binary search instead of a full re-sort of every known
        score on every call (a fresh directory scan reports a score per
        photo in a tight burst).

        Args:
            path: Path to the scored photo.
            score: Sharpness score from focus.sharpness_score (higher is
                sharper).
        """
        self.sharpness[path] = score
        self._sharpness_sorted = sorted(self.sharpness.values())

    def sharpness_bucket(self, path: Path) -> int | None:
        """Relative sharpness quartile for path: 0 (softest) to 3 (sharpest).

        Buckets photos by rank rather than by fixed score cutoffs, so the
        softest-scored photo is always bucket 0 and the sharpest-scored
        photo is always bucket 3 (a cutoff-based scheme has awkward off-by-
        one behavior right at the min/max). Relative to every currently-
        scored photo in this session - never an absolute threshold (see
        focus.sharpness_score) - so a photo's bucket can shift as more of
        the directory finishes decoding.

        Args:
            path: Path to the photo.

        Returns:
            0-3, or None if path has no recorded score yet.
        """
        score = self.sharpness.get(path)
        if score is None:
            return None
        rank = bisect.bisect_left(self._sharpness_sorted, score)
        return min(3, rank * 4 // len(self._sharpness_sorted))

    def get_full_image(self, path: Path) -> QPixmap | None:
        """Get full-resolution image from cache.

        Args:
            path: Path to the image file.

        Returns:
            Cached QPixmap if available, None otherwise.
        """
        if self.image_cache is None:
            return None
        return self.image_cache.get(path)

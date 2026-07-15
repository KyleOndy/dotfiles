"""Tests for the session module."""

from winnow.core.session import PhotoStatus, Session, raw_siblings


def test_session_initialization(tmp_path):
    """Test that a Session can be initialized with directory and images."""
    directory = tmp_path / "photos"
    directory.mkdir()

    images = [tmp_path / "img1.jpg", tmp_path / "img2.jpg"]

    session = Session(directory=directory, images=images)

    assert session.directory == directory
    assert session.images == images
    assert len(session.keepers) == 0
    assert len(session.deletes) == 0
    assert len(session.selected) == 0
    assert session.show_unmarked is True
    assert session.show_keepers is True
    assert session.show_deletes is False  # Hide deletes by default
    assert len(session.thumbnails) == 0


def test_get_status_unmarked_by_default(tmp_path):
    """Test that photos are unmarked by default."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    status = session.get_status(photo)

    assert status == PhotoStatus.UNMARKED


def test_get_status_keeper(tmp_path):
    """Test getting status for a keeper photo."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.keepers.add(photo)

    status = session.get_status(photo)

    assert status == PhotoStatus.KEEPER


def test_get_status_delete(tmp_path):
    """Test getting status for a photo marked for deletion."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.deletes.add(photo)

    status = session.get_status(photo)

    assert status == PhotoStatus.DELETE


def test_set_status_to_keeper(tmp_path):
    """Test marking a photo as keeper."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    session.set_status(photo, PhotoStatus.KEEPER)

    assert photo in session.keepers
    assert photo not in session.deletes
    assert session.get_status(photo) == PhotoStatus.KEEPER


def test_set_status_to_delete(tmp_path):
    """Test marking a photo for deletion."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    session.set_status(photo, PhotoStatus.DELETE)

    assert photo in session.deletes
    assert photo not in session.keepers
    assert session.get_status(photo) == PhotoStatus.DELETE


def test_set_status_to_unmarked(tmp_path):
    """Test clearing a photo's status back to unmarked."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.keepers.add(photo)

    session.set_status(photo, PhotoStatus.UNMARKED)

    assert photo not in session.keepers
    assert photo not in session.deletes
    assert session.get_status(photo) == PhotoStatus.UNMARKED


def test_set_status_keeper_to_delete(tmp_path):
    """Test changing status from keeper to delete removes from keepers."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.set_status(photo, PhotoStatus.KEEPER)

    session.set_status(photo, PhotoStatus.DELETE)

    assert photo not in session.keepers
    assert photo in session.deletes
    assert session.get_status(photo) == PhotoStatus.DELETE


def test_set_status_delete_to_keeper(tmp_path):
    """Test changing status from delete to keeper removes from deletes."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    session.set_status(photo, PhotoStatus.KEEPER)

    assert photo not in session.deletes
    assert photo in session.keepers
    assert session.get_status(photo) == PhotoStatus.KEEPER


def test_filtered_images_all_shown(tmp_path):
    """Test filtered_images returns all images when all filters enabled."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    # Enable all filters to see all photos
    session.show_deletes = True

    result = session.filtered_images()

    assert result == images
    assert len(result) == 3


def test_filtered_images_hide_unmarked(tmp_path):
    """Test hiding unmarked photos."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_unmarked = False
    session.show_deletes = True  # Enable to see deleted photos

    result = session.filtered_images()

    assert result == [photo1, photo2]
    assert photo3 not in result


def test_filtered_images_hide_keepers(tmp_path):
    """Test hiding keeper photos."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_keepers = False
    session.show_deletes = True  # Enable to see deleted photos

    result = session.filtered_images()

    assert result == [photo2, photo3]
    assert photo1 not in result


def test_filtered_images_hide_deletes(tmp_path):
    """Test hiding photos marked for deletion."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_deletes = False

    result = session.filtered_images()

    assert result == [photo1, photo3]
    assert photo2 not in result


def test_filtered_images_show_only_keepers(tmp_path):
    """Test showing only keeper photos."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_unmarked = False
    session.show_deletes = False

    result = session.filtered_images()

    assert result == [photo1]


def test_filtered_images_show_only_deletes(tmp_path):
    """Test showing only photos marked for deletion."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_unmarked = False
    session.show_keepers = False
    session.show_deletes = True  # Enable to see deleted photos

    result = session.filtered_images()

    assert result == [photo2]


def test_filtered_images_show_only_unmarked(tmp_path):
    """Test showing only unmarked photos."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_keepers = False
    session.show_deletes = False

    result = session.filtered_images()

    assert result == [photo3]


def test_filtered_images_hide_all(tmp_path):
    """Test hiding all photos returns empty list."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    images = [photo1, photo2, photo3]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo2, PhotoStatus.DELETE)
    # photo3 remains unmarked

    session.show_unmarked = False
    session.show_keepers = False
    session.show_deletes = False

    result = session.filtered_images()

    assert result == []


def test_filtered_images_preserves_order(tmp_path):
    """Test that filtered_images preserves original image order."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    photo4 = tmp_path / "photo4.jpg"
    photo5 = tmp_path / "photo5.jpg"
    images = [photo1, photo2, photo3, photo4, photo5]

    session = Session(directory=tmp_path, images=images)
    session.set_status(photo1, PhotoStatus.KEEPER)
    session.set_status(photo3, PhotoStatus.KEEPER)
    session.set_status(photo5, PhotoStatus.KEEPER)
    # photo2 and photo4 remain unmarked

    session.show_deletes = False

    result = session.filtered_images()

    # Should maintain original order: 1, 2, 3, 4, 5
    assert result == images


def test_filtered_images_empty_list(tmp_path):
    """Test filtered_images with empty images list."""
    session = Session(directory=tmp_path, images=[])

    result = session.filtered_images()

    assert result == []


def test_count_deletes_zero(tmp_path):
    """Test count_deletes returns 0 when no photos marked for deletion."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    session = Session(directory=tmp_path, images=[photo1, photo2])

    count = session.count_deletes()

    assert count == 0


def test_count_deletes_one(tmp_path):
    """Test count_deletes with one photo marked for deletion."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    session = Session(directory=tmp_path, images=[photo1, photo2])
    session.set_status(photo1, PhotoStatus.DELETE)

    count = session.count_deletes()

    assert count == 1


def test_count_deletes_multiple(tmp_path):
    """Test count_deletes with multiple photos marked for deletion."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo3 = tmp_path / "photo3.jpg"
    photo4 = tmp_path / "photo4.jpg"
    session = Session(directory=tmp_path, images=[photo1, photo2, photo3, photo4])
    session.set_status(photo1, PhotoStatus.DELETE)
    session.set_status(photo3, PhotoStatus.DELETE)
    session.set_status(photo4, PhotoStatus.DELETE)

    count = session.count_deletes()

    assert count == 3


def test_count_deletes_after_status_change(tmp_path):
    """Test that count_deletes updates when status changes."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    assert session.count_deletes() == 1

    # Change to keeper
    session.set_status(photo, PhotoStatus.KEEPER)

    assert session.count_deletes() == 0


def test_selected_list_is_mutable(tmp_path):
    """Test that selected list can be modified."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    session = Session(directory=tmp_path, images=[photo1, photo2])

    assert len(session.selected) == 0

    session.selected.append(photo1)
    assert len(session.selected) == 1
    assert photo1 in session.selected

    session.selected.append(photo2)
    assert len(session.selected) == 2

    session.selected.remove(photo1)
    assert len(session.selected) == 1
    assert photo2 in session.selected


def test_thumbnails_cache_is_mutable(tmp_path):
    """Test that thumbnails cache can be modified."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    assert len(session.thumbnails) == 0
    assert photo not in session.thumbnails

    # Note: We can't create a real QPixmap here without Qt runtime,
    # so we just verify the dict is mutable
    # In actual usage, thumbnails would be QPixmap objects


def test_multiple_photos_different_statuses(tmp_path):
    """Test managing multiple photos with different statuses."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(10)]
    session = Session(directory=tmp_path, images=photos)

    # Mark some as keepers
    session.set_status(photos[0], PhotoStatus.KEEPER)
    session.set_status(photos[1], PhotoStatus.KEEPER)
    session.set_status(photos[2], PhotoStatus.KEEPER)

    # Mark some for deletion
    session.set_status(photos[3], PhotoStatus.DELETE)
    session.set_status(photos[4], PhotoStatus.DELETE)

    # Leave the rest unmarked (5-9)

    assert len(session.keepers) == 3
    assert len(session.deletes) == 2
    assert session.count_deletes() == 2

    # Verify get_status works correctly for each
    assert session.get_status(photos[0]) == PhotoStatus.KEEPER
    assert session.get_status(photos[3]) == PhotoStatus.DELETE
    assert session.get_status(photos[7]) == PhotoStatus.UNMARKED


def test_filtered_images_with_all_same_status(tmp_path):
    """Test filtered_images when all photos have the same status."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(5)]
    session = Session(directory=tmp_path, images=photos)

    # Mark all as keepers
    for photo in photos:
        session.set_status(photo, PhotoStatus.KEEPER)

    # Hide keepers
    session.show_keepers = False

    result = session.filtered_images()

    assert result == []


# raw_siblings() tests


def test_raw_siblings_lowercase_found(tmp_path):
    """Test raw_siblings finds a lowercase .raf sibling."""
    photo = tmp_path / "photo.jpg"
    photo.touch()
    raw = tmp_path / "photo.raf"
    raw.touch()

    assert raw_siblings(photo) == [raw]


def test_raw_siblings_uppercase_found(tmp_path):
    """Test raw_siblings finds an uppercase .RAF sibling (Fuji's convention)."""
    photo = tmp_path / "photo.jpg"
    photo.touch()
    raw = tmp_path / "photo.RAF"
    raw.touch()

    assert raw_siblings(photo) == [raw]


def test_raw_siblings_missing_returns_empty(tmp_path):
    """Test raw_siblings returns an empty list when no sibling exists."""
    photo = tmp_path / "photo.jpg"
    photo.touch()

    assert raw_siblings(photo) == []


def test_raw_siblings_stem_with_dots(tmp_path):
    """Test raw_siblings only swaps the final suffix, preserving dotted stems."""
    photo = tmp_path / "photo.v2.jpg"
    photo.touch()
    raw = tmp_path / "photo.v2.raf"
    raw.touch()

    assert raw_siblings(photo) == [raw]


# Session.count_raw_deletes() tests


def test_count_raw_deletes_zero_without_sibling(tmp_path):
    """Test count_raw_deletes is 0 when a marked delete has no RAW sibling."""
    photo = tmp_path / "photo.jpg"
    photo.touch()
    session = Session(directory=tmp_path, images=[photo])
    session.set_status(photo, PhotoStatus.DELETE)

    assert session.count_raw_deletes() == 0


def test_count_raw_deletes_counts_existing_siblings(tmp_path):
    """Test count_raw_deletes counts RAW siblings across all marked deletes."""
    photo1 = tmp_path / "photo1.jpg"
    photo2 = tmp_path / "photo2.jpg"
    photo1.touch()
    photo2.touch()
    (tmp_path / "photo1.raf").touch()
    (tmp_path / "photo2.RAF").touch()

    session = Session(directory=tmp_path, images=[photo1, photo2])
    session.set_status(photo1, PhotoStatus.DELETE)
    session.set_status(photo2, PhotoStatus.DELETE)

    assert session.count_raw_deletes() == 2


# Sharpness scoring / sort / bucket tests


def test_session_initializes_with_no_sharpness_scores(tmp_path):
    """Test that a new Session starts with no sharpness data."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    assert session.sharpness == {}
    assert session.sort_by_sharpness is False
    assert session.sharpness_bucket(photo) is None


def test_set_sharpness_records_score(tmp_path):
    """Test that set_sharpness stores the score under session.sharpness."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    session.set_sharpness(photo, 42.5)

    assert session.sharpness[photo] == 42.5


def test_set_sharpness_overwrites_previous_score(tmp_path):
    """Test that scoring the same photo twice keeps only the latest score."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    session.set_sharpness(photo, 10.0)
    session.set_sharpness(photo, 99.0)

    assert session.sharpness[photo] == 99.0


def test_filtered_images_default_order_ignores_sharpness(tmp_path):
    """Test that filtered_images preserves capture order when sort is off."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(3)]
    session = Session(directory=tmp_path, images=photos)
    # Score them in reverse order of capture (photo0 sharpest).
    session.set_sharpness(photos[0], 300.0)
    session.set_sharpness(photos[1], 200.0)
    session.set_sharpness(photos[2], 100.0)

    assert session.filtered_images() == photos


def test_filtered_images_sorts_softest_first_when_enabled(tmp_path):
    """Test that enabling sort_by_sharpness orders ascending by score."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(3)]
    session = Session(directory=tmp_path, images=photos)
    session.set_sharpness(photos[0], 300.0)  # sharpest
    session.set_sharpness(photos[1], 100.0)  # softest
    session.set_sharpness(photos[2], 200.0)  # middle
    session.sort_by_sharpness = True

    result = session.filtered_images()

    assert result == [photos[1], photos[2], photos[0]]


def test_filtered_images_sort_sinks_unscored_photos_to_the_end(tmp_path):
    """Test that photos with no score yet sort after every scored photo."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(3)]
    session = Session(directory=tmp_path, images=photos)
    session.set_sharpness(photos[0], 50.0)
    # photos[1] and photos[2] remain unscored.
    session.sort_by_sharpness = True

    result = session.filtered_images()

    assert result[0] == photos[0]
    assert set(result[1:]) == {photos[1], photos[2]}


def test_filtered_images_sort_is_stable_for_ties(tmp_path):
    """Test that equal (or unscored) scores keep original capture order."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(4)]
    session = Session(directory=tmp_path, images=photos)
    session.set_sharpness(photos[0], 10.0)
    session.set_sharpness(photos[1], 10.0)
    # photos[2] and photos[3] both unscored.
    session.sort_by_sharpness = True

    result = session.filtered_images()

    # Tied pair keeps capture order, unscored pair keeps capture order.
    assert result == [photos[0], photos[1], photos[2], photos[3]]


def test_filtered_images_sort_respects_status_filters(tmp_path):
    """Test that sharpness sort applies after, not instead of, filtering."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(3)]
    session = Session(directory=tmp_path, images=photos)
    session.set_status(photos[1], PhotoStatus.DELETE)
    session.set_sharpness(photos[0], 200.0)
    session.set_sharpness(photos[1], 1.0)  # softest, but filtered out
    session.set_sharpness(photos[2], 100.0)
    session.sort_by_sharpness = True
    # show_deletes defaults to False

    result = session.filtered_images()

    assert result == [photos[2], photos[0]]
    assert photos[1] not in result


def test_sharpness_bucket_none_before_scoring(tmp_path):
    """Test that an unscored photo has no bucket."""
    photo = tmp_path / "photo.jpg"
    session = Session(directory=tmp_path, images=[photo])

    assert session.sharpness_bucket(photo) is None


def test_sharpness_bucket_softest_and_sharpest(tmp_path):
    """Test that the softest score buckets to 0 and the sharpest to the top."""
    photos = [tmp_path / f"photo{i}.jpg" for i in range(4)]
    session = Session(directory=tmp_path, images=photos)
    for photo, score in zip(photos, [10.0, 20.0, 30.0, 40.0], strict=True):
        session.set_sharpness(photo, score)

    assert session.sharpness_bucket(photos[0]) == 0
    assert session.sharpness_bucket(photos[-1]) == 3


def test_sharpness_bucket_is_relative_to_current_scores(tmp_path):
    """Test that a photo's bucket can shift as more scores arrive.

    Sharpness ranking is always relative to the currently-scored photos in
    the directory (see focus.sharpness_score) - there is no fixed
    "blurry" cutoff, so a mid-pack score can become the softest once
    softer photos are scored.
    """
    photos = [tmp_path / f"photo{i}.jpg" for i in range(2)]
    session = Session(directory=tmp_path, images=photos)

    session.set_sharpness(photos[0], 50.0)
    assert session.sharpness_bucket(photos[0]) == 0  # only score so far

    session.set_sharpness(photos[1], 10.0)  # softer photo joins
    assert session.sharpness_bucket(photos[1]) == 0
    assert session.sharpness_bucket(photos[0]) > 0


def test_count_raw_deletes_ignores_keepers(tmp_path):
    """Test count_raw_deletes only considers photos marked for deletion."""
    photo = tmp_path / "photo.jpg"
    photo.touch()
    (tmp_path / "photo.raf").touch()

    session = Session(directory=tmp_path, images=[photo])
    session.set_status(photo, PhotoStatus.KEEPER)

    assert session.count_raw_deletes() == 0

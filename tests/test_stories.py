from ailbum.stories import StoryPhoto, detect_stories


def _photo(
    photo_id: str,
    taken_at: str,
    *,
    embedding: tuple[float, ...] | None = None,
    people: frozenset[str] = frozenset(),
    scenes: tuple[tuple[str, float], ...] = (),
    latitude: float | None = None,
    longitude: float | None = None,
) -> StoryPhoto:
    return StoryPhoto(
        photo_id=photo_id,
        taken_at=taken_at,
        embedding=embedding,
        people=people,
        scenes=scenes,
        gps_latitude=latitude,
        gps_longitude=longitude,
        quality=0.8,
    )


def test_sharp_visual_change_splits_nearby_photos() -> None:
    stories = detect_stories(
        [
            _photo("inside-1", "2026-08-07T10:00:00", embedding=(1, 0, 0, 0)),
            _photo("inside-2", "2026-08-07T10:02:00", embedding=(0.99, 0.01, 0, 0)),
            _photo("outside-1", "2026-08-07T10:12:00", embedding=(0, 1, 0, 0)),
            _photo("outside-2", "2026-08-07T10:14:00", embedding=(0.01, 0.99, 0, 0)),
        ]
    )

    assert [story.photo_ids for story in stories] == [
        ["inside-1", "inside-2"],
        ["outside-1", "outside-2"],
    ]


def test_same_visual_activity_bridges_long_pause() -> None:
    stories = detect_stories(
        [
            _photo("morning", "2026-08-07T09:00:00", embedding=(1, 0, 0)),
            _photo("afternoon", "2026-08-07T12:00:00", embedding=(1, 0, 0)),
        ]
    )

    assert len(stories) == 1


def test_single_visual_outlier_does_not_fragment_a_sequence() -> None:
    stories = detect_stories(
        [
            _photo("a1", "2026-08-07T10:00:00", embedding=(1, 0, 0)),
            _photo("a2", "2026-08-07T10:02:00", embedding=(1, 0, 0)),
            _photo("outlier", "2026-08-07T10:04:00", embedding=(0, 1, 0)),
            _photo("a3", "2026-08-07T10:06:00", embedding=(1, 0, 0)),
            _photo("a4", "2026-08-07T10:08:00", embedding=(1, 0, 0)),
        ]
    )

    assert len(stories) == 1


def test_unreadable_photo_inherits_temporal_context() -> None:
    stories = detect_stories(
        [
            _photo("first", "2026-08-07T10:00:00", embedding=(1, 0, 0)),
            _photo("unreadable", "2026-08-07T10:02:00"),
            _photo("last", "2026-08-07T10:04:00", embedding=(1, 0, 0)),
        ]
    )

    assert len(stories) == 1
    assert stories[0].photo_ids == ["first", "unreadable", "last"]


def test_label_names_do_not_control_grouping() -> None:
    stories = detect_stories(
        [
            _photo(
                "first",
                "2026-08-07T10:00:00",
                embedding=(1, 0, 0),
                scenes=(("arbitrary-a", 1.0),),
            ),
            _photo(
                "second",
                "2026-08-07T10:02:00",
                embedding=(1, 0, 0),
                scenes=(("arbitrary-b", 1.0),),
            ),
        ]
    )

    assert len(stories) == 1


def test_large_geographic_jump_splits_close_photos() -> None:
    stories = detect_stories(
        [
            _photo(
                "home",
                "2026-08-07T10:00:00",
                embedding=(1, 0),
                latitude=56.8389,
                longitude=60.6057,
            ),
            _photo(
                "away",
                "2026-08-07T10:45:00",
                embedding=(1, 0),
                latitude=55.7558,
                longitude=37.6173,
            ),
        ]
    )

    assert [story.photo_ids for story in stories] == [["home"], ["away"]]


def test_continuity_limit_forces_a_new_story() -> None:
    stories = detect_stories(
        [
            _photo("first", "2026-08-07T10:00:00", embedding=(1, 0)),
            _photo("second", "2026-08-07T17:00:00", embedding=(1, 0)),
        ]
    )

    assert [story.photo_ids for story in stories] == [["first"], ["second"]]


def test_mixed_timezone_metadata_uses_local_camera_time() -> None:
    stories = detect_stories(
        [
            _photo("phone", "2026-07-30T09:41:00+03:00", embedding=(1, 0)),
            _photo("camera", "2026-07-30T10:00:00", embedding=(1, 0)),
        ]
    )

    assert len(stories) == 1
    assert stories[0].photo_ids == ["phone", "camera"]


def test_rule_title_is_only_a_top_label_fallback() -> None:
    story = detect_stories(
        [
            _photo(
                "hookah",
                "2026-08-03T21:40:00",
                embedding=(1, 0),
                scenes=(("hookah", 0.99), ("performance", 0.5)),
            )
        ]
    )[0]

    assert story.title == "Отдых с кальяном"


def test_story_without_semantics_gets_dated_fallback_not_event() -> None:
    story = detect_stories(
        [_photo("photo", "2026-08-03T12:34:00", embedding=(1, 0))]
    )[0]

    assert story.title == "Фотографии 03.08, 12:34"

from ailbum.stories import StoryPhoto, detect_stories


def _photo(
    photo_id: str,
    taken_at: str,
    *,
    people: frozenset[str] = frozenset(),
    scenes: tuple[tuple[str, float], ...] = (),
    objects: tuple[tuple[str, float], ...] = (),
    latitude: float | None = None,
    longitude: float | None = None,
) -> StoryPhoto:
    return StoryPhoto(
        photo_id=photo_id,
        taken_at=taken_at,
        people=people,
        scenes=scenes,
        objects=objects,
        gps_latitude=latitude,
        gps_longitude=longitude,
        quality=0.8,
    )


def test_story_can_cross_midnight_and_uses_specific_semantic_title() -> None:
    stories = detect_stories(
        [
            _photo(
                "before",
                "2026-08-07T23:45:00",
                scenes=(("beach", 0.8), ("night", 0.7)),
            ),
            _photo(
                "after",
                "2026-08-08T00:20:00",
                scenes=(("beach", 0.7), ("night", 0.8)),
            ),
        ]
    )

    assert len(stories) == 1
    assert stories[0].photo_ids == ["before", "after"]
    assert stories[0].title == "Ночной пляж"


def test_people_bridge_a_long_pause_but_not_the_continuity_limit() -> None:
    person = frozenset({"person:1"})
    stories = detect_stories(
        [
            _photo("first", "2026-08-07T10:00:00", people=person),
            _photo("second", "2026-08-07T13:00:00", people=person),
            _photo("third", "2026-08-07T20:00:00", people=person),
        ]
    )

    assert [story.photo_ids for story in stories] == [["first", "second"], ["third"]]
    assert stories[0].title == "Совместный отдых"


def test_large_geographic_jump_splits_close_photos() -> None:
    stories = detect_stories(
        [
            _photo(
                "home",
                "2026-08-07T10:00:00",
                latitude=56.8389,
                longitude=60.6057,
            ),
            _photo(
                "away",
                "2026-08-07T10:45:00",
                latitude=55.7558,
                longitude=37.6173,
            ),
        ]
    )

    assert [story.photo_ids for story in stories] == [["home"], ["away"]]


def test_semantic_change_splits_meal_from_night_beach_session() -> None:
    stories = detect_stories(
        [
            _photo("meal", "2026-07-28T19:27:00", scenes=(("food", 0.7),)),
            _photo(
                "beach-1",
                "2026-07-28T20:27:00",
                scenes=(("beach", 0.8), ("night", 0.2)),
                objects=(("people", 0.6),),
            ),
            _photo(
                "beach-2",
                "2026-07-28T20:50:00",
                scenes=(("night", 0.9), ("beach", 0.5)),
                objects=(("people", 0.5),),
            ),
            _photo(
                "beach-3",
                "2026-07-28T20:54:00",
                scenes=(("night", 0.8), ("beach", 0.5)),
                objects=(("people", 0.5),),
            ),
        ]
    )

    assert [story.photo_ids for story in stories] == [
        ["meal"],
        ["beach-1", "beach-2", "beach-3"],
    ]
    assert stories[1].title == "Ночная фотосессия на пляже"

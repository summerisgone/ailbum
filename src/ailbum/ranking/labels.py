from __future__ import annotations

EXPLICIT = ("manual", "backfill")


def group_pairs(
    events: list[dict], final: set[int], groups: dict[int, list[int]]
) -> list[tuple[int, int]]:
    """(winner, loser) pairs from groups where the user touched a member; winners are in the final album."""
    touched = {e["image_id"] for e in events if e.get("source") in EXPLICIT}
    pairs = []
    for members in groups.values():
        if len(members) < 2 or touched.isdisjoint(members):
            continue
        winners = sorted(m for m in members if m in final)
        losers = sorted(m for m in members if m not in final)
        pairs.extend((w, l) for w in winners for l in losers)
    return pairs

import Foundation

public enum RankingLabels {
    public static let explicit = ["manual", "backfill"]

    /// (winner, loser) pairs from groups where the user touched a member; winners are in the final album.
    public static func groupPairs(events: [JSONValue], final: Set<Int>, groups: [Int: [Int]]) -> [(Int, Int)] {
        var touched = Set<Int>()
        for e in events {
            if case .string(let s)? = e["source"], explicit.contains(s), case .int(let id)? = e["image_id"] {
                touched.insert(id)
            }
        }
        var pairs: [(Int, Int)] = []
        for key in groups.keys.sorted() {
            let members = groups[key]!
            if members.count < 2 || touched.isDisjoint(with: members) { continue }
            let winners = members.filter { final.contains($0) }.sorted()
            let losers = members.filter { !final.contains($0) }.sorted()
            for w in winners { for l in losers { pairs.append((w, l)) } }
        }
        return pairs
    }
}

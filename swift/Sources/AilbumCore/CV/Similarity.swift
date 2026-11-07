import Foundation

public enum Similarity {
    static let prefilterHashDistance = 24
    static let prefilterHistogramSimilarity: Float = 0.65

    public static func geometric(_ left: GeometricFeatures?, _ right: GeometricFeatures?) throws -> GeometricSimilarity {
        guard let left, let right, left.keypoints.count >= 2, right.keypoints.count >= 2,
              left.descriptors.count >= 2 * 128, right.descriptors.count >= 2 * 128 else { return .empty }
        let dim = 128
        let mutual = try Matcher.mutualRatioMatches(left: left.descriptors, right: right.descriptors, dim: dim, ratio: 0.75)
        if mutual.count < 4 {
            return GeometricSimilarity(score: 0, mutualMatches: mutual.count, inliers: 0, inlierRatio: 0,
                                       coverageLeft: 0, coverageRight: 0)
        }
        let lp = mutual.map { left.keypoints[$0.0] }
        let rp = mutual.map { right.keypoints[$0.1] }
        guard let mask = Homography.ransacInliers(lp, rp, threshold: 4.0, seed: 0x5EED) else {
            return GeometricSimilarity(score: 0, mutualMatches: mutual.count, inliers: 0, inlierRatio: 0,
                                       coverageLeft: 0, coverageRight: 0)
        }
        let inliers = mask.filter { $0 }.count
        let ratio = Double(inliers) / Double(mutual.count)
        let covL = Hull.coverage(zip(mask, lp).filter { $0.0 }.map { $0.1 }, width: left.width, height: left.height)
        let covR = Hull.coverage(zip(mask, rp).filter { $0.0 }.map { $0.1 }, width: right.width, height: right.height)
        let support = 1.0 - exp(-Double(inliers) / 80.0)
        let coverage = (min(covL / 0.25, 1.0) * min(covR / 0.25, 1.0)).squareRoot()
        return GeometricSimilarity(score: support * ratio * coverage, mutualMatches: mutual.count, inliers: inliers,
                                   inlierRatio: ratio, coverageLeft: covL, coverageRight: covR)
    }

    public static func isGeometricCandidate(hash: Int, color: Float) -> Bool {
        hash <= prefilterHashDistance || color >= prefilterHistogramSimilarity
    }

    public static func cluster(_ photos: [PhotoFeatures], hashDistance: Int, histogramThreshold: Float,
                               geometricThreshold: Float? = 0.55, captureTimes: [String?]? = nil,
                               neighborWindow: Int = 12, timeWindowMinutes: Int = 15) throws -> [[Int]] {
        guard neighborWindow >= 1 else { throw AilbumError.decode("Geometric neighbor window must be positive") }
        guard timeWindowMinutes >= 1 else { throw AilbumError.decode("Geometric time window must be positive") }
        if let captureTimes, captureTimes.count != photos.count {
            throw AilbumError.decode("Capture times must match the number of photo features")
        }
        let timestamps: [Double?]? = captureTimes.flatMap { $0.isEmpty ? nil : $0.map(timestamp) }
        var groups = UnionFind(size: photos.count)
        for l in 0..<photos.count {
            for r in (l + 1)..<max(photos.count, l + 1) {
                let hash = HashColor.hamming(photos[l].phash, photos[r].phash)
                let color = HashColor.similarity(photos[l].histogram, photos[r].histogram)
                if hash <= hashDistance && color >= histogramThreshold {
                    groups.union(l, r)
                    continue
                }
                guard let geometricThreshold, isGeometricCandidate(hash: hash, color: color) else { continue }
                guard withinWindow(l, r, timestamps, neighborWindow, timeWindowMinutes) else { continue }
                let g = try geometric(photos[l].geometric, photos[r].geometric)
                if Float(g.score) >= geometricThreshold { groups.union(l, r) }
            }
        }
        return groups.components()
    }

    static func withinWindow(_ l: Int, _ r: Int, _ ts: [Double?]?, _ window: Int, _ minutes: Int) -> Bool {
        if r - l <= window { return true }
        guard let ts, let a = ts[l], let b = ts[r] else { return false }
        return abs(b - a) <= Double(minutes * 60)
    }

    static func timestamp(_ value: String?) -> Double? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts
            if let d = iso.date(from: value) { return d.timeIntervalSince1970 }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: value) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}

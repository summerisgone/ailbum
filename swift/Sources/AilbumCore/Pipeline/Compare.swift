import Foundation

public enum Compare {
    public static func images(
        left: String, right: String, hashDistance: Int = 12, histogramThreshold: Double = 0.72,
        geometricThreshold: Double = 0.55, geometricMaxFeatures: Int = 4000, maxImageSide: Int = 1600
    ) throws -> JSONValue {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        let started = now()
        let leftImage = try ImageLoader.load(path: left)
        let rightImage = try ImageLoader.load(path: right)
        let loaded = now()

        let leftHC = HashColor.features(leftImage)
        let rightHC = HashColor.features(rightImage)
        let hashExtracted = now()

        let leftGeo = try SIFT.extract(leftImage, maxFeatures: geometricMaxFeatures, maxSide: maxImageSide)
        let rightGeo = try SIFT.extract(rightImage, maxFeatures: geometricMaxFeatures, maxSide: maxImageSide)
        let geoExtracted = now()

        let hashValue = HashColor.hamming(leftHC.phash, rightHC.phash)
        let colorValue = Double(HashColor.similarity(leftHC.histogram, rightHC.histogram))
        let hashCompared = now()
        let geometric = try Similarity.geometric(leftGeo, rightGeo)
        let geoCompared = now()

        let hashColorMatch = hashValue <= hashDistance && colorValue >= histogramThreshold
        let geometricMatch = geometric.score >= geometricThreshold
        var matchedBy: [JSONValue] = []
        if hashColorMatch { matchedBy.append("hash_color") }
        if geometricMatch { matchedBy.append("geometric_scene_overlap") }

        return [
            "left": describe(left, leftImage, leftGeo),
            "right": describe(right, rightImage, rightGeo),
            "thresholds": [
                "hash_distance": .int(hashDistance),
                "histogram_similarity": .double(histogramThreshold),
                "geometric_scene_overlap": .double(geometricThreshold),
            ],
            "hash_color": [
                "hash_distance": .int(hashValue),
                "color_similarity": .double(round4(colorValue)),
                "similar": .bool(hashColorMatch),
            ],
            "geometric_scene_overlap": [
                "score": .double(round4(geometric.score)),
                "mutual_matches": .int(geometric.mutualMatches),
                "inliers": .int(geometric.inliers),
                "inlier_ratio": .double(round4(geometric.inlierRatio)),
                "coverage_left": .double(round4(geometric.coverageLeft)),
                "coverage_right": .double(round4(geometric.coverageRight)),
                "similar": .bool(geometricMatch),
            ],
            "similar": .bool(hashColorMatch || geometricMatch),
            "matched_by": .array(matchedBy),
            "timing_ms": [
                "load_images": .double(ms(started, loaded)),
                "extract_hash_color": .double(ms(loaded, hashExtracted)),
                "extract_geometric": .double(ms(hashExtracted, geoExtracted)),
                "compare_hash_color": .double(ms(geoExtracted, hashCompared)),
                "compare_geometric": .double(ms(hashCompared, geoCompared)),
            ],
        ]
    }

    private static func describe(_ path: String, _ image: RGBImage, _ geometric: GeometricFeatures) -> JSONValue {
        let orientation = image.width > image.height ? "landscape" : image.height > image.width ? "portrait" : "square"
        return [
            "path": .string(URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
            "width": .int(image.width),
            "height": .int(image.height),
            "orientation": .string(orientation),
            "geometric_features": .int(geometric.keypoints.count),
        ]
    }

    private static func round4(_ v: Double) -> Double { (v * 10_000).rounded(.toNearestOrEven) / 10_000 }

    private static func ms(_ start: UInt64, _ end: UInt64) -> Double {
        (Double(end - start) / 1e6 * 1000).rounded(.toNearestOrEven) / 1000
    }
}

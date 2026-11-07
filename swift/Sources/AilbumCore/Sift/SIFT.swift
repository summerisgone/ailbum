public enum SIFT {
    public static func extract(_ image: RGBImage, maxFeatures: Int = 4000, maxSide: Int = 1600) throws -> GeometricFeatures {
        let (resized, _) = Resize.forAnalysis(image, maxSide: maxSide)
        let gray = ScaleSpace.grayFloat(resized)
        let space = try ScaleSpace.build(gray, layers: 3, sigma: 1.6)
        let found = SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10)
        let oriented = SiftDetector.assignOrientations(found, space: space)
        let kept = SiftDetector.retainBest(oriented, maxFeatures: maxFeatures)
        let descriptors = SiftDescriptor.compute(kept, space: space)
        return GeometricFeatures(keypoints: kept.map { SIMD2($0.x, $0.y) }, descriptors: descriptors,
                                 width: resized.width, height: resized.height)
    }
}

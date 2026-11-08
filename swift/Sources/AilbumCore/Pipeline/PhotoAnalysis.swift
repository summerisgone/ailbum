import Foundation

public enum PhotoAnalysis {
    public static func faceBackend(_ requested: String) throws -> String {
        let ready = ModelStore.available("yunet") && ModelStore.available("sface")
        switch requested {
        case "auto": return ready ? "dnn" : "off"
        case "classic", "off": return "off"
        case "dnn":
            guard ready else {
                throw AilbumError.invalid(
                    "DNN face models were not found in \(ModelStore.modelsDir.path). "
                        + "Run `ailbum download-models` first.")
            }
            return "dnn"
        default:
            throw AilbumError.invalid("Unsupported face backend: \(requested)")
        }
    }

    public static func semanticBackend(_ requested: String) throws -> String {
        switch requested {
        case "off": return "off"
        case "clip": return "clip"
        case "auto":
            let text = Clip.textOverride != nil
                || FileManager.default.fileExists(
                    atPath: ModelStore.modelsDir.appendingPathComponent("clip_text.json").path)
            return ModelStore.available("clip_vision") && text ? "clip" : "off"
        default:
            throw AilbumError.invalid("Unsupported semantic backend: \(requested)")
        }
    }

    public static func analyze(
        path: String, photoId: String, takenAt: String?, config: PipelineConfig, faceBackend: String
    ) throws -> (record: PhotoRecord, features: PhotoFeatures, preview: RGBImage) {
        let image = try ImageLoader.load(path: path)
        let analysisImage = Resize.forAnalysis(image, maxSide: config.maxImageSide).0
        let preview = Resize.forAnalysis(image, maxSide: 800).0
        let similarityPreview = Resize.forAnalysis(image, maxSide: 256).0
        let sharpness = try Quality.sharpness(analysisImage, maxSide: config.maxImageSide)
        let exposure = Quality.exposure(preview, maxSide: 800)
        var record = PhotoRecord(
            photoId: photoId,
            path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            width: image.width, height: image.height, takenAt: takenAt,
            sharpness: round(sharpness * 1000) / 1000,
            exposure: round(exposure * 10000) / 10000,
            quality: round(Quality.score(sharpness: sharpness, exposure: exposure) * 10000) / 10000,
            isBlurry: sharpness < config.sharpnessThreshold)
        let hc = HashColor.features(similarityPreview)
        var geometric: GeometricFeatures?
        if config.photoGeometricSimilarity != nil {
            geometric = try SIFT.extract(
                analysisImage, maxFeatures: config.geometricMaxFeatures, maxSide: config.maxImageSide)
        }
        let features = PhotoFeatures(phash: hc.phash, histogram: hc.histogram, geometric: geometric)
        if faceBackend == "dnn" {
            let found = try FaceAnalyzer.analyze(
                image, minFaceSize: config.minFaceSize, minAttributeFaceSize: config.minAttributeFaceSize)
            for (offset, analysis) in found.enumerated() {
                let a = analysis.attributes
                var eyes: EyeStateRecord?
                if a.leftEye != nil || a.rightEye != nil {
                    eyes = EyeStateRecord(
                        left: a.leftEye, right: a.rightEye,
                        leftOpenProbability: a.leftEyeOpenProbability,
                        rightOpenProbability: a.rightEyeOpenProbability, bothOpen: a.bothEyesOpen)
                }
                var expression: ExpressionRecord?
                if let label = a.expression, let confidence = a.expressionConfidence,
                    let scores = a.expressionScores, let smile = a.smileProbability {
                    expression = ExpressionRecord(
                        label: label, confidence: confidence, smileProbability: smile, scores: scores)
                }
                let b = analysis.detection.bbox
                record.faces.append(
                    FaceRecord(
                        faceId: "\(photoId)-face-\(String(format: "%02d", offset + 1))",
                        bbox: SIMD4(b.x, b.y, b.w, b.h),
                        confidence: round(Double(analysis.detection.confidence) * 10000) / 10000,
                        embedding: analysis.embedding, eyes: eyes, expression: expression))
            }
        }
        record.composition = Aesthetics.composition(
            preview, faceBoxes: record.faces.map { $0.bbox }, maxSide: 800)
        record.color = Aesthetics.color(preview, maxSide: 800)
        return (record, features, preview)
    }
}

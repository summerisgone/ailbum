public typealias FaceAnalysis = (detection: FaceDetection, embedding: [Float], attributes: FaceAttributes)

public enum FaceAnalyzer {
    public static func analyze(
        _ image: RGBImage, minFaceSize: Int = 40, minAttributeFaceSize: Int = 64
    ) throws -> [(detection: FaceDetection, embedding: [Float], attributes: FaceAttributes)] {
        try YuNet.detect(image, minFaceSize: minFaceSize).map { face in
            let aligned = FaceAlign.alignCrop(image, landmarks: face.landmarks)
            let attributes = min(face.bbox.w, face.bbox.h) >= minAttributeFaceSize
                ? try FaceAttributesModel.classify(aligned) : FaceAttributes()
            return (face, try FaceAlign.embed(aligned), attributes)
        }
    }
}

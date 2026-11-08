import Testing
@testable import AilbumCore

struct RecordJSONTests {
    // Python `to_dict` output for the same records, dumped with json.dumps.
    static let golden: JSONValue = try! JSONValue.parse(#"{"bare":{"color":null,"composition":null,"error":null,"exposure":0.5,"faces":[],"height":20,"is_blurry":true,"path":"/x/b.jpg","photo_id":"p2","quality":0.25,"selected":false,"semantics":null,"sharpness":1.5,"similar_cluster":null,"story_id":null,"taken_at":null,"width":10},"face":{"bbox":[10,20,30,40],"confidence":0.93,"database_id":7,"expression":{"confidence":0.875,"label":"smile","scores":{"neutral":0.375,"smile":0.625},"smile_probability":0.625},"eyes":{"both_open":false,"left":"open","left_open_probability":0.75,"right":"closed","right_open_probability":0.125},"face_id":"p1-face-01","person_cluster":2,"person_id":5},"photo":{"color":{"balance":0.5,"harmony":0.25,"mean_saturation":0.125},"composition":{"crop_risk":0.125,"frame_occupancy":0.5,"main_subject":{"bbox":[0.25,0.5,0.125,0.375],"center":[0.5,0.75],"source":"faces"},"negative_space":0.25,"rule_of_thirds":0.75,"score":0.625},"error":null,"exposure":0.75,"faces":[{"bbox":[10,20,30,40],"confidence":0.93,"database_id":7,"expression":{"confidence":0.875,"label":"smile","scores":{"neutral":0.375,"smile":0.625},"smile_probability":0.625},"eyes":{"both_open":false,"left":"open","left_open_probability":0.75,"right":"closed","right_open_probability":0.125},"face_id":"p1-face-01","person_cluster":2,"person_id":5},{"bbox":[1,2,3,4],"confidence":0.5,"database_id":null,"expression":null,"eyes":null,"face_id":"p1-face-02","person_cluster":null,"person_id":null}],"height":240,"is_blurry":false,"path":"/x/a.jpg","photo_id":"p1","quality":0.625,"selected":true,"semantics":{"aesthetic_score":0.5625,"model":"clip","objects":[{"confidence":0.25,"label":"dog"}],"scenes":[{"confidence":0.375,"label":"beach"}]},"sharpness":120.5,"similar_cluster":3,"story_id":4,"taken_at":"2024-01-02T03:04:05","width":320},"story":{"ended_at":null,"naming_model":"m","object_labels":["dog"],"photo_ids":["p1","p2"],"representative_photo_id":"p1","scene_labels":["beach"],"started_at":"2024-01-02T03:04:05","story_id":1,"title":"T"}}"#)

    static let face = FaceRecord(
        faceId: "p1-face-01", bbox: SIMD4(10, 20, 30, 40), confidence: 0.93, personCluster: 2, personId: 5,
        databaseId: 7, embedding: [0.5, 0.25],
        eyes: EyeStateRecord(left: "open", right: "closed", leftOpenProbability: 0.75,
                             rightOpenProbability: 0.125, bothOpen: false),
        expression: ExpressionRecord(label: "smile", confidence: 0.875, smileProbability: 0.625,
                                     scores: ["smile": 0.625, "neutral": 0.375]))

    static let photo = PhotoRecord(
        photoId: "p1", path: "/x/a.jpg", width: 320, height: 240, takenAt: "2024-01-02T03:04:05",
        sharpness: 120.5, exposure: 0.75, quality: 0.625, isBlurry: false,
        composition: CompositionRecord(
            ruleOfThirds: 0.75, frameOccupancy: 0.5, negativeSpace: 0.25, cropRisk: 0.125, score: 0.625,
            mainSubject: SubjectRecord(bbox: SIMD4(0.25, 0.5, 0.125, 0.375), center: SIMD2(0.5, 0.75), source: "faces")),
        color: ColorRecord(balance: 0.5, harmony: 0.25, meanSaturation: 0.125),
        semantics: SemanticRecord(aestheticScore: 0.5625, model: "clip", scenes: [TagRecord(label: "beach", confidence: 0.375)],
                                  objects: [TagRecord(label: "dog", confidence: 0.25)], embedding: [0.5, 0.5]),
        similarCluster: 3, storyId: 4, selected: true,
        faces: [face, FaceRecord(faceId: "p1-face-02", bbox: SIMD4(1, 2, 3, 4), confidence: 0.5)])

    @Test func testPhotoRecordKeys() {
        #expect(Self.photo.toJSON() == Self.golden["photo"])
        let bare = PhotoRecord(photoId: "p2", path: "/x/b.jpg", width: 10, height: 20, takenAt: nil,
                               sharpness: 1.5, exposure: 0.5, quality: 0.25, isBlurry: true)
        #expect(bare.toJSON() == Self.golden["bare"])
    }

    @Test func testFaceRecordDropsEmbedding() {
        let json = Self.face.toJSON()
        #expect(json == Self.golden["face"])
        #expect(json["embedding"] == nil)
    }

    @Test func testSemanticsDropsEmbedding() {
        let semantics = Self.photo.toJSON()["semantics"]
        #expect(semantics == Self.golden["photo"]?["semantics"])
        #expect(semantics?["embedding"] == nil)
    }

    @Test func testStoryRecordKeys() {
        let story = StoryRecord(storyId: 1, title: "T", photoIds: ["p1", "p2"], startedAt: "2024-01-02T03:04:05",
                                endedAt: nil, representativePhotoId: "p1", sceneLabels: ["beach"],
                                objectLabels: ["dog"], namingModel: "m")
        #expect(story.toJSON() == Self.golden["story"])
    }

    @Test func testPersonRecordKeys() {
        let person = PersonRecord(clusterId: 1, faceIds: ["f1"], photoIds: ["p1"], embeddingModel: "m", centroid: [1])
        let expected: JSONValue = ["person_cluster": 1, "person_id": .null, "public_id": .null, "name": .null,
                                   "faces": ["f1"], "photos": ["p1"]]
        #expect(person.toJSON() == expected)
    }
}

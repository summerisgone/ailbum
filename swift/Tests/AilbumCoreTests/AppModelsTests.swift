import Foundation
import Testing
@testable import AilbumCore

private func modelsTempDB() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/a.db"
}

private func modelsPopulate(album: Bool = true) throws -> String {
    let path = try modelsTempDB()
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')", [])
    for i in 1...2 {
        try db.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
            file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)
            VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024', ?, '{}', '{}', 't')
            """,
            [.integer(i), .text("/p/\(i).jpg"), .text("\(i).jpg"), .text("\(i).jpg"), .text("sha\(i)")])
        try db.execute(
            """
            INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
            quality, is_blurry, story_id, selected) VALUES ('r1', ?, ?, 0.5, 0.5, 0.5, 0, 1, 0)
            """, [.integer(i), .text("p\(i)")])
    }
    if album { _ = try Albums.create(db, title: "T", sources: ["/p"], runId: "r1", targetCount: 2) }
    return path
}

// Real DesktopBridge by default; SUPERLITE_REAL=1 selects the same. The fake is a canned
// bootstrap used only when the bridge is stubbed out via `fakeBridge`.
private func produce(_ db: String, _ action: String, _ payload: JSONValue = [:]) throws -> JSONValue {
    try DesktopBridge.dispatch(database: db, action: action, payload: payload)
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Suite(.serialized) struct AppModelsSuite {
    @Test func bootstrapDecodes() throws {
        let db = try modelsPopulate()
        let lib = try AppModels.decode(Library.self, produce(db, "library.bootstrap", [:]))
        #expect(lib.photos.count == 2)
        #expect(lib.album?.id == 1)
        #expect(lib.album?.status == .draft)
        #expect(lib.selected_count == 2)
        #expect(lib.photos[0].main_subject == nil)
        #expect(lib.photos[0].availability == .present)
    }

    @Test func bootstrapWithoutAlbum() throws {
        let db = try modelsPopulate(album: false)
        let lib = try AppModels.decode(Library.self, produce(db, "library.bootstrap", [:]))
        #expect(lib.album == nil)
        #expect(lib.photos.count == 2)
    }

    @Test func albumListAndExtraKeys() throws {
        let db = try modelsPopulate()
        let albums = try AppModels.decode([Album].self, produce(db, "album.list"))
        #expect(albums.count == 1 && albums[0].title == "T")
        let a = try AppModels.decode(Album.self, [
            "id": 1, "public_id": "x", "title": "Турция", "purpose": "print", "status": "ordered",
            "target_count": 5, "run_id": .null, "sources": ["/p"], "photo_count": 0, "ordered_at": .null,
            "archived_at": .null, "updated_at": "t", "surprise": ["nested": true],
        ])
        #expect(a.title == "Турция" && a.status == .ordered && a.purpose == .print && a.run_id == nil)
    }

    @Test func usageAndSummaryShapes() throws {
        let db = try modelsPopulate()
        let usage = try AppModels.decode(Usage.self, produce(db, "album.usage"))
        #expect(usage.images.present == 2)
    }

    @Test func peopleDecode() throws {
        let db = try modelsPopulate()
        let people = try AppModels.decode(PeopleLibrary.self, produce(db, "people.bootstrap"))
        #expect(people.people.isEmpty && people.total_faces == 0)
        let faces = try AppModels.decode(FaceCollection.self, produce(db, "person.faces", ["person_id": .null]))
        #expect(faces.person == nil && faces.faces.isEmpty)
    }

    @Test func faceOptionalsAndEyeStates() throws {
        let face = try AppModels.decode(Face.self, [
            "id": 1, "run_id": "r", "face_id": "f", "face_index": 0, "image_id": 1, "bbox_x": 0.1,
            "bbox_y": 0.2, "bbox_width": 0.3, "bbox_height": 0.4, "confidence": 0.9, "person_id": .null,
            "embedding_model": .null, "left_eye_state": "closed", "right_eye_state": .null,
            "both_eyes_open": .null, "expression": .null, "expression_confidence": .null,
            "smile_probability": .null, "path": "/p/1.jpg", "file_name": "1.jpg", "taken_at": .null,
            "orientation": .null,
        ])
        #expect(face.left_eye_state == .closed && face.right_eye_state == nil && face.person_id == nil)
    }

    @Test func layoutGetNullAndTemplates() throws {
        let db = try modelsPopulate()
        #expect(try produce(db, "layout.get", ["album_id": 999]) == .null)
        let templates = try AppModels.decode(
            [LayoutTemplateInfo].self,
            produce("x.db", "layout.templates", ["orientation": "vertical", "photo_count": 3]))
        #expect(!templates.isEmpty && templates.allSatisfy { $0.photo_count == 3 })
    }

    @Test func layoutDecodes() throws {
        let cell: JSONValue = [
            "index": 0, "x": 0, "y": 0, "w": 0.5, "h": 1, "crosses_spine": false,
            "placement": ["image_id": 4, "crop": ["x": 0, "y": 0, "w": 1, "h": 1], "fit": 0.8,
                          "warnings": ["w"], "replaced_image_id": .null],
        ]
        let layout = try AppModels.decode(Layout.self, [
            "id": 1, "run_id": .null, "album_id": 1, "orientation": "horizontal", "spread_count": 1,
            "min_photos": 1, "max_photos": 2, "stale": false, "assistant_model": .null, "warnings": [],
            "unplaced": [["image_id": 9, "reason": "x"]],
            "format": ["spread_w_mm": 420, "spread_h_mm": 297.5, "bleed_mm": 3, "safe_mm": 5],
            "spreads": [["id": 1, "position": 0, "template_id": "t", "story_ids": [1], "story_title": "S",
                         "warnings": [], "assistant_reason": .null, "cells": [cell]]],
        ])
        #expect(layout.orientation == .horizontal && layout.format.spread_w_mm == 420)
        #expect(layout.spreads[0].cells[0].placement?.replaced_image_id == nil)
        #expect(layout.spreads[0].cells[0].placement?.image_id == 4)
    }

    @Test func recordAndOtherShapes() throws {
        let info = try AppModels.decode(LayoutPromptInfo.self, ["weights": ["a": 1, "b": 0.5], "labels": ["a"]])
        #expect(info.weights["b"] == 0.5)
        let alt = try AppModels.decode(LayoutAlternative.self, [
            "image_id": 1, "fit": 1, "warnings": [], "in_selection": true,
            "placed": ["spread_id": 1, "position": 0, "cell_index": 2], "similar": false,
        ])
        #expect(alt.placed?.cell_index == 2)
        let run = try AppModels.decode(AnalysisRun.self, [
            "id": "r", "source": "s", "started_at": "a", "completed_at": "b", "face_backend": "none",
            "summary": ["n": 3, "deep": ["x": [1]]],
        ])
        #expect(run.summary["n"] == 3)
        let fav = try AppModels.decode(FavoriteResult.self, ["album_id": 1, "image_id": 2, "favorite": true, "selected_count": 3])
        #expect(fav.favorite)
    }

    @Test func archiveResultVariants() throws {
        #expect(try AppModels.decode(ArchiveResult.self, ["cancelled": true]) == .cancelled)
        #expect(try AppModels.decode(ArchiveResult.self, ["needsExport": true, "blocked": [["image_id": 1, "reason": "r"]]])
                == .needsExport(blocked: [BlockedImage(image_id: 1, reason: "r")]))
        #expect(try AppModels.decode(ArchiveResult.self, ["archived": 2, "blocked": [], "failed": ["/x"], "needsExport": false])
                == .archived(archived: 2, blocked: [], failed: ["/x"]))
    }

    @Test func unionEnumsRawValues() throws {
        #expect(Availability(rawValue: "missing") == .missing)
        #expect(AlbumPurpose(rawValue: "photobook_demo") == .photobook_demo)
        #expect(AlbumStatus(rawValue: "archived") == .archived)
        #expect(LayoutOrientation(rawValue: "vertical") == .vertical)
        #expect(AssistantMode(rawValue: "auto") == .auto)
        #expect(EyeState(rawValue: "open") == .open)
        #expect(Availability(rawValue: "nope") == nil)
        #expect(throws: (any Error).self) {
            try AppModels.decode(Album.self, ["id": 1, "status": "bogus"])
        }
    }

    @Test func layoutParamsEncodesWizardKeys() throws {
        let full = AppLayoutParams(orientation: .vertical, spread_count: 4, min_photos: 3, max_photos: 5,
                                assistant: .off, prompt: "x")
        let json = try JSONValue.parse(String(decoding: JSONEncoder().encode(full), as: UTF8.self))
        #expect(json == ["orientation": "vertical", "spread_count": 4, "min_photos": 3, "max_photos": 5,
                         "assistant": "off", "prompt": "x"])
        let minimal = AppLayoutParams(orientation: .horizontal, spread_count: 1, min_photos: 1, max_photos: 2)
        let mj = try JSONValue.parse(String(decoding: JSONEncoder().encode(minimal), as: UTF8.self))
        #expect(mj["assistant"] == nil && mj["prompt"] == nil && mj.objectValue?.count == 4)
        #expect(try roundTrip(full) == full)
    }
}

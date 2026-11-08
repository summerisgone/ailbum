import Foundation

/// Port of desktop_bridge.py: JSON-lines RPC from the desktop app into the core.
public enum DesktopBridge {
    /// Test seam: called with (name, args) before each layout operation; a non-nil result replaces the real call.
    nonisolated(unsafe) static var layoutHook: ((String, [Any]) throws -> JSONValue?)?
    /// Test seam: replaces `Proxies.faceThumbnail`.
    nonisolated(unsafe) static var faceThumbnailOverride: ((String, Int) throws -> Data)?

    // MARK: Python-style coercions

    private static func missing(_ key: String) -> AilbumError { .invalid("'\(key)'") }

    private static func required(_ payload: [String: JSONValue], _ key: String) throws -> JSONValue {
        guard let v = payload[key] else { throw missing(key) }
        return v
    }

    private static func pyInt(_ value: JSONValue) throws -> Int {
        switch value {
        case .int(let v): return v
        case .double(let v):
            guard v.isFinite, abs(v) < 9e18 else { throw AilbumError.invalid("cannot convert float \(v) to integer") }
            return Int(v)
        case .bool(let v): return v ? 1 : 0
        case .string(let s):
            guard let v = Int(s.trimmingCharacters(in: .whitespaces)) else {
                throw AilbumError.invalid("invalid literal for int() with base 10: '\(s)'")
            }
            return v
        default: throw AilbumError.invalid("int() argument must be a string, a bytes-like object or a real number")
        }
    }

    private static func int(_ payload: [String: JSONValue], _ key: String) throws -> Int {
        try pyInt(required(payload, key))
    }

    private static func optionalInt(_ payload: [String: JSONValue], _ key: String) throws -> Int? {
        guard let v = payload[key], v != .null else { return nil }
        return try pyInt(v)
    }

    private static func pyStr(_ value: JSONValue) -> String {
        switch value {
        case .null: return "None"
        case .bool(let v): return v ? "True" : "False"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        default: return (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private static func string(_ payload: [String: JSONValue], _ key: String) throws -> String {
        pyStr(try required(payload, key))
    }

    private static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let v)?: return v
        case .int(let v)?: return v != 0
        case .double(let v)?: return v != 0
        case .string(let v)?: return !v.isEmpty
        case .array(let v)?: return !v.isEmpty
        case .object(let v)?: return !v.isEmpty
        }
    }

    /// `str(payload.get(key) or "")[:MAX_PROMPT]`, counted in code points.
    private static func prompt(_ payload: [String: JSONValue], maxLength: Bool = true) -> String {
        guard truthy(payload["prompt"]), let v = payload["prompt"] else { return "" }
        let text = pyStr(v)
        return maxLength ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(Preferences.maxPrompt))) : text
    }

    private static func ints(_ value: JSONValue) throws -> [Int] {
        guard let items = value.arrayValue else { throw AilbumError.invalid("object is not iterable") }
        return try items.map(pyInt)
    }

    private static func optionalName(_ payload: [String: JSONValue]) -> String? {
        guard let v = payload["name"], v != .null else { return nil }
        return pyStr(v)
    }

    // MARK: Library

    private static func library(_ database: String, albumId: Int?) throws -> JSONValue {
        var library = try AlbumLibrary.getLibrary(database: database, albumId: albumId)
        let db = try Database.open(path: database)
        var hashes: [Int: String] = [:]
        for row in try db.query("SELECT id, sha256 FROM images", []) {
            if case .integer(let id)? = row["id"], case .text(let sha)? = row["sha256"] { hashes[Int(id)] = sha }
        }
        var photos = library["photos"]?.arrayValue ?? []
        for index in photos.indices {
            guard var photo = photos[index].objectValue else { continue }
            var image: [String: SQLValue] = [:]
            image["path"] = photo["path"]?.stringValue.map { .text($0) } ?? .null
            image["availability"] = photo["availability"]?.stringValue.map { .text($0) } ?? .null
            if let id = photo["id"]?.intValue, let sha = hashes[id] { image["sha256"] = .text(sha) }
            photo["media_path"] = Proxies.imageSource(database: database, image: image).map { .string($0) } ?? .null
            photos[index] = .object(photo)
        }
        guard var object = library.objectValue else { return library }
        object["photos"] = .array(photos)
        library = .object(object)
        return library
    }

    // MARK: Layout

    private static func layoutParams(_ payload: [String: JSONValue]) throws -> LayoutParams {
        LayoutParams(
            orientation: try string(payload, "orientation"),
            spreadCount: try int(payload, "spread_count"),
            minPhotos: try int(payload, "min_photos"),
            maxPhotos: try int(payload, "max_photos"),
            assistant: payload["assistant"].map(pyStr) ?? "auto",
            prompt: prompt(payload))
    }

    private static func layoutTemplates(_ orientation: String, photoCount: Int?) throws -> JSONValue {
        let format = try Templates.formatFor(orientation)
        return .array(try Templates.templatesFor(orientation, photoCount: photoCount).map { template in
            [
                "id": .string(template.id),
                "photo_count": .int(template.photoCount),
                "cells": .array(template.cells.map { cell in
                    [
                        "index": .int(cell.index),
                        "x": .double(cell.rect.x / format.spreadWmm),
                        "y": .double(cell.rect.y / format.spreadHmm),
                        "w": .double(cell.rect.w / format.spreadWmm),
                        "h": .double(cell.rect.h / format.spreadHmm),
                    ]
                }),
            ]
        })
    }

    private static func hook(_ name: String, _ args: Any...) throws -> JSONValue? {
        try layoutHook?(name, args)
    }

    private static func dispatchLayout(_ database: String, _ action: String, _ payload: [String: JSONValue]) throws
        -> JSONValue
    {
        switch action {
        case "layout.preflight":
            let albumId = try int(payload, "album_id")
            let params = try layoutParams(payload)
            if let r = try hook("preflight", database, albumId, params) { return r }
            return try LayoutService.preflight(database: database, albumId: albumId, params: params)
        case "layout.get":
            let albumId = try int(payload, "album_id")
            let db = try Database.open(path: database)
            return try LayoutStore.loadLayout(db, albumId: albumId) ?? .null
        case "layout.templates":
            return try layoutTemplates(try string(payload, "orientation"),
                                       photoCount: try optionalInt(payload, "photo_count"))
        case "layout.export":
            return try LayoutExport.exportOriginals(
                database: database, albumId: try int(payload, "album_id"), folder: try string(payload, "folder"))
        case "layout.parse_prompt":
            return Editing.parsePrompt(prompt(payload, maxLength: false))
        default: break
        }
        let spreadId = try int(payload, "spread_id")
        switch action {
        case "layout.similar":
            let cell = try int(payload, "cell_index")
            if let r = try hook("similar", database, spreadId, cell) { return r }
            return .array(try Editing.similar(database: database, spreadId: spreadId, cellIndex: cell))
        case "layout.variants":
            if let r = try hook("variants", database, spreadId) { return r }
            return .array(try Editing.variants(database: database, spreadId: spreadId))
        case "layout.apply_variant":
            let template = try string(payload, "template_id")
            let ids = try ints(try required(payload, "image_ids"))
            if let r = try hook("apply_variant", database, spreadId, template, ids) { return r }
            return try Editing.applyVariant(database: database, spreadId: spreadId, templateId: template, imageIds: ids)
        case "layout.alternatives":
            let cell = try int(payload, "cell_index")
            if let r = try hook("alternatives", database, spreadId, cell) { return r }
            return .array(try Editing.alternatives(database: database, spreadId: spreadId, cellIndex: cell))
        case "layout.set_photo":
            let cell = try int(payload, "cell_index")
            let image = try int(payload, "image_id")
            if let r = try hook("set_photo", database, spreadId, cell, image) { return r }
            return try Editing.setPhoto(database: database, spreadId: spreadId, cellIndex: cell, imageId: image)
        case "layout.swap_cells":
            let a = try int(payload, "cell_a")
            let b = try int(payload, "cell_b")
            if let r = try hook("swap_cells", database, spreadId, a, b) { return r }
            return try Editing.swapCells(database: database, spreadId: spreadId, cellA: a, cellB: b)
        case "layout.set_template":
            let template = try string(payload, "template_id")
            if let r = try hook("set_template", database, spreadId, template) { return r }
            return try Editing.setTemplate(database: database, spreadId: spreadId, templateId: template)
        case "layout.set_crop":
            let cell = try int(payload, "cell_index")
            let crop = try required(payload, "crop")
            guard crop.objectValue != nil else { throw AilbumError.invalid("cannot convert crop to dict") }
            if let r = try hook("set_crop", database, spreadId, cell, crop) { return r }
            return try Editing.setCrop(database: database, spreadId: spreadId, cellIndex: cell, crop: crop)
        case "layout.recompose_spread":
            let text = prompt(payload)
            if let r = try hook("recompose_spread", database, spreadId, text) { return r }
            return try Editing.recomposeSpread(database: database, spreadId: spreadId, prompt: text)
        default:
            throw AilbumError.invalid("Unknown desktop action: \(action)")
        }
    }

    // MARK: Dispatch

    public static func dispatch(database: String, action: String, payload: JSONValue) throws -> JSONValue {
        let p = payload.objectValue ?? [:]
        switch action {
        case "database.initialize":
            _ = try Database.open(path: database)
            return try CatalogQueries.summary(database: database)
        case "database.summary":
            return try CatalogQueries.summary(database: database)
        case "library.bootstrap":
            return try library(database, albumId: try optionalInt(p, "album_id"))
        case "favorite.set":
            let db = try Database.open(path: database)
            return try AlbumLibrary.setPhoto(
                db, albumId: try int(p, "album_id"), imageId: try int(p, "image_id"),
                selected: truthy(try required(p, "favorite")))
        case "target.set":
            let db = try Database.open(path: database)
            return try AlbumLibrary.setTarget(db, albumId: try int(p, "album_id"), targetCount: try int(p, "target_count"))
        case "selection.autofill":
            let db = try Database.open(path: database)
            return try AlbumLibrary.autofill(db, albumId: try int(p, "album_id"))
        case "album.list":
            return try Albums.list(try Database.open(path: database))
        case "album.status":
            let db = try Database.open(path: database)
            return try Albums.setStatus(db, try int(p, "album_id"), try string(p, "status"))
        case "album.rename":
            let db = try Database.open(path: database)
            return try Albums.rename(db, try int(p, "album_id"), title: try string(p, "title"))
        case "album.delete":
            let db = try Database.open(path: database)
            try Albums.delete(db, try int(p, "album_id"), forgetDecisions: truthy(p["forget_decisions"]))
            return ["deleted": true]
        case "album.prepare_archive":
            return try Archive.prepare(database: database, albumId: try int(p, "album_id"))
        case "album.complete_archive":
            guard let items = try required(p, "trashed").arrayValue else {
                throw AilbumError.invalid("object is not iterable")
            }
            return try Archive.complete(database: database, albumId: try int(p, "album_id"), trashed: items.map(pyStr))
        case "album.confirm_missing":
            return ["confirmed": .int(try Archive.confirmMissing(
                database: database, imageIds: try ints(try required(p, "image_ids"))))]
        case "album.usage":
            return try Forget.usage(database: database)
        case "people.bootstrap":
            return try PeopleStore.desktopPeople(database: database)
        case "person.faces":
            return try PeopleStore.desktopFaces(database: database, personId: try optionalInt(p, "person_id"))
        case "person.name":
            return try PeopleStore.name(database: database, personId: try int(p, "person_id"), name: optionalName(p))
        case "person.merge":
            return try PeopleStore.merge(
                database: database, targetId: try int(p, "target_id"), sourceIds: [try int(p, "source_id")])
        case "face.assign":
            return try PeopleStore.setFacePerson(
                database: database, faceId: try int(p, "face_id"), personId: try optionalInt(p, "person_id"))
        case "face.create_person":
            return try PeopleStore.createPersonFromFace(
                database: database, faceId: try int(p, "face_id"), name: optionalName(p))
        case "face.thumbnail":
            let faceId = try int(p, "face_id")
            let data = try faceThumbnailOverride?(database, faceId)
                ?? Proxies.faceThumbnail(database: database, faceId: faceId)
            return ["mime_type": "image/jpeg", "base64": .string(data.base64EncodedString())]
        case _ where action.hasPrefix("layout."):
            return try dispatchLayout(database, action, p)
        case "ping":
            return ["ok": true]
        default:
            throw AilbumError.invalid("Unknown desktop action: \(action)")
        }
    }

    // MARK: JSON-lines round trip

    private static func message(_ error: Error) -> String {
        switch error {
        case AilbumError.invalid(let m), AilbumError.decode(let m), AilbumError.sqlite(let m), AilbumError.metal(let m):
            return m
        case AilbumError.schemaTooOld(let v): return "Database schema version \(v) is too old"
        default: return (error as NSError).localizedDescription
        }
    }

    private static func encode(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func respond(database: String, line: String) -> String {
        var requestId: JSONValue = .null
        var response: JSONValue
        do {
            let request = try JSONValue.parse(line)
            guard let object = request.objectValue else {
                throw AilbumError.invalid("Desktop request must be a JSON object")
            }
            requestId = object["id"] ?? .null
            guard let id = object["id"] else { throw missing("id") }
            guard let action = object["action"] else { throw missing("action") }
            let payload = truthy(object["payload"]) ? object["payload"]! : [:]
            guard payload.objectValue != nil else { throw AilbumError.invalid("Desktop payload must be a JSON object") }
            let result = try dispatch(database: database, action: pyStr(action), payload: payload)
            response = ["id": id, "result": result]
        } catch {
            response = ["id": requestId, "error": .string(message(error))]
        }
        if let text = encode(response) { return text }
        return encode(["id": requestId, "error": "Response is not JSON serializable"])
            ?? #"{"error":"Response is not JSON serializable","id":null}"#
    }
}

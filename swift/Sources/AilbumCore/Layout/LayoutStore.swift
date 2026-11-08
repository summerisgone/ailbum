import Foundation

public enum LayoutStore {
    public static func selectionHash(_ db: Database, albumId: Int) throws -> String {
        try AlbumLibrary.selectionHash(db, albumId: albumId)
    }

    public static func albumRun(_ db: Database, albumId: Int) throws -> String {
        guard let row = try db.query("SELECT run_id FROM albums WHERE id = ?", [.integer(albumId)]).first else {
            throw AilbumError.invalid("Альбом не найден")
        }
        guard case .text(let run)? = row["run_id"] else { throw AilbumError.invalid("У альбома нет анализа") }
        return run
    }

    public static func requireDraft(_ db: Database, albumId: Int) throws {
        guard let row = try db.query("SELECT status FROM albums WHERE id = ?", [.integer(albumId)]).first else {
            throw AilbumError.invalid("Альбом не найден")
        }
        guard case .text("draft")? = row["status"] else {
            throw AilbumError.invalid("Альбом заказан: изменения недоступны")
        }
    }

    /// Replaces the album's layout in one transaction; returns the new layout id.
    @discardableResult
    public static func saveLayout(
        _ db: Database, albumId: Int, runId: String, params: LayoutParams, spreads: [SpreadDraft],
        unplaced: [JSONValue], warnings: [String], selectionHash: String, assistantModel: String?
    ) throws -> Int {
        var layoutId = 0
        try db.transaction {
            // Children are removed explicitly so replacement does not depend on PRAGMA foreign_keys.
            for old in try db.query("SELECT id FROM layouts WHERE album_id = ?", [.integer(albumId)]) {
                guard case .integer(let oldId)? = old["id"] else { continue }
                for spread in try db.query("SELECT id FROM layout_spreads WHERE layout_id = ?", [.integer(oldId)]) {
                    if case .integer(let spreadId)? = spread["id"] {
                        try db.execute("DELETE FROM layout_placements WHERE spread_id = ?", [.integer(spreadId)])
                    }
                }
                try db.execute("DELETE FROM layout_spreads WHERE layout_id = ?", [.integer(oldId)])
                try db.execute("DELETE FROM layouts WHERE id = ?", [.integer(oldId)])
            }
            let now = Catalog.utcNow()
            try db.execute(
                """
                INSERT INTO layouts (
                    album_id, run_id, orientation, spread_count, min_photos, max_photos, selection_hash,
                    assistant_model, unplaced_json, warnings_json, prompt, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.integer(albumId), .text(runId), .text(params.orientation), .integer(params.spreadCount),
                 .integer(params.minPhotos), .integer(params.maxPhotos), .text(selectionHash),
                 assistantModel.map { .text($0) } ?? .null, .text(dumps(.array(unplaced))),
                 .text(dumps(strings(warnings))), .text(params.prompt), .text(now), .text(now)])
            layoutId = try lastId(db)
            for (offset, spread) in spreads.enumerated() {
                try db.execute(
                    """
                    INSERT INTO layout_spreads (
                        layout_id, position, template_id, story_ids_json, warnings_json, assistant_reason
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(layoutId), .integer(offset + 1), .text(spread.templateId),
                     .text(dumps(.array(spread.storyIds.map { .int($0) }))), .text(dumps(strings(spread.warnings))),
                     spread.assistantReason.map { .text($0) } ?? .null])
                let spreadId = try lastId(db)
                for p in spread.placements {
                    try db.execute(
                        """
                        INSERT INTO layout_placements (
                            spread_id, cell_index, image_id, crop_x, crop_y, crop_w, crop_h, fit,
                            warnings_json, replaced_image_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.integer(spreadId), .integer(p.cellIndex), .integer(p.imageId), .real(p.crop.x),
                         .real(p.crop.y), .real(p.crop.w), .real(p.crop.h), .real(p.fit),
                         .text(dumps(strings(p.warnings))), p.replacedImageId.map { .integer($0) } ?? .null])
                }
            }
        }
        return layoutId
    }

    public static func loadLayout(_ db: Database, albumId: Int) throws -> JSONValue? {
        guard let layout = try db.query("SELECT * FROM layouts WHERE album_id = ?", [.integer(albumId)]).first else {
            return nil
        }
        let runId = text(layout["run_id"]) ?? ""
        let orientation = text(layout["orientation"]) ?? ""
        let format = try Templates.formatFor(orientation)
        var templates: [String: Template] = [:]
        for template in try Templates.templatesFor(orientation) { templates[template.id] = template }
        var titles: [Int: String] = [:]
        for row in try db.query("SELECT story_id, title FROM stories WHERE run_id = ?", [.text(runId)]) {
            if let id = int(row["story_id"]) { titles[id] = text(row["title"]) ?? "" }
        }
        let layoutId = int(layout["id"]) ?? 0
        var spreads: [JSONValue] = []
        let spreadRows = try db.query(
            "SELECT * FROM layout_spreads WHERE layout_id = ? ORDER BY position", [.integer(layoutId)])
        for spread in spreadRows {
            var placements: [Int: [String: SQLValue]] = [:]
            for row in try db.query(
                "SELECT * FROM layout_placements WHERE spread_id = ?", [.integer(int(spread["id"]) ?? 0)]) {
                placements[int(row["cell_index"]) ?? 0] = row
            }
            let templateId = text(spread["template_id"]) ?? ""
            guard let template = templates[templateId] else {
                throw AilbumError.invalid("Неизвестный шаблон: \(templateId)")
            }
            let storyIds = try JSONValue.parse(text(spread["story_ids_json"]) ?? "[]")
            var cells: [JSONValue] = []
            for cell in template.cells.sorted(by: { $0.index < $1.index }) {
                cells.append([
                    "index": .int(cell.index),
                    "x": .double(fraction(cell.rect.x, format.spreadWmm)),
                    "y": .double(fraction(cell.rect.y, format.spreadHmm)),
                    "w": .double(fraction(cell.rect.w, format.spreadWmm)),
                    "h": .double(fraction(cell.rect.h, format.spreadHmm)),
                    "crosses_spine": .bool(cell.spineBand != nil),
                    "placement": try placements[cell.index].map { try placement($0) } ?? .null,
                ])
            }
            let title = (storyIds.arrayValue ?? []).compactMap { $0.intValue.flatMap { titles[$0] } }
                .joined(separator: " + ")
            spreads.append([
                "id": .int(int(spread["id"]) ?? 0),
                "position": .int(int(spread["position"]) ?? 0),
                "template_id": .string(templateId),
                "story_ids": storyIds,
                "story_title": .string(title),
                "warnings": try JSONValue.parse(text(spread["warnings_json"]) ?? "[]"),
                "assistant_reason": text(spread["assistant_reason"]).map { .string($0) } ?? .null,
                "cells": .array(cells),
            ])
        }
        let current = try AlbumLibrary.selectionHash(db, albumId: albumId)
        return [
            "id": .int(layoutId),
            "album_id": .int(albumId),
            "run_id": .string(runId),
            "prompt": .string(text(layout["prompt"]) ?? ""),
            "orientation": .string(orientation),
            "spread_count": .int(int(layout["spread_count"]) ?? 0),
            "min_photos": .int(int(layout["min_photos"]) ?? 0),
            "max_photos": .int(int(layout["max_photos"]) ?? 0),
            "stale": .bool(text(layout["selection_hash"]) != current),
            "assistant_model": text(layout["assistant_model"]).map { .string($0) } ?? .null,
            "warnings": try JSONValue.parse(text(layout["warnings_json"]) ?? "[]"),
            "unplaced": try JSONValue.parse(text(layout["unplaced_json"]) ?? "[]"),
            "format": [
                "spread_w_mm": .double(format.spreadWmm),
                "spread_h_mm": .double(format.spreadHmm),
                "bleed_mm": .double(format.bleedMm),
                "safe_mm": .double(format.safeMm),
            ],
            "spreads": .array(spreads),
        ]
    }

    private static func placement(_ row: [String: SQLValue]) throws -> JSONValue {
        [
            "image_id": .int(int(row["image_id"]) ?? 0),
            "crop": [
                "x": number(row["crop_x"]), "y": number(row["crop_y"]),
                "w": number(row["crop_w"]), "h": number(row["crop_h"]),
            ],
            "fit": number(row["fit"]),
            "warnings": try JSONValue.parse(text(row["warnings_json"]) ?? "[]"),
            "replaced_image_id": int(row["replaced_image_id"]).map { .int($0) } ?? .null,
        ]
    }

    /// Python `min(1.0, max(0.0, round(value / total, 5)))`.
    private static func fraction(_ valueMm: Double, _ totalMm: Double) -> Double {
        let rounded = Double(String(format: "%.5f", valueMm / totalMm)) ?? 0
        return min(1.0, max(0.0, rounded))
    }

    private static func lastId(_ db: Database) throws -> Int {
        int(try db.query("SELECT last_insert_rowid() AS id", []).first?["id"]) ?? 0
    }

    private static func text(_ v: SQLValue?) -> String? { if case .text(let s)? = v { return s } else { return nil } }

    private static func int(_ v: SQLValue?) -> Int? { if case .integer(let i)? = v { return Int(i) } else { return nil } }

    private static func number(_ v: SQLValue?) -> JSONValue {
        switch v {
        case .real(let d)?: return .double(d)
        case .integer(let i)?: return .int(Int(i))
        default: return .null
        }
    }

    private static func strings(_ items: [String]) -> JSONValue { .array(items.map { .string($0) }) }

    /// Python `json.dumps(value, ensure_ascii=False)` with sorted keys.
    static func dumps(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
            return "\(d)"
        case .string(let s): return quote(s)
        case .array(let a): return "[" + a.map(dumps).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { quote($0) + ": " + dumps(o[$0]!) }.joined(separator: ", ") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

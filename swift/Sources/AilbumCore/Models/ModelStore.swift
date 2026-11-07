import CoreML
import CryptoKit
import Foundation

public enum ModelStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: MLModel] = [:]

    static var modelsDir: URL {
        if let env = ProcessInfo.processInfo.environment["AILBUM_MODELS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }  // swift/
        return url.appendingPathComponent("Models")
    }

    static func sourceURL(_ name: String) -> URL {
        modelsDir.appendingPathComponent("\(name).mlpackage")
    }

    public static func available(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sourceURL(name).path)
    }

    /// Compiled `.mlmodelc` cached by name and Manifest.json hash.
    static func compiledURL(_ name: String) throws -> URL {
        let src = sourceURL(name)
        guard let manifest = FileManager.default.contents(atPath: src.appendingPathComponent("Manifest.json").path) else {
            throw AilbumError.decode("model not found: \(src.path)")
        }
        let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ailbum/models")
        let dest = cacheDir.appendingPathComponent("\(name)-\(hash).mlmodelc")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let tmp = try MLModel.compileModel(at: src)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            throw AilbumError.decode("cannot compile \(src.path): \(error)")
        }
        return dest
    }

    static func model(_ name: String) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let m = loaded[name] { return m }
        let url = try compiledURL(name)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        do {
            let m = try MLModel(contentsOf: url, configuration: cfg)
            loaded[name] = m
            return m
        } catch {
            throw AilbumError.decode("cannot load \(url.path): \(error)")
        }
    }

    public static func predict(_ name: String, inputs: [String: MLMultiArray]) throws -> [String: [Float]] {
        let m = try model(name)
        let out: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
            out = try m.prediction(from: provider)
        } catch {
            throw AilbumError.decode("prediction failed for \(name): \(error)")
        }
        var result: [String: [Float]] = [:]
        for key in out.featureNames {
            guard let arr = out.featureValue(for: key)?.multiArrayValue else { continue }
            result[key] = (0..<arr.count).map { arr[$0].floatValue }
        }
        return result
    }
}

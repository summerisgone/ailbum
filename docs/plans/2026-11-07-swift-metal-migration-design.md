# Swift + Metal migration - design

## 1. Decisions (user, 2026-11-07)

- macOS only. MSI/deb packaging is dropped at the end of the migration.
- Full rewrite: Swift core + SwiftUI app. Python backend and Electron/React UI are removed once the Swift app reaches parity.
- CV runtime: Apple frameworks only. ONNX models (YuNet, SFace, eye state, expression, YOLOX) and CLIP are converted once to CoreML with `coremltools` (offline build step, never shipped). SIFT + RANSAC homography is reimplemented on Metal. No OpenCV, no ONNX Runtime.
- Data: SQLite schema v12 is kept byte-compatible. CV features (embeddings, hashes, scores) are recomputed by the Swift pipeline ("re-analysis"); persisted people and decisions survive, face embeddings are refreshed per run.
- AI orchestrator.

## 2. Toolchain facts (verified)

- Only Command Line Tools are installed (no Xcode): SwiftPM 6.3 builds and tests; `xcrun metal` is absent, so Metal kernels are compiled at runtime with `MTLDevice.makeLibrary(source:options:)` from Swift string constants.
- Swift Testing works with CLT only when `-F`/rpath flags point at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` (see `.superlite/test-cmd.json`). XCTest is unavailable.
- CoreML models load via `MLModel.compileModel(at:)` at runtime (no `coremlc`).

## 3. Phases

Each phase is its own superlite plan; a phase starts after the previous one is merged.

| Phase | Scope | Python modules replaced |
|---|---|---|
| 1 Core foundations | SwiftPM package, SQLite v12 access, image decode/EXIF, Metal context, quality metrics, pHash/colour, vectors + clustering, logistic ranker, CLI probe | database (open), io, cv/quality, cv/similarity (hash/colour), cv/clustering, ranking/model |
| 2 Geometry | Metal SIFT (DoG pyramid, orientation, descriptors), brute-force L2 matcher + ratio test, RANSAC homography, convex hull coverage, `cluster_similar_photos` | cv/similarity (geometric) |
| 3 Models | coremltools conversion script; Vision face detection fallback; YuNet/SFace/eye/expression/YOLOX in CoreML; CLIP image+text encoders and BPE tokenizer; aesthetics/composition | cv/faces, cv/objects, cv/semantics, cv/aesthetics |
| 4 Pipeline | pipeline, stories, people, feature cache, proxies, metadata, albums, archive, ranking select/train, layout engine | remaining `src/ailbum` |
| 5 App | SwiftUI app replacing every Electron IPC call, LM Studio client, packaging (.app/.dmg), removal of Python and Electron | desktop/, packaging/ |

## 4. Parity rule

Every Swift port of a numeric function is tested against golden values produced by running the current Python function on the same synthetic input. Tolerances: exact for integer/bit outputs computed without resizing; relative 1e-3 for float metrics on un-resized input; relative 2e-2 where an INTER_AREA resize is involved.

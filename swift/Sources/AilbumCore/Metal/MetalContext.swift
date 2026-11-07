import Foundation
import Metal

public final class MetalContext: @unchecked Sendable {
    public static let shared = MetalContext()

    public let device: MTLDevice?
    public let queue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    private init() {
        let d = MTLCreateSystemDefaultDevice()
        device = d
        queue = d?.makeCommandQueue()
    }

    public func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        guard let device else { throw AilbumError.metal("no Metal device") }
        if let p = pipelines[name] { return p }
        do {
            if library == nil {
                library = try device.makeLibrary(source: MetalKernels.source, options: nil)
            }
            guard let fn = library?.makeFunction(name: name) else {
                throw AilbumError.metal("kernel not found: \(name)")
            }
            let p = try device.makeComputePipelineState(function: fn)
            pipelines[name] = p
            return p
        } catch let e as AilbumError {
            throw e
        } catch {
            throw AilbumError.metal("\(error)")
        }
    }
}

enum MetalKernels {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    inline int reflect101(int i, int n) {
        if (n == 1) return 0;
        if (i < 0) i = -i;
        if (i >= n) i = 2 * n - 2 - i;
        return i;
    }

    kernel void gaussian3(device const float *src [[buffer(0)]],
                          device float *dst [[buffer(1)]],
                          constant int2 &size [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        int w = size.x, h = size.y;
        if ((int)gid.x >= w || (int)gid.y >= h) return;
        int x = gid.x, y = gid.y;
        const int k[3] = {1, 2, 1};
        float sum = 0.0f;
        for (int dy = -1; dy <= 1; dy++) {
            int yy = reflect101(y + dy, h);
            for (int dx = -1; dx <= 1; dx++) {
                int xx = reflect101(x + dx, w);
                sum += src[yy * w + xx] * float(k[dy + 1] * k[dx + 1]);
            }
        }
        dst[y * w + x] = floor(sum / 16.0f + 0.5f);
    }

    kernel void laplacian(device const float *src [[buffer(0)]],
                          device float *dst [[buffer(1)]],
                          constant int2 &size [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        int w = size.x, h = size.y;
        if ((int)gid.x >= w || (int)gid.y >= h) return;
        int x = gid.x, y = gid.y;
        int xl = reflect101(x - 1, w), xr = reflect101(x + 1, w);
        int yu = reflect101(y - 1, h), yd = reflect101(y + 1, h);
        dst[y * w + x] = src[yu * w + x] + src[yd * w + x] + src[y * w + xl] + src[y * w + xr]
                         - 4.0f * src[y * w + x];
    }
    """
}

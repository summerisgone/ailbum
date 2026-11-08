import Foundation

enum MatcherKernels {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // One thread per query row: best and second-best squared distance over the train set.
    // Ties keep the lower train index (strict <).
    kernel void knn2(device const float *query [[buffer(0)]],
                     device const float *train [[buffer(1)]],
                     device int *bestIdx [[buffer(2)]],
                     device float2 *bestDist [[buffer(3)]],
                     constant int3 &dims [[buffer(4)]],   // nq, nt, dim
                     uint gid [[thread_position_in_grid]],
                     uint lid [[thread_position_in_threadgroup]],
                     uint tsize [[threads_per_threadgroup]]) {
        int nq = dims.x, nt = dims.y, dim = dims.z;
        bool active = (int)gid < nq;
        float b1 = INFINITY, b2 = INFINITY;
        int bi = -1;
        threadgroup float tile[16 * 128];
        const int tileRows = 16;
        for (int base = 0; base < nt; base += tileRows) {
            int rows = min(tileRows, nt - base);
            for (int i = (int)lid; i < rows * dim; i += (int)tsize) {
                tile[i] = train[(long)base * dim + i];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (active) {
                for (int r = 0; r < rows; r++) {
                    float d = 0.0f;
                    for (int k = 0; k < dim; k++) {
                        float e = query[(long)gid * dim + k] - tile[r * dim + k];
                        d += e * e;
                    }
                    if (d < b1) { b2 = b1; b1 = d; bi = base + r; }
                    else if (d < b2) { b2 = d; }
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (active) {
            bestIdx[gid] = bi;
            bestDist[gid] = float2(b1, b2);
        }
    }
    """
}

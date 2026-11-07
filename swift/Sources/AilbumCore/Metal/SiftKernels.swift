enum SiftKernels {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    inline int reflect101(int i, int n) {
        if (n == 1) return 0;
        if (i < 0) i = -i;
        if (i >= n) i = 2 * n - 2 - i;
        return i;
    }

    kernel void sift_upsample2(device const float *src [[buffer(0)]],
                               device float *dst [[buffer(1)]],
                               constant int2 &srcSize [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int w = srcSize.x, h = srcSize.y;
        if ((int)gid.x >= 2 * w || (int)gid.y >= 2 * h) return;
        float fx = ((float)gid.x + 0.5f) * 0.5f - 0.5f;
        float fy = ((float)gid.y + 0.5f) * 0.5f - 0.5f;
        int sx = (int)floor(fx), sy = (int)floor(fy);
        fx -= (float)sx; fy -= (float)sy;
        if (sx < 0) { fx = 0; sx = 0; }
        if (sx >= w - 1) { fx = 0; sx = w - 1; }
        if (sy < 0) { fy = 0; sy = 0; }
        if (sy >= h - 1) { fy = 0; sy = h - 1; }
        int sx1 = min(sx + 1, w - 1), sy1 = min(sy + 1, h - 1);
        float a = src[sy * w + sx] * (1 - fx) + src[sy * w + sx1] * fx;
        float b = src[sy1 * w + sx] * (1 - fx) + src[sy1 * w + sx1] * fx;
        dst[gid.y * 2 * w + gid.x] = a * (1 - fy) + b * fy;
    }

    // dir.x = 1: horizontal pass, 0: vertical pass
    kernel void sift_blur1d(device const float *src [[buffer(0)]],
                            device float *dst [[buffer(1)]],
                            device const float *weights [[buffer(2)]],
                            constant int4 &params [[buffer(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = params.x, h = params.y, ksize = params.z, horiz = params.w;
        if ((int)gid.x >= w || (int)gid.y >= h) return;
        int r = ksize / 2;
        float sum = 0.0f;
        for (int k = -r; k <= r; k++) {
            float v = horiz ? src[gid.y * w + reflect101((int)gid.x + k, w)]
                            : src[reflect101((int)gid.y + k, h) * w + gid.x];
            sum += v * weights[k + r];
        }
        dst[gid.y * w + gid.x] = sum;
    }

    kernel void sift_downsample2(device const float *src [[buffer(0)]],
                                 device float *dst [[buffer(1)]],
                                 constant int4 &params [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        int sw = params.x, dw = params.z, dh = params.w;
        if ((int)gid.x >= dw || (int)gid.y >= dh) return;
        dst[gid.y * dw + gid.x] = src[(2 * gid.y) * sw + 2 * gid.x];
    }

    kernel void sift_subtract(device const float *a [[buffer(0)]],
                              device const float *b [[buffer(1)]],
                              device float *dst [[buffer(2)]],
                              constant int &n [[buffer(3)]],
                              uint i [[thread_position_in_grid]]) {
        if ((int)i >= n) return;
        dst[i] = a[i] - b[i];
    }
    """
}

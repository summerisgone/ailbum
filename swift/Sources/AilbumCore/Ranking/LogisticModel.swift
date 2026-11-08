import Foundation

public struct LogisticModel {
    public var weights: [Double]
    public var bias: Double
    public var mean: [Double]
    public var std: [Double]
    public var featureVersion: Int
    public var featureNames: [String]

    public init(weights: [Double], bias: Double, mean: [Double], std: [Double],
                featureVersion: Int = 0, featureNames: [String] = []) {
        self.weights = weights
        self.bias = bias
        self.mean = mean
        self.std = std
        self.featureVersion = featureVersion
        self.featureNames = featureNames
    }

    public static func fit(x: [[Double]], y: [Double], l2: Double) -> LogisticModel {
        let n = x.count
        let d = x.first?.count ?? 0
        var mean = [Double](repeating: 0, count: d)
        var std = [Double](repeating: 1, count: d)
        for j in 0..<d {
            let m = x.reduce(0.0) { $0 + $1[j] } / Double(n)
            let v = x.reduce(0.0) { $0 + ($1[j] - m) * ($1[j] - m) } / Double(n)
            let s = v.squareRoot()
            mean[j] = m
            std[j] = s < 1e-12 ? 1.0 : s
        }
        let k = d + 1
        let a: [[Double]] = x.map { row in (0..<d).map { (row[$0] - mean[$0]) / std[$0] } + [1.0] }
        var beta = [Double](repeating: 0, count: k)
        for _ in 0..<50 {
            var grad = [Double](repeating: 0, count: k)
            var hess = [Double](repeating: 0, count: k * k)
            for i in 0..<n {
                var t = 0.0
                for j in 0..<k { t += a[i][j] * beta[j] }
                let p = 1.0 / (1.0 + exp(-min(max(t, -30), 30)))
                let w = p * (1 - p)
                for j in 0..<k {
                    grad[j] += a[i][j] * (p - y[i])
                    for l in 0..<k { hess[j * k + l] += a[i][j] * w * a[i][l] }
                }
            }
            for j in 0..<d {
                grad[j] += l2 * beta[j]
                hess[j * k + j] += l2
            }
            for j in 0..<k { hess[j * k + j] += 1e-9 }
            let step = solve(hess, grad, k)
            var maxStep = 0.0
            for j in 0..<k {
                beta[j] -= step[j]
                maxStep = max(maxStep, abs(step[j]))
            }
            if maxStep < 1e-8 { break }
        }
        return LogisticModel(weights: Array(beta[0..<d]), bias: beta[d], mean: mean, std: std)
    }

    // Gaussian elimination with partial pivoting; a is row-major k x k.
    private static func solve(_ a0: [Double], _ b0: [Double], _ k: Int) -> [Double] {
        var a = a0, b = b0
        for c in 0..<k {
            var piv = c
            for r in (c + 1)..<max(k, c + 1) where abs(a[r * k + c]) > abs(a[piv * k + c]) { piv = r }
            if piv != c {
                for j in 0..<k { a.swapAt(c * k + j, piv * k + j) }
                b.swapAt(c, piv)
            }
            let p = a[c * k + c]
            for r in (c + 1)..<max(k, c + 1) {
                let f = a[r * k + c] / p
                if f == 0 { continue }
                for j in c..<k { a[r * k + j] -= f * a[c * k + j] }
                b[r] -= f * b[c]
            }
        }
        var xs = [Double](repeating: 0, count: k)
        for r in stride(from: k - 1, through: 0, by: -1) {
            var s = b[r]
            for j in (r + 1)..<max(k, r + 1) { s -= a[r * k + j] * xs[j] }
            xs[r] = s / a[r * k + r]
        }
        return xs
    }

    public func score(_ x: [[Double]]) -> [Double] {
        x.map { row in
            var t = bias
            for j in 0..<weights.count { t += (row[j] - mean[j]) / std[j] * weights[j] }
            return 1.0 / (1.0 + exp(-min(max(t, -30), 30)))
        }
    }

    public func toJSON() -> [String: Any] {
        ["weights": weights, "bias": bias, "mean": mean, "std": std,
         "feature_version": featureVersion, "feature_names": featureNames]
    }

    public static func fromJSON(_ d: [String: Any]) throws -> LogisticModel {
        func doubles(_ key: String) throws -> [Double] {
            guard let v = d[key] as? [Any] else { throw AilbumError.decode("model json: missing \(key)") }
            return try v.map {
                guard let n = $0 as? NSNumber else { throw AilbumError.decode("model json: bad \(key)") }
                return n.doubleValue
            }
        }
        guard let b = d["bias"] as? NSNumber else { throw AilbumError.decode("model json: missing bias") }
        let fv = (d["feature_version"] as? NSNumber)?.intValue ?? 0
        let names = d["feature_names"] as? [String] ?? []
        return LogisticModel(weights: try doubles("weights"), bias: b.doubleValue, mean: try doubles("mean"),
                             std: try doubles("std"), featureVersion: fv, featureNames: names)
    }
}

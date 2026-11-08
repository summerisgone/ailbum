public enum Hull {
    /// Convex hull area of `points` divided by the frame area (Andrew monotone chain + shoelace).
    public static func coverage(_ points: [SIMD2<Float>], width: Int, height: Int) -> Double {
        guard points.count >= 3, width > 0, height > 0 else { return 0 }
        let pts = points.map { (Double($0.x), Double($0.y)) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        var hull: [(Double, Double)] = []
        for p in pts {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        let lower = hull.count + 1
        for p in pts.reversed().dropFirst() {
            while hull.count >= lower, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        hull.removeLast()
        guard hull.count >= 3 else { return 0 }
        var area = 0.0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.0 * b.1 - b.0 * a.1
        }
        return abs(area) / 2 / (Double(width) * Double(height))
    }
}

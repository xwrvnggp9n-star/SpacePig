import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000).
enum TreemapLayout {
    /// Returns one rectangle per value, in input order. Values should be sorted largest
    /// first for good aspect ratios. Zero values get an empty rectangle.
    static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var indices = Array(areas.indices.filter { areas[$0] > 0 })
        var free = rect

        while !indices.isEmpty {
            let side = Double(min(free.width, free.height))
            var row: [Int] = []
            var rowSum = 0.0
            var best = Double.infinity
            while let next = indices.first {
                let candidate = row + [next]
                let sum = rowSum + areas[next]
                let w = worst(candidate.map { areas[$0] }, sum: sum, side: side)
                if !row.isEmpty && w > best { break }
                row = candidate
                rowSum = sum
                best = w
                indices.removeFirst()
            }
            // Lay the row along the shorter side of the free rectangle.
            let thickness = CGFloat(rowSum / side)
            var offset: CGFloat = 0
            if free.width >= free.height {
                for i in row {
                    let h = CGFloat(areas[i]) / thickness
                    result[i] = CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: h)
                    offset += h
                }
                free = CGRect(x: free.minX + thickness, y: free.minY, width: max(free.width - thickness, 0), height: free.height)
            } else {
                for i in row {
                    let w = CGFloat(areas[i]) / thickness
                    result[i] = CGRect(x: free.minX + offset, y: free.minY, width: w, height: thickness)
                    offset += w
                }
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: max(free.height - thickness, 0))
            }
        }
        return result
    }

    /// Worst aspect ratio in a row of areas laid along a side of length `side`.
    private static func worst(_ row: [Double], sum: Double, side: Double) -> Double {
        guard let maxA = row.max(), let minA = row.min(), sum > 0, minA > 0 else { return .infinity }
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}

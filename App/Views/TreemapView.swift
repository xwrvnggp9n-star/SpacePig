import SwiftUI

/// Squarified treemap of the current folder's children. Click selects, double-click opens.
struct TreemapView: View {
    let items: [BrowserItem]
    let onOpen: (BrowserItem) -> Void
    @Binding var selected: BrowserItem?
    @State private var hovered: Int?

    /// Shows at most this many rectangles; the rest are drawn as one "other" block.
    private let maxItems = 120

    private var shown: [BrowserItem] {
        let sorted = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard sorted.count > maxItems else { return sorted }
        let head = Array(sorted.prefix(maxItems - 1))
        let rest = sorted.dropFirst(maxItems - 1).reduce(UInt64(0)) { $0 + $1.size }
        return head + [BrowserItem(id: "other", kind: .virtual("other"), name: "\(sorted.count - head.count) more items",
                                   size: rest, isContainer: false)]
    }

    var body: some View {
        GeometryReader { geo in
            let items = shown
            let rects = TreemapLayout.layout(values: items.map { Double($0.size) },
                                             in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (i, item) in items.enumerated() {
                        let r = rects[i].insetBy(dx: 1, dy: 1)
                        guard r.width > 0, r.height > 0 else { continue }
                        var color = color(for: i, item: item)
                        if selected?.id == item.id { color = color.opacity(1) }
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color))
                        if hovered == i || selected?.id == item.id {
                            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.primary), lineWidth: 2)
                        }
                        if r.width > 60, r.height > 30 {
                            let label = Text("\(item.name)\n\(ByteFormat.string(item.size))")
                                .font(.system(size: r.width > 160 && r.height > 50 ? 12 : 10))
                                .foregroundStyle(.white)
                            ctx.draw(label, in: r.insetBy(dx: 5, dy: 4))
                        }
                    }
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hovered = rects.firstIndex { $0.contains(p) } } else { hovered = nil }
                    }
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        if let i = rects.firstIndex(where: { $0.contains(v.location) }), items[i].id != "other" { onOpen(items[i]) }
                    }.exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                        if let i = rects.firstIndex(where: { $0.contains(v.location) }), items[i].id != "other" { selected = items[i] }
                    }))
            }
            .help(hovered.flatMap { $0 < items.count ? "\(items[$0].name): \(ByteFormat.string(items[$0].size))" : nil } ?? "")
        }
    }

    private func color(for i: Int, item: BrowserItem) -> Color {
        if item.id == "other" { return Color.gray.opacity(0.5) }
        let hue = Double((i * 47) % 360) / 360
        let base = Color(hue: hue, saturation: item.isContainer ? 0.55 : 0.35, brightness: item.isContainer ? 0.72 : 0.62)
        return base.opacity(selected == nil || selected?.id == item.id ? 0.95 : 0.75)
    }
}

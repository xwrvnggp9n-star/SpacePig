import AppKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let scope: BrowserScope

    enum Mode: String, CaseIterable { case list = "List", treemap = "Treemap" }
    @State private var mode: Mode = .list
    @State private var stack: [BrowserItem] = []
    @State private var selected: BrowserItem?
    @State private var showInspector = true

    private var browser: Browser { Browser(model: model, scope: scope) }

    private var items: [BrowserItem] {
        if let top = stack.last { return browser.children(of: top) }
        return browser.roots()
    }

    private var parentSize: UInt64 {
        if let top = stack.last { return top.size }
        return items.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            if model.data == nil && model.volumes == nil {
                ContentUnavailableView("No scan yet", systemImage: "internaldrive",
                                       description: Text("Click Scan in the toolbar."))
            } else if items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "folder",
                                       description: Text(model.data == nil ? "Scan the disk first." : "This folder has no contents in this view."))
            } else {
                switch mode {
                case .list: list
                case .treemap:
                    TreemapView(items: items, onOpen: open, selected: $selected)
                        .padding(8)
                }
            }
        }
        .navigationTitle(scope.title)
        .inspector(isPresented: $showInspector) {
            InspectorView(item: selected, browser: browser)
                .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button(scope.title) { stack = []; selected = nil }
                .buttonStyle(.link)
            ForEach(Array(stack.enumerated()), id: \.offset) { i, item in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Button(item.name) { stack = Array(stack.prefix(i + 1)); selected = nil }
                    .buttonStyle(.link)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteFormat.string(parentSize)).foregroundStyle(.secondary).monospacedDigit()
            if !stack.isEmpty {
                Button { _ = stack.popLast(); selected = nil } label: { Image(systemName: "arrow.up") }
                    .help("Up one level")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var list: some View {
        let maxSize = max(items.first?.size ?? 1, 1)
        return List(items, selection: Binding(get: { selected?.id }, set: { id in selected = items.first { $0.id == id } })) { item in
            HStack(spacing: 10) {
                Image(systemName: icon(for: item))
                    .foregroundStyle(item.isContainer ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                badges(item)
                Spacer(minLength: 12)
                SizeBar(fraction: Double(item.size) / Double(maxSize)).frame(width: 140, height: 8)
                Text(ByteFormat.string(item.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                if parentSize > 0 {
                    Text(percent(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                }
            }
            .tag(item.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(item) }
            .contextMenu { contextMenu(item) }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func badges(_ item: BrowserItem) -> some View {
        if item.flags.contains(.unreadable) { Badge(text: "unreadable", color: .orange) }
        if item.flags.contains(.dataless) { Badge(text: "in cloud", color: .cyan) }
        if item.flags.contains(.otherDevice) { Badge(text: "other volume", color: .gray) }
        if item.flags.contains(.purgeable) { Badge(text: "purgeable", color: .green) }
    }

    private func icon(for item: BrowserItem) -> String {
        if case .virtual = item.kind { return "cylinder" }
        if item.flags.contains(.aggregate) { return "doc.on.doc" }
        return item.flags.contains(.directory) ? "folder.fill" : "doc"
    }

    private func percent(_ size: UInt64) -> String {
        let p = Double(size) / Double(max(parentSize, 1)) * 100
        return p < 0.1 ? "<0.1%" : String(format: "%.1f%%", p)
    }

    private func open(_ item: BrowserItem) {
        guard item.isContainer else { selected = item; return }
        stack.append(item)
        selected = nil
    }

    @ViewBuilder private func contextMenu(_ item: BrowserItem) -> some View {
        if item.isContainer { Button("Open") { open(item) } }
        let d = browser.details(for: item)
        if let p = d.displayPath {
            Button("Reveal in Finder") { Inspector.reveal(p) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p, forType: .string)
            }
        }
    }
}

struct SizeBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), 2))
            }
        }
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

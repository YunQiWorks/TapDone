import AppKit
import SwiftUI

// Background and AppKit window use the same fixed one-magnified-icon budget.
enum DockMetrics {
    static let iconSize: CGFloat = 48
    static let scale: CGFloat = 1.45
    static let spacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 12
    static let shadowInset: CGFloat = 8

    static func backgroundSize(count: Int, horizontal: Bool) -> CGSize {
        let count = max(count, 1)
        let enlarged = iconSize * scale
        let length = CGFloat(count - 1) * (iconSize + spacing) + enlarged
        return horizontal
            ? CGSize(width: length + horizontalPadding * 2, height: enlarged + verticalPadding * 2)
            : CGSize(width: enlarged + horizontalPadding * 2, height: length + verticalPadding * 2)
    }
}

struct SidebarView: View {
    @ObservedObject var store: AppStore
    let dismiss: () -> Void
    let showName: (QuickAction?, CGRect?) -> Void
    @State private var hoveredID: String?
    @State private var buttonFrames: [String: CGRect] = [:]

    private var hoveredIndex: Int? {
        store.dockActions.firstIndex { $0.id == hoveredID }
    }

    private func magnification(at index: Int) -> CGFloat {
        hoveredIndex == index ? DockMetrics.scale : 1
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = store.activationEdge.horizontalDock
            let ideal = DockMetrics.backgroundSize(count: store.dockActions.count, horizontal: horizontal)
            let width = min(ideal.width, max(1, geometry.size.width - DockMetrics.shadowInset * 2))
            let height = min(ideal.height, max(1, geometry.size.height - DockMetrics.shadowInset * 2))
            ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                Group {
                    if horizontal {
                        HStack(spacing: DockMetrics.spacing) { dockButtons }
                    } else {
                        VStack(spacing: DockMetrics.spacing) { dockButtons }
                    }
                }
                .padding(.horizontal, DockMetrics.horizontalPadding)
                .padding(.vertical, DockMetrics.verticalPadding)
                .frame(minWidth: width, minHeight: height)
            }
            .frame(width: width, height: height)
            .background(DockMaterial())
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "dock")
        .animation(.easeInOut(duration: 0.16), value: hoveredID)
        .onPreferenceChange(DockButtonFrames.self) { frames in
            buttonFrames = frames
            updateName()
        }
        .onDisappear { hoveredID = nil; showName(nil, nil) }
    }

    @ViewBuilder
    private var dockButtons: some View {
        ForEach(Array(store.dockActions.enumerated()), id: \.element.id) { index, action in
            DockButton(action: action, size: DockMetrics.iconSize * magnification(at: index), hovered: hoveredID == action.id) {
                showName(nil, nil)
                dismiss()
                store.run(action)
            }
            .background(GeometryReader { buttonGeometry in
                Color.clear.preference(key: DockButtonFrames.self,
                    value: [action.id: buttonGeometry.frame(in: .named("dock"))])
            })
            .onHover { inside in
                if inside { hoveredID = action.id }
                else if hoveredID == action.id { hoveredID = nil }
                updateName()
            }
        }
    }

    private func updateName() {
        guard let action = store.dockActions.first(where: { $0.id == hoveredID }),
              let frame = buttonFrames[action.id] else { showName(nil, nil); return }
        showName(action, frame)
    }
}

private struct DockButtonFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DockMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct DockButton: View {
    let action: QuickAction
    let size: CGFloat
    let hovered: Bool
    let perform: () -> Void

    private var nativeIcon: CGImage? {
        if action.kind == .application,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.target) {
            return DockIconCache.image(forFile: url.path)
        }
        if action.kind == .folder || action.kind == .file {
            let path = (action.target as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            return DockIconCache.image(forFile: url.path)
        }
        return nil
    }

    var body: some View {
        Button(action: perform) {
            Group {
                if let icon = nativeIcon {
                    Image(decorative: icon, scale: 1).resizable().interpolation(.high).scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor], startPoint: .top, endPoint: .bottom))
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
                        Image(systemName: action.symbol)
                            .font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                    }
                    .padding(3)
                }
            }
            .frame(width: DockMetrics.iconSize, height: DockMetrics.iconSize)
            .scaleEffect(size / DockMetrics.iconSize)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(hovered ? 0.25 : 0.12), radius: hovered ? 4 : 2, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }
}

// Resolve the multi-representation system icon once at a stable pixel size.
// SwiftUI always receives the same bitmap throughout the magnification animation.
@MainActor
private enum DockIconCache {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func image(forFile path: String) -> CGImage? {
        let key = path as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        // Maximum visible size is about 70 points; 256 pixels also covers Retina.
        let pixels = 256
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let source = NSWorkspace.shared.icon(forFile: path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        cache.setObject(Entry(image), forKey: key, cost: pixels * pixels * 4)
        return image
    }
}

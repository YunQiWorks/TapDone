import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
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

    @MainActor
    private var nativeIcon: CGImage? {
        TaskIconProvider.image(for: action)
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
enum DockIconCache {
    final class Entry {
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

/// Shared presentation resolver; execution never reads icon resources.
@MainActor
enum TaskIconProvider {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SideTap/Resources/Icons", isDirectory: true)

    private static let assets = NSCache<NSString, DockIconCache.Entry>()

    static func image(for task: QuickAction) -> CGImage? {
        if let id = task.presentation?.iconAssetID, task.presentation?.isValid == true {
            if let cached = assets.object(forKey: id as NSString) { return cached.image }
            if let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(id + ".png") as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) {
                assets.totalCostLimit = 16 * 1024 * 1024
                assets.setObject(DockIconCache.Entry(image), forKey: id as NSString, cost: image.bytesPerRow * image.height)
                return image
            }
        }
        if let id = task.presentation?.builtinIconID,
           let icon = BuiltinTaskIcon.all.first(where: { $0.id == id }),
           let image = builtinImage(icon) { return image }
        if task.presentation?.useSymbol == true { return nil }
        if task.kind == .application, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: task.target) {
            return DockIconCache.image(forFile: url.path)
        }
        if task.kind == .folder || task.kind == .file {
            let path = (task.target as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            return DockIconCache.image(forFile: url.path)
        }
        return nil
    }

    private static func builtinImage(_ icon: BuiltinTaskIcon) -> CGImage? {
        let key = ("builtin:" + icon.id + ":" + NSColor.controlAccentColor.description) as NSString
        if let cached = assets.object(forKey: key) { return cached.image }
        let pixels = 256
        func makeContext() -> CGContext? {
            CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let source = NSImage(named: NSImage.Name(icon.assetName)),
              let glyph = makeContext(), let tile = makeContext() else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: glyph, flipped: false)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let mask = glyph.makeImage() else { return nil }
        tile.setFillColor(NSColor.controlAccentColor.cgColor)
        tile.addPath(CGPath(roundedRect: rect.insetBy(dx: 12, dy: 12), cornerWidth: 48, cornerHeight: 48, transform: nil))
        tile.fillPath()
        tile.clip(to: rect.insetBy(dx: 57, dy: 57), mask: mask)
        tile.setFillColor(NSColor.white.cgColor)
        tile.fill(rect)
        guard let image = tile.makeImage() else { return nil }
        assets.totalCostLimit = 16 * 1024 * 1024
        assets.setObject(DockIconCache.Entry(image), forKey: key, cost: pixels * pixels * 4)
        return image
    }

    static func importImage(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else {
            throw TapDoneError("INVALID_ICON", "请选择不超过 8 MB、1600 万像素的 PNG 或 JPEG 图片。")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw TapDoneError("INVALID_ICON", "无法编码图标。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TapDoneError("INVALID_ICON", "无法保存图标。") }
        let encoded = data as Data
        let id = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(id + ".png")
        if !FileManager.default.fileExists(atPath: target.path) {
            try encoded.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        return id
    }
}

struct TaskIconView: View {
    let task: QuickAction
    var imageOverride: CGImage? = nil
    var body: some View {
        Group {
            if let image = imageOverride ?? TaskIconProvider.image(for: task) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: task.symbol).resizable().scaledToFit().foregroundStyle(Color.accentColor) }
        }
    }
}

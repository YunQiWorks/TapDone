import AppKit
import SwiftUI

enum ActivationEdge: String, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "左边缘"
        case .right: return "右边缘"
        case .top: return "上边缘"
        case .bottom: return "下边缘"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
    var horizontalDock: Bool { self == .top || self == .bottom }
    var dockOnLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }

    func contains(_ point: NSPoint, screen: NSRect, range: CGFloat) -> Bool {
        guard screen.contains(point) else { return false }
        let left = point.x <= screen.minX + range
        let right = point.x >= screen.maxX - range
        let top = point.y >= screen.maxY - range
        let bottom = point.y <= screen.minY + range
        switch self {
        case .left: return left
        case .right: return right
        case .top: return top
        case .bottom: return bottom
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var library: TaskLibrary {
        didSet { persistLibrary() }
    }
    var categories: [TaskCategory] { library.categories }
    var actions: [QuickAction] { categories.flatMap(\.tasks) }
    // Dock order follows category order and the task order within each category.
    var dockActions: [QuickAction] {
        let pinned = Set(library.dockTaskIDs)
        return actions.filter { pinned.contains($0.id) }
    }
    func isInDock(_ id: String) -> Bool { library.dockTaskIDs.contains(id) }
    @Published var message = ""
    @Published var gestureEnabled: Bool { didSet { defaults.set(gestureEnabled, forKey: "gestureEnabled") } }
    @Published var activationEdge: ActivationEdge { didSet { defaults.set(activationEdge.rawValue, forKey: "activationEdge") } }
    @Published var edgeRange: Double { didSet { defaults.set(edgeRange, forKey: "edgeRange") } }
    @Published var dwellTime: Double { didSet { defaults.set(dwellTime, forKey: "dwellTime") } }
    private let defaults: UserDefaults
    private let executor = ActionExecutor()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "taskLibrary"),
           let saved = try? JSONDecoder().decode(TaskLibrary.self, from: data), saved.isValid {
            library = saved
        } else {
            let old = defaults.data(forKey: "quickActions")
                .flatMap { try? JSONDecoder().decode([QuickAction].self, from: $0) }
            let tasks = old.flatMap { Set($0.map(\.id)).count == $0.count ? $0 : nil } ?? QuickAction.examples
            library = TaskLibrary(categories: [TaskCategory(id: "default", name: "常用", tasks: tasks)], dockTaskIDs: tasks.map(\.id))
        }
        defaults.register(defaults: ["gestureEnabled": true, "edgeRange": 12.0, "dwellTime": 0.4])
        gestureEnabled = defaults.bool(forKey: "gestureEnabled")
        let edgeValue = defaults.string(forKey: "activationEdge") ?? defaults.string(forKey: "gestureDirection") ?? "left"
        activationEdge = ActivationEdge(rawValue: edgeValue) ?? .left
        let range = defaults.double(forKey: "edgeRange")
        edgeRange = range.isFinite ? min(max(range, 2), 120) : 12
        let dwell = defaults.double(forKey: "dwellTime")
        dwellTime = dwell.isFinite ? min(max(dwell, 0.1), 2) : 0.4
        persistLibrary()
    }

    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            defaults.set(data, forKey: "taskLibrary")
        }
    }

    func categoryID(for taskID: String) -> String? {
        categories.first { $0.tasks.contains { $0.id == taskID } }?.id
    }

    func saveCategory(id: String?, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var next = library
        if let id, let index = next.categories.firstIndex(where: { $0.id == id }) {
            next.categories[index].name = name
        } else {
            next.categories.append(TaskCategory(id: UUID().uuidString, name: name, tasks: []))
        }
        library = next
    }

    func deleteCategory(_ id: String) {
        var next = library
        let removed = Set(next.categories.first(where: { $0.id == id })?.tasks.map(\.id) ?? [])
        next.categories.removeAll { $0.id == id }
        next.dockTaskIDs.removeAll { removed.contains($0) }
        library = next
    }

    func moveCategory(_ id: String, by offset: Int) {
        var next = library
        guard let index = next.categories.firstIndex(where: { $0.id == id }),
              next.categories.indices.contains(index + offset) else { return }
        next.categories.swapAt(index, index + offset)
        library = next
    }

    func save(_ action: QuickAction, categoryID: String, inDock: Bool) {
        var next = library
        guard let destination = next.categories.firstIndex(where: { $0.id == categoryID }) else { return }
        let oldIndex = next.categories[destination].tasks.firstIndex { $0.id == action.id }
        for index in next.categories.indices {
            next.categories[index].tasks.removeAll { $0.id == action.id }
        }
        next.categories[destination].tasks.insert(action, at: oldIndex ?? next.categories[destination].tasks.count)
        next.dockTaskIDs.removeAll { $0 == action.id }
        if inDock { next.dockTaskIDs.append(action.id) }
        library = next
    }

    func setInDock(_ id: String, enabled: Bool) {
        guard actions.contains(where: { $0.id == id }) else { return }
        var next = library
        next.dockTaskIDs.removeAll { $0 == id }
        if enabled { next.dockTaskIDs.append(id) }
        library = next
    }

    func deleteTask(_ id: String) {
        var next = library
        for index in next.categories.indices { next.categories[index].tasks.removeAll { $0.id == id } }
        next.dockTaskIDs.removeAll { $0 == id }
        library = next
    }

    func move(_ id: String, by offset: Int) {
        var next = library
        guard let category = next.categories.firstIndex(where: { $0.tasks.contains { $0.id == id } }),
              let index = next.categories[category].tasks.firstIndex(where: { $0.id == id }),
              next.categories[category].tasks.indices.contains(index + offset) else { return }
        next.categories[category].tasks.swapAt(index, index + offset)
        library = next
    }

    func run(_ action: QuickAction) {
        Task {
            do {
                try await executor.execute(action)
                message = "已打开“\(action.title)”"
            } catch {
                message = "无法打开“\(action.title)”：\(error.localizedDescription)"
                let alert = NSAlert()
                alert.messageText = "动作执行失败"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}

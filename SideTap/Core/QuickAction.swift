import Foundation

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case application, website, folder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .application: return "应用"
        case .website: return "网址"
        case .folder: return "文件夹"
        }
    }
}

struct QuickAction: Identifiable, Codable {
    let id: String
    var title: String
    var subtitle: String
    var symbol: String
    var kind: ActionKind
    var target: String

    static let examples: [QuickAction] = [
        .init(id: "finder", title: "访达", subtitle: "浏览文件", symbol: "folder", kind: .application, target: "com.apple.finder"),
        .init(id: "safari", title: "Safari", subtitle: "打开浏览器", symbol: "safari", kind: .application, target: "com.apple.Safari"),
        .init(id: "terminal", title: "终端", subtitle: "开始命令行工作", symbol: "terminal", kind: .application, target: "com.apple.Terminal"),
        .init(id: "downloads", title: "下载", subtitle: "打开下载文件夹", symbol: "arrow.down.circle", kind: .folder, target: "Downloads"),
        .init(id: "github", title: "GitHub", subtitle: "发现开源项目", symbol: "globe", kind: .website, target: "https://github.com")
    ]
}

// Reserved for the portable action-pack format; importing and execution come later.
struct ActionPack: Codable {
    var formatVersion: Int = 1
    var name: String
    var actions: [QuickAction]
}

struct TaskCategory: Identifiable, Codable {
    let id: String
    var name: String
    var tasks: [QuickAction]
}

struct TaskLibrary: Codable {
    var formatVersion = 1
    var categories: [TaskCategory]
    var dockTaskIDs: [String]

    var isValid: Bool {
        let categoryIDs = categories.map(\.id)
        let taskIDs = categories.flatMap(\.tasks).map(\.id)
        return formatVersion == 1 && Set(categoryIDs).count == categoryIDs.count
            && Set(taskIDs).count == taskIDs.count
            && Set(dockTaskIDs).count == dockTaskIDs.count
            && Set(dockTaskIDs).isSubset(of: Set(taskIDs))
    }
}

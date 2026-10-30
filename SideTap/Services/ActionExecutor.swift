import AppKit

@MainActor
struct ActionExecutor {
    enum ExecutionError: LocalizedError {
        case missingApplication, invalidTarget, openFailed
        var errorDescription: String? {
            switch self {
            case .missingApplication: return "未找到应用，请检查是否已安装。"
            case .invalidTarget: return "目标地址无效。"
            case .openFailed: return "系统未能打开目标。"
            }
        }
    }

    func execute(_ action: QuickAction) async throws {
        switch action.kind {
        case .application:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.target) else {
                throw ExecutionError.missingApplication
            }
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website:
            guard let url = URL(string: action.target),
                  let scheme = url.scheme, ["https", "http"].contains(scheme.lowercased()), url.host != nil else {
                throw ExecutionError.invalidTarget
            }
            guard NSWorkspace.shared.open(url) else { throw ExecutionError.openFailed }
        case .folder:
            let expanded = (action.target as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded)
            guard NSWorkspace.shared.open(url) else { throw ExecutionError.openFailed }
        }
    }
}

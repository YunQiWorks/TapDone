import Foundation
import Darwin

/// A shared implementation used by the GUI and CLI. Never write a stale whole-library snapshot.
public final class TaskRepository {
    public let directoryURL: URL
    public var libraryURL: URL { directoryURL.appendingPathComponent("library.json") }
    private let legacyDefaults: UserDefaults

    public init(directoryURL: URL? = nil, legacyDefaults: UserDefaults? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideTap", isDirectory: true)
        self.legacyDefaults = legacyDefaults ?? UserDefaults(suiteName: "dev.sidetap.SideTap") ?? .standard
    }

    public func read(createIfMissing: Bool = false) throws -> TaskLibrary {
        try locked {
            let exists = FileManager.default.fileExists(atPath: libraryURL.path)
            let library = try loadUnlocked()
            if createIfMissing && !exists { try writeUnlocked(library) }
            return library
        }
    }

    @discardableResult
    public func transaction(expectedRevision: UInt64? = nil, _ change: (inout TaskLibrary) throws -> Void) throws -> TaskLibrary {
        try locked {
            var latest = try loadUnlocked()
            if let expectedRevision, latest.revision != expectedRevision {
                throw SideTapError("REVISION_CONFLICT", "任务库已变化，请重新读取后再修改。当前 revision：\(latest.revision)。")
            }
            let before = latest
            try change(&latest)
            guard latest.isValid else { throw SideTapError("INVALID_LIBRARY", "任务库结构无效，未保存。") }
            if latest != before || !FileManager.default.fileExists(atPath: libraryURL.path) {
                guard latest.revision < UInt64.max else { throw SideTapError("REVISION_OVERFLOW", "任务库版本已达到上限。") }
                latest.revision += 1
                try writeUnlocked(latest)
            }
            return latest
        }
    }

    /// Capture the latest library under the same lock used by the GUI and CLI.
    public func backupForApplicationUpdate() throws -> URL {
        try locked {
            let library = try loadUnlocked()
            let directory = directoryURL.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("library-before-update-" + UUID().uuidString + ".json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        }
    }

    private func loadUnlocked() throws -> TaskLibrary {
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            do {
                let data = try Data(contentsOf: libraryURL)
                let value = try JSONDecoder().decode(TaskLibrary.self, from: data)
                guard value.isValid else { throw SideTapError("INVALID_LIBRARY", "任务库内容不合法，原文件已保留。") }
                return value
            } catch let error as SideTapError { throw error }
            catch { throw SideTapError("READ_FAILED", "无法读取任务库，原文件已保留：\(error.localizedDescription)") }
        }
        // One-way migration, guarded by the same cross-process lock as normal writes.
        // Keep the original defaults intact as a backup.
        if let data = legacyDefaults.data(forKey: "taskLibrary") {
            do {
                let library = try JSONDecoder().decode(TaskLibrary.self, from: data)
                guard library.isValid else { throw SideTapError("INVALID_LEGACY_DATA", "旧任务库格式不正确，未覆盖旧配置。") }
                return library
            } catch let error as SideTapError { throw error }
            catch { throw SideTapError("INVALID_LEGACY_DATA", "无法迁移旧任务库：\(error.localizedDescription)") }
        }
        let tasks: [QuickAction]
        if let data = legacyDefaults.data(forKey: "quickActions") {
            do { tasks = try JSONDecoder().decode([QuickAction].self, from: data) }
            catch { throw SideTapError("INVALID_LEGACY_DATA", "无法迁移旧按钮：\(error.localizedDescription)") }
        } else { tasks = QuickAction.examples }
        let library = TaskLibrary(categories: [TaskCategory(id: "default", name: "常用", tasks: tasks)], dockTaskIDs: tasks.map(\.id))
        guard library.isValid else { throw SideTapError("INVALID_LEGACY_DATA", "旧按钮包含无效或重复任务。") }
        return library
    }

    private func writeUnlocked(_ library: TaskLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try encoder.encode(library).write(to: libraryURL, options: .atomic) }
        catch { throw SideTapError("WRITE_FAILED", "无法保存任务库：\(error.localizedDescription)") }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        do { try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true) }
        catch { throw SideTapError("STORAGE_UNAVAILABLE", "无法创建配置目录：\(error.localizedDescription)") }
        let lockURL = directoryURL.appendingPathComponent("library.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SideTapError("LOCK_FAILED", "无法打开任务库锁。") }
        defer { Darwin.close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw SideTapError("LOCK_FAILED", "无法锁定任务库。") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SideTapError("LIBRARY_BUSY", "任务库正在被其他进程修改，请稍后重试。") }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

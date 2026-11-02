import Foundation
import Combine

/// Session-only visibility. Dismissing a row never mutates or cancels its execution.
@MainActor
final class ActivityOverlayModel: ObservableObject {
    @Published private(set) var items: [RunActivity] = []
    @Published private(set) var manuallyPresented = false
    private var snapshots: [RunActivity] = []
    private var seen = Set<String>()
    private var session = Set<String>()
    private var dismissed = Set<String>()
    private var expiration: [String: Date] = [:]
    private var subscription: AnyCancellable?
    private var expirationTask: Task<Void, Never>?
    private let completionLifetime: TimeInterval = 5
    #if DEBUG
    private var previewAutoDismissCompleted = true
    #endif

    init(center: RunActivityCenter? = nil) {
        if let center {
            // Do not replay historical successes or failures when the app launches.
            snapshots = center.activities
            seen = Set(snapshots.map(\.id))
            session = Set(snapshots.filter { !$0.state.isTerminal }.map(\.id))
            refresh()
            subscription = center.$activities
                .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
                .sink { [weak self] in self?.receive($0) }
        }
    }

    /// Also accepts isolated development snapshots; it has no executor or repository.
    func receive(_ activities: [RunActivity]) {
        let ids = Set(activities.map(\.id))
        session.formUnion(ids.subtracting(seen))
        seen.formUnion(ids)
        session.formIntersection(ids)
        dismissed.formIntersection(ids)
        expiration = expiration.filter { ids.contains($0.key) }
        snapshots = activities
        #if DEBUG
        let autoDismissCompleted = previewAutoDismissCompleted
        #else
        let autoDismissCompleted = true
        #endif
        for activity in activities where session.contains(activity.id) {
            if autoDismissCompleted && (activity.state == .succeeded || activity.state == .cancelled) {
                if expiration[activity.id] == nil { expiration[activity.id] = Date().addingTimeInterval(completionLifetime) }
            } else { expiration.removeValue(forKey: activity.id) }
        }
        refresh()
    }

    #if DEBUG
    /// Reusing fixed fixture IDs must not inherit another preview scenario's dismissal/expiry.
    func replacePreviewSnapshots(_ activities: [RunActivity], autoDismissCompleted: Bool = true) {
        previewAutoDismissCompleted = autoDismissCompleted
        seen.removeAll(); session.removeAll(); dismissed.removeAll(); expiration.removeAll()
        manuallyPresented = false
        receive(activities)
    }
    #endif

    func dismiss(_ id: String) { dismissed.insert(id); refresh() }
    func hideAll() {
        dismissed.formUnion(session)
        manuallyPresented = false
        refresh()
    }
    func reveal() {
        dismissed.removeAll()
        manuallyPresented = true
        refresh()
    }
    func shutdown() {
        subscription?.cancel(); subscription = nil
        expirationTask?.cancel(); expirationTask = nil
    }

    private func refresh() {
        expirationTask?.cancel(); expirationTask = nil
        let now = Date()
        let visible = snapshots.filter {
            session.contains($0.id) && !dismissed.contains($0.id) && $0.parentWorkflowRunID == nil &&
            (expiration[$0.id].map { $0 > now } ?? true)
        }.sorted {
            let left = priority($0.state), right = priority($1.state)
            if left != right { return left < right }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
        if items != visible { items = visible }
        if let deadline = visible.compactMap({ expiration[$0.id] }).min() {
            let delay = max(0.05, deadline.timeIntervalSinceNow)
            expirationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    private func priority(_ state: RunActivity.State) -> Int {
        switch state {
        case .waitingReview: return 0
        case .running, .waitingExternal: return 1
        case .paused: return 2
        case .failed, .timedOut, .interrupted: return 3
        case .succeeded, .cancelled: return 4
        }
    }
}

enum ActivityOverlayPosition: String, CaseIterable, Identifiable {
    case topCenter, topLeft, topRight, bottomCenter, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topCenter: return "顶部居中"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomCenter: return "底部居中"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
    var isTop: Bool { self == .topCenter || self == .topLeft || self == .topRight }
}

@MainActor
final class ActivityOverlayPreferences: ObservableObject {
    @Published var position: ActivityOverlayPosition { didSet { defaults.set(position.rawValue, forKey: "activityOverlayPosition") } }
    @Published var verticalInset: Double {
        didSet {
            let value = Self.normalized(verticalInset)
            if verticalInset != value { verticalInset = value }
            defaults.set(value, forKey: "activityOverlayInset")
        }
    }
    @Published private(set) var revealRequest: UUID?
    func requestReveal() { revealRequest = UUID() }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        position = ActivityOverlayPosition(rawValue: defaults.string(forKey: "activityOverlayPosition") ?? "") ?? .topCenter
        verticalInset = Self.normalized(defaults.object(forKey: "activityOverlayInset") == nil ? 64 : defaults.double(forKey: "activityOverlayInset"))
    }
    func reset() { position = .topCenter; verticalInset = 64 }
    private static func normalized(_ value: Double) -> Double { value.isFinite ? min(200, max(16, value)) : 64 }
}

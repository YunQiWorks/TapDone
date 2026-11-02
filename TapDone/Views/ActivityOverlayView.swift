import SwiftUI

/// The compact card is shared by the live floating panel and development previews.
struct ActivityOverlayCard: View {
    let activity: RunActivity
    let task: QuickAction?
    let phase: String?
    let details: () -> Void
    let openLog: () -> Void
    let stop: () -> Void
    let dismiss: () -> Void
    var imageOverride: CGImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let task { TaskIconView(task: task, imageOverride: imageOverride).frame(width: 38, height: 38) }
                else { Image(systemName: activity.symbol).font(.title2).frame(width: 38, height: 38).foregroundStyle(Color.accentColor) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.title).font(.callout.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Label(activity.state.title, systemImage: stateSymbol).foregroundStyle(stateColor)
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsed(at: context.date)).monospacedDigit().fixedSize().foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(4).contentShape(Rectangle()).help("隐藏此运行，不停止任务").accessibilityLabel("隐藏此运行")
            }
            if let progress = activity.progress {
                ProgressView(value: progress.fraction).tint(stateColor)
                Text("完成 \(progress.completed) / \(progress.total) 个节点").font(.caption).foregroundStyle(.secondary)
            }
            Text(phase ?? message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 12) {
                Button(activity.state == .waitingReview ? "前往复核" : activity.source == .workflow ? "查看流程" : "查看详情", action: details)
                    .buttonStyle(.bordered).tint(Color.accentColor)
                if activity.capabilities.contains(.openLog) { Button("日志", action: openLog).buttonStyle(.borderless) }
                Spacer(minLength: 0)
                if activity.capabilities.contains(.stopTracking) {
                    Button("停止跟踪", action: stop).buttonStyle(.borderless)
                } else if activity.capabilities.contains(.stop) {
                    Button(activity.source == .workflow ? "停止流程" : "停止", action: stop).buttonStyle(.borderless)
                }
            }.controlSize(.small).font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var stateColor: Color {
        switch activity.state {
        case .failed, .timedOut, .interrupted: return .red
        case .succeeded: return .green
        default: return .accentColor
        }
    }
    private var stateSymbol: String {
        switch activity.state {
        case .running: return "play.circle"
        case .waitingExternal: return "clock.arrow.circlepath"
        case .waitingReview: return "person.crop.circle.badge.questionmark"
        case .paused: return "pause.circle"
        case .succeeded: return "checkmark.circle"
        case .failed, .timedOut, .interrupted: return "exclamationmark.circle"
        case .cancelled: return "stop.circle"
        }
    }
    private var message: String {
        if activity.state == .succeeded, let task,
           [.application, .website, .folder, .file].contains(task.kind) {
            return "系统已接受打开请求，不代表后续操作完成。"
        }
        switch activity.state {
        case .running: return "任务正在执行。"
        case .waitingExternal: return "服务器已接收作业，正在等待最终结果。"
        case .waitingReview: return "需要核对上游产物，批准后才会继续。"
        case .paused: return "流程已暂停，打开详情后可确认继续。"
        case .succeeded: return "已完成。打开详情查看具体结果。"
        case .failed: return "执行失败，请查看详情或日志。"
        case .timedOut: return "等待超时，请确认实际执行结果。"
        case .interrupted: return "最终结果未确认，不会自动重跑。"
        case .cancelled: return "已停止本地执行或跟踪；远程作业可能仍在运行。"
        }
    }
    private func elapsed(at now: Date) -> String {
        let total = Int(min(999_999_999, max(0, (activity.finishedAt ?? now).timeIntervalSince(activity.startedAt))))
        return total < 3600 ? String(format: "%02d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

struct ActivityOverlayView: View {
    @ObservedObject var model: ActivityOverlayModel
    let contentHeight: CGFloat
    let task: (RunActivity) -> QuickAction?
    let image: (RunActivity) -> CGImage?
    let phase: (RunActivity) -> String?
    let details: (RunActivity) -> Void
    let openLog: (RunActivity) -> Void
    let stop: (RunActivity) -> Void
    let showActivities: () -> Void

    var body: some View {
        if model.items.count == 1, let activity = model.items.first {
            card(for: activity)
        } else {
            collection
        }
    }

    private func card(for activity: RunActivity) -> some View {
        ActivityOverlayCard(activity: activity, task: task(activity), phase: phase(activity),
            details: { details(activity) }, openLog: { openLog(activity) }, stop: { stop(activity) },
            dismiss: { model.dismiss(activity.id) }, imageOverride: image(activity))
    }

    private var collection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path").foregroundStyle(Color.accentColor)
                Text("任务运行").font(.headline)
                Text("\(model.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("查看全部", action: showActivities).font(.caption).buttonStyle(.plain)
                Button { model.hideAll() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("隐藏浮窗，不停止任务").accessibilityLabel("隐藏浮窗")
            }.padding(14)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.items.isEmpty {
                        Text("目前没有进行中的任务").font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(model.items) { activity in
                        card(for: activity)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 4)
            }.frame(height: contentHeight)
            HStack {
                Text("关闭只隐藏，不停止任务").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color.accentColor.opacity(0.3)))
    }
}

struct ActivityOverlaySettingsView: View {
    @ObservedObject var preferences: ActivityOverlayPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("任务运行浮窗").font(.headline)
            Text("默认显示在屏幕顶部居中、菜单栏下方 64 点。修改会立即移动已显示的浮窗，位置将在重启后保留。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("显示位置", selection: $preferences.position) {
                    ForEach(ActivityOverlayPosition.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("距\(preferences.position.isTop ? "顶部" : "底部")：\(Int(preferences.verticalInset)) 点")
                    Slider(value: $preferences.verticalInset, in: 16...200, step: 8)
                }
            }
            HStack {
                Button("显示浮窗") { preferences.requestReveal() }.buttonStyle(.borderedProminent)
                Button("恢复默认位置") { preferences.reset() }
            }
            Text("“显示浮窗”会立即打开窗口，即使没有正在运行的任务，也会显示空白状态，便于确认位置。")
                .font(.caption).foregroundStyle(.secondary)
            Text("边距从屏幕可用区域计算，会避开菜单栏与系统 Dock。多显示器时优先使用任务启动时鼠标所在屏幕。")
                .font(.caption).foregroundStyle(.secondary)
            Text("浮窗已隐藏时，可从菜单栏选择“任务运行状态…”重新显示。关闭浮窗不会停止任务。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16)
    }
}

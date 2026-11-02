import SwiftUI

/// Data and callbacks only: both live execution and the development gallery use this card.
struct TaskRunSummaryCard: View {
    let run: TaskRun?
    let showHistory: () -> Void
    let openLog: () -> Void
    let openResult: () -> Void
    let stop: () -> Void
    var body: some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近运行").font(.headline)
                    Spacer()
                    Button("全部记录", action: showHistory).font(.callout)
                }
                if let run {
                    HStack {
                        Label(run.state.title, systemImage: symbol(run.state))
                            .foregroundStyle(run.state == .failed || run.state == .timedOut ? Color.red : Color.primary)
                        Spacer()
                        Text(run.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = run.summary { Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let remote = run.remoteJob { LabeledContent("远程作业", value: remote.jobID).font(.caption).textSelection(.enabled) }
                    if let code = run.exitCode { Text("退出码 \(code)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let output = run.output {
                        DisclosureGroup("查看返回内容") { ExecutionJSONView(value: output) }.font(.callout)
                    }
                    HStack {
                        Button("查看日志", action: openLog)
                        if run.resultURL != nil { Button("查看结果文件", action: openResult) }
                        Spacer()
                        if run.canStop { Button(run.definition.externalProgram?.asyncOptions == nil ? "停止任务" : "停止跟踪", action: stop) }
                    }
                } else {
                    Label("还没有运行记录", systemImage: "clock").foregroundStyle(.secondary)
                    Text("点击“执行任务”后，可在这里查看状态与结果。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func symbol(_ state: TaskRun.State) -> String {
        switch state {
        case .running: return "play.circle"
        case .waitingExternal: return "clock.arrow.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed, .timedOut: return "exclamationmark.circle"
        case .cancelled, .interrupted: return "pause.circle"
        }
    }
}

struct ExecutionJSONView: View {
    let value: JSONValue
    private var text: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法显示内容"
    }
    var body: some View {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RunActivityRow: View {
    let activity: RunActivity
    let task: QuickAction?
    let openLog: () -> Void
    let showWorkflow: () -> Void
    let stop: () -> Void
    var iconOverride: CGImage? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let task { TaskIconView(task: task, imageOverride: iconOverride).frame(width: 28, height: 28) }
            else { Image(systemName: activity.symbol).frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.title).fontWeight(.medium)
                    Spacer()
                    Text(activity.state.title).foregroundStyle(.secondary)
                }
                Text(activity.source == .workflow ? "流程" : activity.parentWorkflowRunID == nil ? "任务" : "流程子任务")
                    .font(.caption).foregroundStyle(.secondary)
                if let progress = activity.progress {
                    ProgressView(value: progress.fraction)
                    Text("完成 \(progress.completed) / \(progress.total) 个节点").font(.caption)
                }
                Text(activity.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if activity.capabilities.contains(.openLog) { Button("查看日志", action: openLog) }
                    if activity.source == .workflow, !activity.state.isTerminal {
                        Button(activity.capabilities.contains(.review) ? "前往复核" : "查看流程", action: showWorkflow)
                    }
                    if activity.source == .task, activity.capabilities.contains(.stop) || activity.capabilities.contains(.stopTracking) {
                        Button(activity.capabilities.contains(.stopTracking) ? "停止跟踪" : "停止", action: stop)
                    }
                }.font(.caption)
            }
        }.padding(.vertical, 6)
    }
}

struct WorkflowNodeStatusView: View {
    let node: WorkflowInstance.Node
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(name); Spacer(); Text(node.state.title).foregroundStyle(.secondary) }
            if let message = node.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

struct WorkspaceStorageError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Spacer()
            Button("重新读取", action: retry)
        }.padding(16)
    }
}

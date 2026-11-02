#if DEBUG
import AppKit
import SwiftUI

/// A development feature, not a task runner: fixtures never enter a repository or coordinator.
private enum PreviewScenario: String, CaseIterable, Identifiable {
    case idle, running, succeeded, failed, timedOut, cancelled, interrupted
    case submitting, waiting, remoteSucceeded, queryInterrupted
    case flowRunning, flowPartial, flowBlocked, flowPaused, flowSucceeded, flowCancelled
    case reviewWaiting, reviewApproved, reviewRejected
    case longTitle, longOutput, icons, customImage, missingIcon, empty, storageError
    var id: String { rawValue }
    var group: String {
        switch self {
        case .idle, .running, .succeeded, .failed, .timedOut, .cancelled, .interrupted: return "普通任务"
        case .submitting, .waiting, .remoteSucceeded, .queryInterrupted: return "异步作业"
        case .flowRunning, .flowPartial, .flowBlocked, .flowPaused, .flowSucceeded, .flowCancelled: return "上下游流程"
        case .reviewWaiting, .reviewApproved, .reviewRejected: return "人工复核"
        default: return "图标与边界"
        }
    }
    var title: String {
        switch self {
        case .idle: return "尚未运行"
        case .running: return "运行中"
        case .succeeded: return "执行成功"
        case .failed: return "执行失败"
        case .timedOut: return "执行超时"
        case .cancelled: return "已停止"
        case .interrupted: return "意外中断"
        case .submitting: return "提交远程作业"
        case .waiting: return "等待远程结果"
        case .remoteSucceeded: return "远程作业完成"
        case .queryInterrupted: return "查询中断"
        case .flowRunning: return "流程启动"
        case .flowPartial: return "部分节点完成"
        case .flowBlocked: return "失败阻断下游"
        case .flowPaused: return "流程暂停"
        case .flowSucceeded: return "流程完成"
        case .flowCancelled: return "流程已停止"
        case .reviewWaiting: return "等待人工复核"
        case .reviewApproved: return "复核通过"
        case .reviewRejected: return "复核驳回"
        case .longTitle: return "超长任务名称"
        case .longOutput: return "长返回内容"
        case .icons: return "内置图标总览"
        case .customImage: return "自定义图片图标"
        case .missingIcon: return "自定义图标缺失"
        case .empty: return "空白状态"
        case .storageError: return "存储错误"
        }
    }
    static let groups = ["普通任务", "异步作业", "上下游流程", "人工复核", "图标与边界"]
    var sequence: [Self] {
        switch group {
        case "普通任务": return [.idle, .running, .succeeded]
        case "异步作业": return [.submitting, .waiting, .remoteSucceeded]
        case "上下游流程": return [.flowRunning, .flowPartial, .reviewWaiting, .reviewApproved, .flowSucceeded]
        case "人工复核": return [.reviewWaiting, .reviewApproved, .flowSucceeded]
        default: return [.longTitle, .longOutput, .icons, .customImage, .missingIcon, .empty, .storageError]
        }
    }
}

@MainActor
private final class ExecutionPreviewModel: ObservableObject {
    @Published private(set) var scenario: PreviewScenario = .idle
    @Published private(set) var run: TaskRun?
    @Published private(set) var flow: WorkflowInstance?
    @Published private(set) var playing = false
    @Published private(set) var fixtureError = ""
    @Published var notice = ""
    @Published var reviewError = ""
    @Published var requestReview = false
    @Published var autoDismissCompleted = false { didSet { synchronizeOverlay() } }
    private var previewOverlay: ActivityOverlayController?
    private var playback: Task<Void, Never>?
    private var template: WorkflowInstance?
    private let startedAt = Date()
    private let runID = "00000000-0000-4000-8000-000000000001"
    var task: QuickAction { run?.definition ?? makeTask() }
    var context: WorkflowReviewContext? { flow?.nodes.first(where: { $0.id == "review" })?.context }

    var floatingActivity: RunActivity? {
        if let flow { return RunActivity(workflow: flow) }
        return run.map { RunActivity(task: $0) }
    }
    func openOverlay(preferences: ActivityOverlayPreferences) {
        if scenario == .idle {
            select(.running)
            notice = "未运行场景没有运行实例，已切换到“运行中”供浮窗预览。"
        }
        if previewOverlay == nil {
            previewOverlay = ActivityOverlayController(model: ActivityOverlayModel(), preferences: preferences,
                task: { [weak self] _ in self?.run?.definition }, phase: { _ in nil },
                details: { [weak self] activity in
                    if activity.state == .waitingReview { self?.stopPlayback(); self?.requestReview = true }
                    else { self?.notice = "这是模拟详情入口，不会打开真实任务。" }
                }, openLog: { [weak self] _ in self?.notice = "[浮窗预览] 没有读取或创建真实日志。" },
                stop: { [weak self] activity in
                    if activity.source == .workflow { self?.select(.flowCancelled) } else { self?.simulatedStop() }
                }, showActivities: { [weak self] in self?.notice = "这是模拟活动入口，不会改变真实任务。" },
                image: { [weak self] _ in
                    guard self?.scenario == .customImage else { return nil }
                    var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
                    return NSApp.applicationIconImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                }, windowName: "TapDone · 效果预览")
        }
        synchronizeOverlay()
    }
    func closeOverlay() {
        stopPlayback()
        previewOverlay?.shutdown(); previewOverlay = nil
    }
    private func synchronizeOverlay() {
        guard let overlay = previewOverlay else { return }
        let activity = floatingActivity
        overlay.model.replacePreviewSnapshots(activity.map { [$0] } ?? [], autoDismissCompleted: autoDismissCompleted)
        if !autoDismissCompleted || activity == nil { overlay.reveal() }
        else { overlay.showCurrentState() }
    }

    init() {
        do {
            let definition = try WorkflowDefinition.decode(Data(#"{"schemaVersion":1,"id":"preview.flow","name":"构建 → 复核 → 发布","nodes":[{"id":"build","name":"构建产物","kind":"task","taskID":"preview.build"},{"id":"review","name":"人工复核","kind":"review","dependsOn":["build"]},{"id":"publish","name":"发布产物","kind":"task","taskID":"preview.publish","dependsOn":["review"]}]}"#.utf8))
            // Rendering snapshot only: never submitted to WorkflowRunner.
            let plan = WorkflowPlan(definition: definition, libraryRevision: 0,
                                    orderedNodeIDs: ["build", "review", "publish"], taskSnapshots: [:])
            template = WorkflowInstance(plan: plan)
            render()
        } catch { fixtureError = error.localizedDescription }
    }
    func select(_ scenario: PreviewScenario) {
        stopPlayback(); self.scenario = scenario; notice = ""; render()
    }
    func stopPlayback() { playback?.cancel(); playback = nil; playing = false }
    func reset() { select(scenario.sequence[0]) }
    func play() {
        stopPlayback()
        let sequence = scenario.sequence
        playing = true
        scenario = sequence[0]; render()
        playback = Task { @MainActor [weak self] in
            for step in sequence.dropFirst() {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.scenario = step; self.render()
            }
            self?.playing = false
            self?.playback = nil
        }
    }
    func simulatedStop() {
        select(scenario.group == "异步作业" ? .queryInterrupted : .cancelled)
        notice = "仅改变预览状态，没有停止或取消真实作业。"
    }
    func decide(approved: Bool, reason: String) -> Bool {
        guard let context else { return false }
        do {
            _ = try context.decide(approved: approved, expectedDigest: context.digest(), reviewer: "开发预览", reason: reason)
            select(approved ? .reviewApproved : .reviewRejected)
            if let index = flow?.nodes.firstIndex(where: { $0.id == "review" }) {
                flow?.nodes[index].approval = try context.decide(approved: approved, expectedDigest: context.digest(), reviewer: "开发预览", reason: reason)
            }
            notice = "复核只保存在当前预览内存中，不授权或执行真实任务。"
            return true
        } catch { reviewError = error.localizedDescription; return false }
    }
    private func makeTask() -> QuickAction {
        let remote = scenario.group == "异步作业"
        let program = ExternalProgram(executable: "/preview/adapter", input: .object(["configuration": .string("Release")]),
            options: .init(workingDirectory: "/preview/project"), protocolVersion: 2,
            asyncOptions: remote ? .init() : nil)
        return QuickAction(id: "preview.task", title: scenario == .longTitle ? "为 macOS 构建并上传包含多语言资源与完整符号文件的正式安装包 · 一个用于检查换行和布局的超长任务名称" : remote ? "远程打包服务器" : "构建发布包",
            subtitle: "仅用于查看界面效果", symbol: "terminal", kind: .external, target: program.executable, externalProgram: program,
            presentation: .init(iconAssetID: scenario == .missingIcon ? String(repeating: "0", count: 64) : nil, builtinIconID: "package"))
    }
    private func render() {
        defer { synchronizeOverlay() }
        fixtureError = ""; reviewError = ""; run = nil; flow = nil
        do {
            if scenario.group == "上下游流程" || scenario.group == "人工复核" {
                guard var snapshot = template else { throw TapDoneError("PREVIEW_FIXTURE", "流程预览数据不可用。") }
                let reviewContext = WorkflowReviewContext(workflowRunID: snapshot.id, nodeID: "review", inputs: [
                    "build": .init(runID: runID, output: .object(["artifact": .string("preview-package.zip"), "sha256": .string(String(repeating: "a", count: 64)), "sizeBytes": .number(12_345_678)]))
                ])
                snapshot.nodes[1].context = reviewContext
                snapshot.nodes[0].state = scenario == .flowRunning ? .running : .succeeded
                snapshot.nodes[0].childRunID = runID
                switch scenario {
                case .flowRunning: snapshot.state = .running
                case .flowPartial:
                    snapshot.state = .running; snapshot.nodes[1].state = .starting
                case .flowBlocked:
                    snapshot.state = .failed; snapshot.nodes[0].state = .failed
                    snapshot.nodes[0].message = "构建失败，依赖节点保持待执行。"
                case .flowCancelled:
                    snapshot.state = .cancelled; snapshot.message = "流程已停止，未启动后续节点。"
                case .flowPaused:
                    snapshot.state = .paused; snapshot.message = "重启后暂停，等待用户确认继续。"
                case .reviewWaiting:
                    snapshot.state = .waitingReview; snapshot.nodes[1].state = .waitingReview
                case .reviewApproved, .flowSucceeded:
                    snapshot.nodes[1].state = .approved
                    snapshot.nodes[1].approval = try reviewContext.decide(approved: true, expectedDigest: reviewContext.digest(), reviewer: "开发预览", reason: "已核对预览产物")
                    snapshot.state = scenario == .flowSucceeded ? .succeeded : .running
                    snapshot.nodes[2].state = scenario == .flowSucceeded ? .succeeded : .running
                case .reviewRejected:
                    snapshot.state = .failed; snapshot.nodes[1].state = .rejected
                    snapshot.nodes[1].approval = try reviewContext.decide(approved: false, expectedDigest: reviewContext.digest(), reviewer: "开发预览", reason: "产物需要重新检查")
                default: break
                }
                if snapshot.state.terminal { snapshot.finishedAt = Date() }
                flow = snapshot
                return
            }
            if [.idle, .icons, .empty, .storageError].contains(scenario) { return }
            var snapshot = TaskRun(id: runID, definition: makeTask(), logURL: URL(fileURLWithPath: "/preview/logs/run.log"), startedAt: startedAt)
            if [.waiting, .remoteSucceeded, .queryInterrupted].contains(scenario) {
                try snapshot.waitForRemote(.init(jobID: "preview-job-2026-001", deadline: startedAt.addingTimeInterval(3600), nextPollAt: startedAt.addingTimeInterval(5)), message: "服务器已接受作业，正在等待最终结果。")
            }
            switch scenario {
            case .succeeded, .remoteSucceeded, .longOutput:
                let output: JSONValue = scenario == .longOutput ? .object(["files": .array((1...30).map { .object(["name": .string("artifact-\($0).zip"), "status": .string("已完成")]) })]) : .object(["artifact": .string("TapDone-preview.zip"), "verified": .bool(true)])
                try snapshot.complete(state: .succeeded, exitCode: 0, summary: "产物已生成，返回内容通过校验。", output: output)
                snapshot.resultURL = URL(fileURLWithPath: "/preview/results/result.json")
            case .failed: try snapshot.complete(state: .failed, exitCode: 1, summary: "构建工具返回非零退出码，请检查日志。")
            case .timedOut: try snapshot.complete(state: .timedOut, exitCode: nil, summary: "执行超过设定时间，已停止等待。")
            case .cancelled: try snapshot.complete(state: .cancelled, exitCode: nil, summary: "用户已请求停止任务。")
            case .interrupted, .queryInterrupted: try snapshot.complete(state: .interrupted, exitCode: nil, summary: "未能确认最终结果，不会自动重新提交。")
            default: break
            }
            run = snapshot
        } catch { fixtureError = error.localizedDescription }
    }
}

@MainActor
struct ExecutionPreviewView: View {
    @ObservedObject var overlayPreferences: ActivityOverlayPreferences
    @StateObject private var model = ExecutionPreviewModel()
    @State private var showReview = false
    @State private var appearance = "system"
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("效果预览").font(.system(size: 26, weight: .semibold))
                    Text("开发版专用 · 内存模拟，不执行任务、不写入任务库").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.frame(width: 130)
            }
            HStack {
                Picker("场景", selection: Binding(get: { model.scenario }, set: { model.select($0) })) {
                    ForEach(PreviewScenario.groups, id: \.self) { group in
                        Section(group) {
                            ForEach(PreviewScenario.allCases.filter { $0.group == group }) { Text($0.title).tag($0) }
                        }
                    }
                }
                Button(model.playing ? "暂停" : "模拟播放") { if model.playing { model.stopPlayback() } else { model.play() } }
                Button("重置") { model.reset() }
                Button("弹出运行浮窗") { model.openOverlay(preferences: overlayPreferences) }
            }
            HStack {
                Picker("浮窗位置", selection: $overlayPreferences.position) {
                    ForEach(ActivityOverlayPosition.allCases) { Text($0.title).tag($0) }
                }
                Text("边距 \(Int(overlayPreferences.verticalInset)) 点").font(.caption).foregroundStyle(.secondary)
                Slider(value: $overlayPreferences.verticalInset, in: 16...200, step: 8).frame(maxWidth: 150)
            }
            Toggle("预览完成后自动收起（5 秒）", isOn: $model.autoDismissCompleted)
                .font(.caption).toggleStyle(.checkbox)
            if !model.fixtureError.isEmpty { WorkspaceStorageError(message: model.fixtureError) { model.reset() } }
            if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewContent
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }.padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme ?? systemScheme)
            .onChange(of: model.requestReview) { value in
                if value { model.requestReview = false; presentReview() }
            }
            .onDisappear {
                model.closeOverlay()
            }
            .sheet(isPresented: $showReview) {
                if let context = model.context {
                    WorkflowReviewView(context: context, error: model.reviewError, decide: model.decide)
                }
            }
    }
    @ViewBuilder
    private var previewContent: some View {
        if let activity = floatingActivity {
            Text("独立运行浮窗卡片").font(.headline)
            ActivityOverlayCard(activity: activity, task: activity.source == .task ? model.run?.definition : nil, phase: nil,
                details: { if activity.state == .waitingReview { presentReview() } else { simulatedHistory() } },
                openLog: simulatedLog, stop: {
                    if activity.source == .workflow { model.select(.flowCancelled) } else { model.simulatedStop() }
                }, dismiss: { model.notice = "此处为卡片预览；真正的隐藏效果可点击“弹出运行浮窗”查看。" }, imageOverride: sampleImage)
            Divider()
        }
        if model.scenario == .storageError {
            WorkspaceStorageError(message: "无法保存运行记录：配置目录暂时不可写（模拟）。") {
                model.notice = "已模拟重新读取，没有访问真实配置目录。"
            }
        } else if model.scenario == .empty {
            WorkspaceCard { Text("暂无活动").foregroundStyle(.secondary).padding(.vertical, 24) }
            TaskRunSummaryCard(run: nil, showHistory: simulatedHistory, openLog: simulatedLog, openResult: simulatedResult, stop: model.simulatedStop)
        } else if model.scenario == .icons {
            iconGallery
        } else if let flow = model.flow {
            WorkspaceCard {
                RunActivityRow(activity: RunActivity(workflow: flow), task: nil, openLog: simulatedLog,
                    showWorkflow: { if flow.state == .waitingReview { presentReview() } else { model.notice = "下方即为流程节点预览。" } }, stop: model.simulatedStop)
            }
            WorkspaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(flow.plan.definition.name).font(.headline)
                    if let message = flow.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    ForEach(flow.nodes) { node in
                        WorkflowNodeStatusView(node: node, name: flow.plan.definition.nodes.first(where: { $0.id == node.id })?.name ?? node.id)
                        if let receipt = node.approval { Text("\(receipt.reviewer) · \(receipt.approved ? "批准" : "驳回")：\(receipt.reason)").font(.caption) }
                        if node.state == .waitingReview { Button("复核…") { presentReview() } }
                        if node.id != flow.nodes.last?.id { Divider() }
                    }
                    if flow.state == .paused { Button("模拟继续") { model.select(.flowPartial) } }
                    if !flow.state.terminal { Button("模拟停止流程") { model.select(.flowCancelled) } }
                }
            }
        } else {
            HStack(spacing: 16) {
                TaskIconView(task: model.task, imageOverride: sampleImage).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.task.title).font(.title2.weight(.semibold))
                    Text(model.scenario == .missingIcon ? "缺失图片时，回退到内置图标" : model.scenario.title).foregroundStyle(.secondary)
                }
            }
            if model.scenario == .customImage {
                Text("使用应用内置图片模拟自定义图标，不读取用户图片。").font(.caption).foregroundStyle(.secondary)
            }
            if let run = model.run {
                WorkspaceCard { RunActivityRow(activity: RunActivity(task: run), task: run.definition, openLog: simulatedLog, showWorkflow: {}, stop: model.simulatedStop, iconOverride: sampleImage) }
            }
            TaskRunSummaryCard(run: model.run, showHistory: simulatedHistory, openLog: simulatedLog, openResult: simulatedResult, stop: model.simulatedStop)
                .id(model.scenario)
        }
    }
    private var iconGallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                TaskIconView(task: QuickAction.examples[0]).frame(width: 48, height: 48)
                Text("原生应用图标与内置 Lucide 图标").font(.headline)
            }
            ForEach(BuiltinTaskIcon.categories, id: \.self) { category in
                Text(category).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74))], spacing: 14) {
                    ForEach(BuiltinTaskIcon.all.filter { $0.category == category }) { icon in
                        VStack(spacing: 6) {
                            TaskIconView(task: QuickAction(id: "preview.icon." + icon.id, title: icon.title, symbol: "star", kind: .website, target: "https://example.invalid", presentation: .init(builtinIconID: icon.id)))
                                .frame(width: 42, height: 42)
                            Text(icon.title).font(.caption)
                        }
                    }
                }
            }
        }
    }
    private var floatingActivity: RunActivity? { model.floatingActivity }
    private var sampleImage: CGImage? {
        guard model.scenario == .customImage else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        return NSApp.applicationIconImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    private func presentReview() { model.stopPlayback(); showReview = true }
    private func simulatedHistory() { model.notice = "这是模拟记录，未打开真实运行历史。" }
    private func simulatedLog() { model.notice = "[预览日志] 开始 → 执行 → 等待返回。没有读取或创建日志文件。" }
    private func simulatedResult() { model.notice = "结果仅在当前卡片的“查看返回内容”中显示，没有创建结果文件。" }
}
#endif

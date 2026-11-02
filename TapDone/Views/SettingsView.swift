import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: AppUpdateController
    @State private var destination: WorkspaceDestination = .tasks
    @State private var settingsSection = "gesture"
    @State private var workflowFocus: WorkspaceOpenRequest?
    @State private var draft: TaskEditorDraft?
    @State private var pendingIntent: WorkspaceIntent?
    @State private var confirmingDiscard = false
    @State private var deletingTask: QuickAction?
    @State private var confirmingDelete = false
    @State private var editingCategory = false
    @State private var categoryDraftID: String?
    @State private var categoryName = ""
    @State private var deletingCategory: TaskCategory?
    @State private var confirmingCategoryDelete = false

    private struct TaskEditorDraft: Identifiable {
        let id = UUID()
        let action: QuickAction
        let categoryID: String
        let inDock: Bool
        let revision: UInt64
    }
    private enum WorkspaceIntent {
        case navigate(WorkspaceDestination), edit(QuickAction), newTask, openRun(WorkspaceOpenRequest)
    }
    private var activeCategory: TaskCategory? {
        switch destination {
        case .task(let id): return store.categories.first { $0.tasks.contains { $0.id == id } }
        case .category(let id): return store.categories.first { $0.id == id }
        default: return store.categories.first
        }
    }

    var body: some View {
        HSplitView {
            TaskNavigationView(store: store, activities: store.activities, destination: destination,
                select: { request(.navigate($0)) }, newTask: { request(.newTask) },
                newCategory: { editCategory(nil) }, importTasks: chooseTaskDocument,
                editTask: { request(.edit($0)) }, deleteTask: { deletingTask = $0; confirmingDelete = true },
                renameCategory: { editCategory($0) }, deleteCategory: { deletingCategory = $0; confirmingCategoryDelete = true })
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            VStack(spacing: 0) {
                if !store.storageError.isEmpty {
                    WorkspaceStorageError(message: store.storageError) { store.refreshLibrary() }
                    Divider()
                }
                if let draft { inlineEditor(draft) }
                else { workspace.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                if !store.message.isEmpty {
                    Divider()
                    HStack {
                        Text(store.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 600, idealHeight: 760)
        .onReceive(store.$workspaceOpenRequest) { value in
            guard let value else { return }
            DispatchQueue.main.async {
                guard store.workspaceOpenRequest?.id == value.id else { return }
                store.workspaceOpenRequest = nil
                request(.openRun(value))
            }
        }
        .alert("放弃尚未保存的修改？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) { pendingIntent = nil }
            Button("放弃修改", role: .destructive) {
                draft = nil
                if let intent = pendingIntent { pendingIntent = nil; perform(intent) }
            }
        } message: { Text("切换内容会关闭当前编辑草稿，已保存的任务不受影响。") }
        .alert("删除这个任务？", isPresented: $confirmingDelete, presenting: deletingTask) { task in
            Button("删除", role: .destructive) {
                store.deleteTask(task.id)
                if store.storageError.isEmpty {
                    if destination == .task(task.id) { destination = .tasks }
                    if draft?.action.id == task.id { draft = nil }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { task in Text("从设置和 Dock 移除“\(task.title)”，不会删除实际应用或文件。") }
        .alert(categoryDraftID == nil ? "添加分类" : "重命名分类", isPresented: $editingCategory) {
            TextField("分类名称", text: $categoryName)
            Button("保存") {
                store.saveCategory(id: categoryDraftID, name: categoryName)
                if store.storageError.isEmpty && draft == nil,
                   let id = categoryDraftID ?? store.categories.last?.id { destination = .category(id) }
            }.disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .alert("删除整个分类？", isPresented: $confirmingCategoryDelete, presenting: deletingCategory) { category in
            Button("删除", role: .destructive) {
                store.deleteCategory(category.id)
                if store.storageError.isEmpty {
                    if destination == .category(category.id) || category.tasks.contains(where: { destination == .task($0.id) }) { destination = .tasks }
                    if draft?.categoryID == category.id { draft = nil }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { category in
            Text("将移除“\(category.name)”及其 \(category.tasks.count) 个子任务，同时从 Dock 移除这些任务。实际应用和文件不受影响。")
        }
    }

    @MainActor @ViewBuilder
    private var workspace: some View {
        switch destination {
        case .tasks:
            collection(nil)
        case .category(let id):
            if let category = store.categories.first(where: { $0.id == id }) { collection(category) }
            else { missingSelection }
        case .task(let id):
            if let task = store.actions.first(where: { $0.id == id }) {
                TaskDetailView(store: store, task: task, edit: { request(.edit(task)) },
                    delete: { deletingTask = task; confirmingDelete = true }, showHistory: { request(.navigate(.runs)) }).id(task.id)
            } else { missingSelection }
        case .activities:
            ActivitiesView(center: store.activities, store: store) { request(.navigate(.workflows)) }.padding(24)
        case .workflows:
            WorkflowsView(runner: store.workflows, store: store, focus: workflowFocus).padding(24)
        case .runs:
            runsTab.padding(12)
        #if DEBUG
        case .previews:
            ExecutionPreviewView(overlayPreferences: store.overlayPreferences)
        #endif
        case .settings:
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.system(size: 26, weight: .semibold)).padding(.horizontal, 16)
                Picker("设置页面", selection: $settingsSection) {
                    Text("边缘唤出").tag("gesture")
                    Text("运行浮窗").tag("overlay")
                    Text("AI 接入").tag("integration")
                    Text("软件更新").tag("updates")
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                Group {
                    switch settingsSection {
                    case "overlay": ActivityOverlaySettingsView(preferences: store.overlayPreferences)
                    case "integration": integrationTab
                    case "updates": updateTab
                    default: gestureTab
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(16).padding(.top, 12)
        }
    }

    private func collection(_ category: TaskCategory?) -> some View {
        TaskCollectionView(store: store, category: category, select: { request(.navigate(.task($0.id))) },
            newTask: { request(.newTask) }, newCategory: { editCategory(nil) },
            rename: { if let category { editCategory(category) } },
            delete: { if let category { deletingCategory = category; confirmingCategoryDelete = true } })
    }
    private var missingSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容已被移除").font(.title2)
            Text("任务库可能已在其他地方更新，请从左侧重新选择。").foregroundStyle(.secondary)
            Button("查看全部任务") { request(.navigate(.tasks)) }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func request(_ intent: WorkspaceIntent) {
        if draft != nil { pendingIntent = intent; confirmingDiscard = true }
        else { perform(intent) }
    }
    private func perform(_ intent: WorkspaceIntent) {
        switch intent {
        case .navigate(let target): workflowFocus = nil; destination = target
        case .openRun(let value):
            switch value.destination {
            case .task(let id): destination = .task(id)
            case .workflow:
                workflowFocus = value
                destination = .workflows
            case .activities: destination = .activities
            }
        case .edit(let task):
            guard let categoryID = store.categoryID(for: task.id) else { return }
            destination = .task(task.id)
            draft = TaskEditorDraft(action: task, categoryID: categoryID, inDock: store.isInDock(task.id), revision: store.library.revision)
        case .newTask:
            guard let category = activeCategory ?? store.categories.first else { editCategory(nil); return }
            destination = .category(category.id)
            draft = TaskEditorDraft(action: QuickAction(id: UUID().uuidString, title: "", symbol: "globe", kind: .website, target: ""),
                categoryID: category.id, inDock: false, revision: store.library.revision)
        }
    }
    private func editCategory(_ category: TaskCategory?) {
        categoryDraftID = category?.id; categoryName = category?.name ?? ""; editingCategory = true
    }
    private func inlineEditor(_ value: TaskEditorDraft) -> some View {
        ActionEditor(action: value.action, categoryID: value.categoryID, inDock: value.inDock, revision: value.revision,
            categories: store.categories, onSave: { task, categoryID, pinned, revision in
                let saved = store.save(task, categoryID: categoryID, inDock: pinned, expectedRevision: revision)
                if saved { destination = .task(task.id); draft = nil }
                return saved
            }, embedded: true, onClose: { draft = nil }).id(value.id)
    }

    private func chooseTaskDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url { store.importTasks(from: url) }
    }

    private var runsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("任务运行记录").font(.headline)
            Text("同一任务运行中不会重复启动。命令可停止；打开类任务仅记录系统是否接受请求。")
                .font(.caption).foregroundStyle(.secondary)
            List(store.commandRuns) { run in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(run.title).fontWeight(.medium)
                        Spacer()
                        Text(run.state.title).foregroundStyle(run.state == .failed || run.state == .timedOut ? Color.red : Color.secondary)
                    }
                    if let remote = run.remoteJob {
                        Text("远程作业：\(remote.jobID)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let summary = run.summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack {
                        Text(run.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        if let code = run.exitCode { Text("exit \(code)").font(.caption.monospaced()) }
                        Spacer()
                        if let result = run.resultURL {
                            Button("查看结果") { NSWorkspace.shared.open(result) }
                        }
                        Button("查看日志") { NSWorkspace.shared.open(run.logURL) }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([run.logURL]) }
                        if run.canStop {
                            Button(run.definition.externalProgram?.asyncOptions == nil ? "停止" : "停止跟踪") { store.stopCommand(run.id) }
                        }
                    }
                }.padding(.vertical, 6)
            }
            .overlay {
                if store.commandRuns.isEmpty { Text("尚无任务运行记录").foregroundStyle(.secondary) }
            }
            Text("运行记录跨重启保存；未收到最终结果的历史运行标记为中断，不会自动重试。日志保存在配置目录的 Logs 文件夹中。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    private var integrationTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("让 AI 添加任务").font(.headline)
            Text("将下面的 CLI 路径提供给支持本机终端操作的 AI。它可以查询任务、校验 JSON、添加或更新任务；所有修改会自动同步到 TapDone。")
                .foregroundStyle(.secondary)
            Text(store.cliURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("复制 CLI 路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.cliURL.path, forType: .string)
            }
            Button("复制给 AI 的接入说明") {
                let cli = "'" + store.cliURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let instructions = """
                请使用本机 TapDone CLI：\(cli)
                先运行 \(cli) schema 和 \(cli) tasks list，依据实际 Schema 判断任务能力。
                此版本支持 application、website、folder、file、open、command 和 external。新增能力优先使用 external：AI 编写外部脚本，由稳定协议调用，无需修改或重新编译 TapDone。
                command 需要命令文本与工作目录。external 需要 executable、arguments、JSON input 和工作目录；从 stdin 读取 {protocolVersion:1,taskID,runID,input}，stdout 只返回 {protocolVersion:1,ok,message,data}，日志写 stderr。脚本可放在 tapdone paths 返回的 scripts 目录，每次执行读取最新脚本。
                先 validate，再 apply，并携带读取到的 --if-revision。使用稳定任务 ID，保留无关任务。
                只有我要求时才设置 showInDock: true；添加和更新不要顺带执行任务。
                """
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(instructions, forType: .string)
            }
            Divider()
            Text("任务配置位置").font(.headline)
            Text(store.libraryURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("打开配置目录") { NSWorkspace.shared.open(store.libraryURL.deletingLastPathComponent()) }
            Text("推荐让 AI 通过 CLI 修改任务。创建与导入只保存配置，不会执行任务；当前支持应用、网址、文件夹、文件及本机命令。命令通过 /bin/zsh -lc 在后台运行，日志可在“运行记录”中查看。external 提供与语言无关的 JSON 输入输出协议，新增能力只需添加脚本与任务配置。")
                .font(.callout).foregroundStyle(.secondary)
            Text("外部脚本目录").font(.headline)
            Text(store.libraryURL.deletingLastPathComponent().appendingPathComponent("scripts").path)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("打开脚本目录") {
                let directory = store.libraryURL.deletingLastPathComponent().appendingPathComponent("scripts", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                } catch {
                    let alert = NSAlert(); alert.messageText = "无法打开脚本目录"
                    alert.informativeText = error.localizedDescription; alert.runModal()
                }
            }
        }.padding(16)
        }
    }

    private var updateTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TapDone 软件更新").font(.headline)
            LabeledContent("当前版本", value: updates.currentVersion)
            Toggle("自动检查更新", isOn: $updates.automaticChecks).disabled(!updates.isConfigured)
            Text("发现新版本后提示，由你确认下载和安装。有任务运行时延后安装，任务完成后再重启。")
                .font(.callout).foregroundStyle(.secondary)
            Text(updates.status).font(.callout).textSelection(.enabled)
            if let date = updates.lastCheck { LabeledContent("上次检查") { Text(date, style: .date); Text(date, style: .time) } }
            HStack {
                Button("检查更新…") { updates.checkForUpdates(nil) }.disabled(!updates.canCheck)
                if updates.installationPending { Button("继续安装") { updates.resumeInstallationIfIdle() } }
                Button("GitHub 发布页") { NSWorkspace.shared.open(updates.releaseURL) }
            }
            Divider()
            Text("任务库、脚本和日志保存在应用之外。更新前会备份任务库；脚本和任务配置继续独立更新，无需重启应用。")
                .font(.caption).foregroundStyle(.secondary)
            Text("更新地址：" + updates.feedURLString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }.padding(16)
    }

    private var gestureTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("鼠标区域停留唤出").font(.headline)
            Form {
                Toggle("启用边缘停留唤出", isOn: $store.gestureEnabled)
                Picker("触发位置", selection: $store.activationEdge) {
                    ForEach(ActivationEdge.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("触发范围：\(Int(store.edgeRange)) 点")
                    Slider(value: $store.edgeRange, in: 2...120, step: 2)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("停留时间：\(store.dwellTime, specifier: "%.1f") 秒")
                    Slider(value: $store.dwellTime, in: 0.1...2, step: 0.1)
                }
            }
            Text("鼠标进入所选边缘或角落的触发区域，停留达到设定时间即可唤出。无需滑动，不限制速度。上下边缘显示横向 Dock，左右边缘及四角显示竖向 Dock。")
                .font(.callout).foregroundStyle(.secondary)
            Text("范围使用屏幕逻辑点：边缘按条带宽度计算，角落按正方形边长计算。区域内移动不影响计时，离开区域会重新计时。鼠标移出设置窗口即可使用。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

private struct ActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: QuickAction
    @State var categoryID: String
    @State var inDock: Bool
    @State var revision: UInt64
    let categories: [TaskCategory]
    let onSave: (QuickAction, String, Bool, UInt64) -> Bool
    var embedded = false
    var onClose: (() -> Void)?
    @State private var errorMessage = ""
    @State private var commandDirectory = ""
    @State private var commandTimeout: Double = 300
    @State private var externalArguments = "[]"
    @State private var externalInput = "{}"
    @State private var iconSearch = ""
    @State private var iconLibrary = "lucide"
    private let symbolGroups: [(String, [String])] = [
        ("常用", ["star", "heart", "bolt", "checkmark.circle", "flag", "bookmark", "bell", "clock"]),
        ("开发", ["terminal", "hammer", "wrench.and.screwdriver", "gearshape", "curlybraces", "chevron.left.forwardslash.chevron.right", "ladybug", "shippingbox"]),
        ("文件", ["folder", "folder.fill", "doc", "doc.text", "archivebox", "tray", "arrow.down.circle", "paperclip"]),
        ("网络", ["globe", "safari", "link", "network", "server.rack", "externaldrive", "cloud", "wifi"]),
        ("工具", ["app", "display", "keyboard", "computermouse", "magnifyingglass", "camera", "photo", "scissors"]),
        ("效率", ["play.circle", "arrow.triangle.2.circlepath", "calendar", "list.bullet", "chart.bar", "paperplane", "lock", "person.2"])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(action.title.isEmpty ? "添加子任务" : "编辑子任务").font(.title3.weight(.semibold))
            ScrollView {
            Form {
                TextField("名称", text: $action.title)
                Picker("分类", selection: $categoryID) {
                    ForEach(categories) { Text($0.name).tag($0.id) }
                }
                Toggle("显示在 Dock", isOn: $inDock)
                Picker("类型", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: action.kind) { kind in
                    action.target = ""
                    action.symbol = kind == .website ? "globe" : kind == .folder ? "folder" : kind == .file ? "doc" : (kind == .command || kind == .external) ? "terminal" : "app"
                    errorMessage = ""
                }
                if action.kind == .command || action.kind == .external {
                    if action.kind == .external {
                        TextField("可执行程序绝对路径", text: $action.target)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("参数（JSON 字符串数组）")
                            TextEditor(text: $externalArguments).font(.system(.caption, design: .monospaced))
                                .frame(height: 55).border(Color.secondary.opacity(0.3))
                            Text("输入参数（任意 JSON）")
                            TextEditor(text: $externalInput).font(.system(.caption, design: .monospaced))
                                .frame(height: 80).border(Color.secondary.opacity(0.3))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("命令（zsh）")
                            TextEditor(text: $action.target).font(.system(.body, design: .monospaced))
                                .frame(height: 90).border(Color.secondary.opacity(0.3))
                        }
                    }
                    HStack {
                        TextField("工作目录", text: $commandDirectory)
                        Button("选择…", action: chooseCommandDirectory)
                    }
                    TextField("超时（秒）", value: $commandTimeout, format: .number)
                } else {
                    HStack {
                        TextField(action.kind == .website ? "网址" : action.kind == .folder || action.kind == .file ? "路径" : "应用标识", text: $action.target)
                        if action.kind != .website { Button("选择…", action: chooseTarget) }
                    }
                }
                TextField("活动标题", text: Binding(
                    get: { action.presentation?.activityTitle ?? "" },
                    set: { value in
                        var presentation = action.presentation ?? TaskPresentation()
                        presentation.activityTitle = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                        action.presentation = presentation
                    }))
                Toggle("显示在活动列表", isOn: Binding(
                    get: { action.presentation?.activityEnabled ?? true },
                    set: { value in
                        var presentation = action.presentation ?? TaskPresentation()
                        presentation.activityEnabled = value
                        action.presentation = presentation
                    }))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TaskIconView(task: action).frame(width: 32, height: 32)
                        Text("任务图标").font(.headline)
                        Spacer()
                        Button("导入图片…", action: chooseIcon)
                        Button("恢复默认") {
                            action.presentation?.builtinIconID = nil
                            action.presentation?.iconAssetID = nil
                            action.presentation?.useSymbol = nil
                        }
                    }
                    TextField("搜索图标分类或名称", text: $iconSearch)
                        .textFieldStyle(.roundedBorder)
                    Picker("图标库", selection: $iconLibrary) {
                        Text("Lucide · 48 个").tag("lucide")
                        Text("系统图标").tag("system")
                    }.pickerStyle(.segmented)
                    if iconLibrary == "lucide" {
                        LucideTaskIconGrid(action: $action, search: iconSearch)
                    } else {
                        ForEach(Array(symbolGroups.enumerated()), id: \.offset) { _, group in
                            let symbols = group.1.filter { symbol in
                                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil &&
                                (iconSearch.isEmpty || group.0.localizedCaseInsensitiveContains(iconSearch) || symbol.localizedCaseInsensitiveContains(iconSearch))
                            }
                            if !symbols.isEmpty {
                                Text(group.0).font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 46))], spacing: 6) {
                                    ForEach(symbols, id: \.self) { symbol in
                                        Button {
                                            action.symbol = symbol
                                            var presentation = action.presentation ?? TaskPresentation()
                                            presentation.builtinIconID = nil
                                            presentation.iconAssetID = nil
                                            presentation.useSymbol = true
                                            action.presentation = presentation
                                        } label: {
                                            Image(systemName: symbol).font(.system(size: 20))
                                                .frame(maxWidth: .infinity).frame(height: 36)
                                                .foregroundStyle(action.symbol == symbol && action.presentation?.useSymbol == true && action.presentation?.builtinIconID == nil ? Color.accentColor : Color.primary)
                                                .background(RoundedRectangle(cornerRadius: 7).fill(
                                                    action.symbol == symbol && action.presentation?.useSymbol == true && action.presentation?.builtinIconID == nil ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
                                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                                                    action.symbol == symbol && action.presentation?.useSymbol == true && action.presentation?.builtinIconID == nil ? Color.accentColor : Color.clear))
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain).help(symbol).accessibilityLabel(symbol)
                                        .accessibilityAddTraits(action.symbol == symbol && action.presentation?.useSymbol == true && action.presentation?.builtinIconID == nil ? .isSelected : [])
                                    }
                                }
                            }
                        }
                    }
                    Text("点击图标即可选择；支持按中文分类或英文名称搜索。")
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
            }.frame(height: embedded ? nil : action.kind == .external ? 390 : action.kind == .command ? 320 : 220)
                .frame(maxHeight: embedded ? .infinity : nil)
            Text(action.kind == .external ? "通用 JSON 协议：从 stdin 读输入，stdout 返回协议结果，stderr 写日志。参数直接传递，不经 Shell 插值。" : action.kind == .command ? "后台运行，不提供交互式输入。保存不会执行；环境变量可通过 AI JSON 配置，编辑时会保留。" : action.kind == .application ? "选择已安装的 .app，图标列将使用应用本身的图标。" : action.kind == .folder || action.kind == .file ? "选择要打开的目标，也可填写绝对路径或 ~/ 开头的路径。" : "支持 HTTP / HTTPS 网址；省略协议时自动使用 HTTPS。")
                .font(.caption).foregroundStyle(.secondary)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(embedded ? 28 : 24).frame(width: embedded ? nil : 520)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
        .onAppear {
            if action.presentation?.useSymbol == true && action.presentation?.builtinIconID == nil { iconLibrary = "system" }
            commandDirectory = action.externalProgram?.options.workingDirectory ?? action.commandOptions?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            commandTimeout = action.externalProgram?.options.timeoutSeconds ?? action.commandOptions?.timeoutSeconds ?? 300
            if let external = action.externalProgram {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                externalArguments = (try? encoder.encode(external.arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                externalInput = (try? encoder.encode(external.input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
        }
    }

    private func close() {
        if embedded { onClose?() } else { dismiss() }
    }

    @MainActor
    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try TaskIconProvider.importImage(at: url)
            var presentation = action.presentation ?? TaskPresentation()
            presentation.builtinIconID = nil
            presentation.useSymbol = nil
            presentation.iconAssetID = id
            action.presentation = presentation
            errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseCommandDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { commandDirectory = url.path }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = action.kind == .folder
        panel.canChooseFiles = action.kind == .application || action.kind == .file
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if action.kind == .application {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if action.kind == .application {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else {
                errorMessage = "无法读取应用标识，请选择有效的 .app。"
                return
            }
            action.target = identifier
        } else {
            action.target = url.path
        }
        if action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            action.title = FileManager.default.displayName(atPath: url.path)
        }
        errorMessage = ""
    }

    private func save() {
        action.title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        action.target = action.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action.presentation?.isValid ?? true else { errorMessage = "活动标题不能超过 200 字，图标引用必须有效。"; return }
        guard categories.contains(where: { $0.id == categoryID }) else { errorMessage = "请选择分类。"; return }
        guard !action.title.isEmpty else { errorMessage = "请填写任务名称。"; return }
        if action.kind != .command { action.commandOptions = nil }
        if action.kind != .external { action.externalProgram = nil }
        switch action.kind {
        case .external:
            do {
                let arguments = try JSONDecoder().decode([String].self, from: Data(externalArguments.utf8))
                let input = try JSONDecoder().decode(JSONValue.self, from: Data(externalInput.utf8))
                let options = CommandOptions(workingDirectory: commandDirectory, timeoutSeconds: commandTimeout,
                                             environment: action.externalProgram?.options.environment ?? [:])
                let program = try ExternalProgram(executable: action.target, arguments: arguments, input: input, options: options, protocolVersion: action.externalProgram?.protocolVersion ?? 1, inputContract: action.externalProgram?.inputContract, outputContract: action.externalProgram?.outputContract, asyncOptions: action.externalProgram?.asyncOptions).validated()
                action.externalProgram = program
                action.target = program.executable
            } catch { errorMessage = error.localizedDescription; return }
        case .command:
            do {
                action.commandOptions = try CommandOptions(workingDirectory: commandDirectory, timeoutSeconds: commandTimeout,
                    environment: action.commandOptions?.environment ?? [:]).validated(command: action.target)
            } catch { errorMessage = error.localizedDescription; return }
        case .website:
            if !action.target.contains("://") { action.target = "https://" + action.target }
            guard let url = URL(string: action.target), let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()), let host = url.host, !host.isEmpty else {
                errorMessage = "请填写有效的 HTTP / HTTPS 网址。"; return
            }
            action.target = url.absoluteString
        case .application:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.target) != nil else {
                errorMessage = "未找到应用，请通过“选择”指定已安装的应用。"; return
            }
        case .folder, .file:
            let expanded = (action.target as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded).path
            var isDirectory: ObjCBool = false
            guard !action.target.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), (action.kind == .file || isDirectory.boolValue) else {
                errorMessage = "目标不存在或类型不匹配，请重新选择。"; return
            }
            action.target = path
        }
        if onSave(action, categoryID, inDock, revision) {
            close()
        } else {
            errorMessage = "保存失败或配置已被外部修改。请取消后重新打开编辑；草稿仍保留在此窗口。"
        }
    }
}

/// A native adapter of RunActivity; future surfaces consume the same snapshots.
private struct ActivitiesView: View {
    @ObservedObject var center: RunActivityCenter
    @ObservedObject var store: AppStore
    let showWorkflows: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("任务与流程活动").font(.headline)
            Text("统一显示执行、远程等待和人工复核。流程进度表示已完成节点数。")
                .font(.caption).foregroundStyle(.secondary)
            if center.activities.isEmpty { Text("暂无活动").foregroundStyle(.secondary) }
            List(center.activities) { activity in
                RunActivityRow(activity: activity,
                    task: store.commandRuns.first(where: { $0.id == activity.runID && activity.source == .task })?.definition,
                    openLog: {
                        if let run = store.commandRuns.first(where: { $0.id == activity.runID }) { NSWorkspace.shared.open(run.logURL) }
                    }, showWorkflow: showWorkflows, stop: { store.stopCommand(activity.runID) })
            }
        }.padding(.top, 8)
    }
}

private struct LucideTaskIconGrid: View {
    @Binding var action: QuickAction
    let search: String
    private var matches: [BuiltinTaskIcon] {
        BuiltinTaskIcon.all.filter {
            search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)
                || $0.title.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        if matches.isEmpty { Text("没有匹配的图标").font(.caption).foregroundStyle(.secondary) }
        ForEach(BuiltinTaskIcon.categories, id: \.self) { category in
            let icons = matches.filter { $0.category == category }
            if !icons.isEmpty {
                Text(category).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 46))], spacing: 6) {
                    ForEach(icons) { icon in
                        let selected = action.presentation?.builtinIconID == icon.id && action.presentation?.iconAssetID == nil
                        Button {
                            var presentation = action.presentation ?? TaskPresentation()
                            presentation.iconAssetID = nil
                            presentation.useSymbol = nil
                            presentation.builtinIconID = icon.id
                            action.presentation = presentation
                        } label: {
                            Image(icon.assetName).renderingMode(.template).resizable().scaledToFit()
                                .frame(width: 22, height: 22)
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(icon.title + " · " + icon.id).accessibilityLabel(icon.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}

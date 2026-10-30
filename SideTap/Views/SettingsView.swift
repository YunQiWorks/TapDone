import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: AppUpdateController
    @State private var selectedID: String?
    @State private var selectedCategoryID: String?
    @State private var editingAction: QuickAction?
    @State private var confirmingDelete = false
    @State private var editingCategory = false
    @State private var categoryDraftID: String?
    @State private var categoryName = ""
    @State private var confirmingCategoryDelete = false

    private var selectedAction: QuickAction? { store.actions.first { $0.id == selectedID } }
    private var activeCategory: TaskCategory? {
        let id = selectedID.flatMap { store.categoryID(for: $0) } ?? selectedCategoryID
        return store.categories.first { $0.id == id } ?? store.categories.first
    }

    var body: some View {
        TabView {
            actionsTab.tabItem { Label("任务", systemImage: "list.bullet.indent") }
            runsTab.tabItem { Label("运行记录", systemImage: "text.alignleft") }
            integrationTab.tabItem { Label("AI 接入", systemImage: "terminal") }
            updateTab.tabItem { Label("软件更新", systemImage: "arrow.down.circle") }
            gestureTab.tabItem { Label("边缘唤出", systemImage: "rectangle.dashed") }
        }
        .padding(20).frame(width: 680, height: 620)
        .sheet(item: $editingAction) { action in
            ActionEditor(action: action, categoryID: store.categoryID(for: action.id) ?? activeCategory?.id ?? "",
                         inDock: store.isInDock(action.id), revision: store.library.revision, categories: store.categories) { task, categoryID, pinned, revision in
                let saved = store.save(task, categoryID: categoryID, inDock: pinned, expectedRevision: revision)
                if saved { selectedID = task.id; selectedCategoryID = categoryID }
                return saved
            }
        }
        .alert("删除这个任务？", isPresented: $confirmingDelete, presenting: selectedAction) { task in
            Button("删除", role: .destructive) { store.deleteTask(task.id); selectedID = nil }
            Button("取消", role: .cancel) {}
        } message: { task in Text("从设置和 Dock 移除“\(task.title)”，不会删除实际应用或文件。") }
        .alert(categoryDraftID == nil ? "添加分类" : "重命名分类", isPresented: $editingCategory) {
            TextField("分类名称", text: $categoryName)
            Button("保存") {
                store.saveCategory(id: categoryDraftID, name: categoryName)
                selectedCategoryID = categoryDraftID ?? store.categories.last?.id
                selectedID = nil
            }.disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .alert("删除整个分类？", isPresented: $confirmingCategoryDelete, presenting: activeCategory) { category in
            Button("删除", role: .destructive) {
                store.deleteCategory(category.id)
                selectedID = nil
                selectedCategoryID = nil
            }
            Button("取消", role: .cancel) {}
        } message: { category in
            Text("将移除“\(category.name)”及其 \(category.tasks.count) 个子任务，同时从 Dock 移除这些任务。实际应用和文件不受影响。")
        }
    }

    private var actionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.storageError.isEmpty {
                HStack {
                    Text(store.storageError).font(.caption).foregroundStyle(.red)
                    Button("重新读取") { store.refreshLibrary() }
                }
            }
            Text("分类与子任务").font(.headline)
            Text("这里显示全部任务。仅勾选“显示在 Dock”的子任务会出现在图标栏中。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("导入任务…") { chooseTaskDocument() }
                Button("添加分类") { categoryDraftID = nil; categoryName = ""; editingCategory = true }
                Button("重命名分类") {
                    categoryDraftID = activeCategory?.id
                    categoryName = activeCategory?.name ?? ""
                    editingCategory = true
                }.disabled(activeCategory == nil)
                Button("删除分类…") { confirmingCategoryDelete = true }.disabled(activeCategory == nil)
            }
            List(selection: $selectedID) {
                ForEach(store.categories) { category in
                    Section {
                        ForEach(category.tasks) { task in
                            taskRow(task).tag(task.id)
                        }
                        if category.tasks.isEmpty {
                            Text("暂无子任务").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                    } header: {
                        HStack {
                            Button {
                                selectedCategoryID = category.id
                                selectedID = nil
                            } label: {
                                Label(category.name + " (\(category.tasks.count))", systemImage: "folder")
                                    .fontWeight(activeCategory?.id == category.id ? .bold : .regular)
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { store.moveCategory(category.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(store.categories.first?.id == category.id).help("分类上移").accessibilityLabel("分类上移")
                            Button { store.moveCategory(category.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(store.categories.last?.id == category.id).help("分类下移").accessibilityLabel("分类下移")
                        }
                        .textCase(nil)
                    }
                }
            }
            .overlay {
                if store.categories.isEmpty {
                    Text("先添加分类，再添加子任务。")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            HStack {
                Button("添加子任务") {
                    editingAction = QuickAction(id: UUID().uuidString, title: "", subtitle: "", symbol: "globe", kind: .website, target: "")
                }.disabled(activeCategory == nil)
                Button("执行") { if let task = selectedAction { store.run(task) } }.disabled(selectedAction == nil)
                Button("编辑…") { editingAction = selectedAction }.disabled(selectedAction == nil)
                Button("删除任务…") { confirmingDelete = true }.disabled(selectedAction == nil)
                Spacer()
                Button { if let id = selectedID { store.move(id, by: -1) } } label: { Image(systemName: "arrow.up") }
                    .disabled(selectedID == nil || activeCategory?.tasks.first?.id == selectedID).help("任务上移").accessibilityLabel("任务上移")
                Button { if let id = selectedID { store.move(id, by: 1) } } label: { Image(systemName: "arrow.down") }
                    .disabled(selectedID == nil || activeCategory?.tasks.last?.id == selectedID).help("任务下移").accessibilityLabel("任务下移")
            }
            if !store.message.isEmpty {
                Text(store.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Dock 已添加 \(store.dockActions.count) 个任务 · 按分类及子任务的顺序显示 · 修改自动保存")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    private func taskRow(_ task: QuickAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.symbol).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                Text(task.kind.title + " · " + task.target)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("显示在 Dock", isOn: Binding(get: { store.isInDock(task.id) }, set: { store.setInDock(task.id, enabled: $0) }))
                .toggleStyle(.checkbox).fixedSize()
        }
        .padding(.leading, 18).padding(.vertical, 4)
        .contextMenu {
            Button("执行") { store.run(task) }
            Button("编辑…") { editingAction = task }
            Button(store.isInDock(task.id) ? "从 Dock 移除" : "添加到 Dock") {
                store.setInDock(task.id, enabled: !store.isInDock(task.id))
            }
            Button("删除…", role: .destructive) { selectedID = task.id; confirmingDelete = true }
        }
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
            Text("命令运行记录").font(.headline)
            Text("同一任务运行中不会重复启动。停止或超时会终止该次运行及其子进程。")
                .font(.caption).foregroundStyle(.secondary)
            List(store.commandRuns) { run in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(run.title).fontWeight(.medium)
                        Spacer()
                        Text(run.state.rawValue).foregroundStyle(run.state == .failed || run.state == .timedOut ? Color.red : Color.secondary)
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
                        if run.state == .running { Button("停止") { store.stopCommand(run.id) } }
                    }
                }.padding(.vertical, 6)
            }
            .overlay {
                if store.commandRuns.isEmpty { Text("尚无命令运行记录").foregroundStyle(.secondary) }
            }
            Text("此列表显示本次启动的运行；日志文件保存在配置目录的 Logs 文件夹中。退出 TapDone 会停止仍在运行的命令。")
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
                command 需要命令文本与工作目录。external 需要 executable、arguments、JSON input 和工作目录；从 stdin 读取 {protocolVersion:1,taskID,runID,input}，stdout 只返回 {protocolVersion:1,ok,message,data}，日志写 stderr。脚本可放在 sidetap paths 返回的 scripts 目录，每次执行读取最新脚本。
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
    @State private var errorMessage = ""
    @State private var commandDirectory = ""
    @State private var commandTimeout: Double = 300
    @State private var externalArguments = "[]"
    @State private var externalInput = "{}"
    private let symbols = ["globe", "folder", "arrow.down.circle", "app", "terminal", "star", "bolt", "doc", "link", "gearshape"]

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
                Picker("图标", selection: $action.symbol) {
                    ForEach(Array(Set(symbols + [action.symbol])).sorted(), id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
            }
            }.frame(height: action.kind == .external ? 390 : action.kind == .command ? 320 : 220)
            Text(action.kind == .external ? "通用 JSON 协议：从 stdin 读输入，stdout 返回协议结果，stderr 写日志。参数直接传递，不经 Shell 插值。" : action.kind == .command ? "后台运行，不提供交互式输入。保存不会执行；环境变量可通过 AI JSON 配置，编辑时会保留。" : action.kind == .application ? "选择已安装的 .app，图标列将使用应用本身的图标。" : action.kind == .folder || action.kind == .file ? "选择要打开的目标，也可填写绝对路径或 ~/ 开头的路径。" : "支持 HTTP / HTTPS 网址；省略协议时自动使用 HTTPS。")
                .font(.caption).foregroundStyle(.secondary)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            commandDirectory = action.externalProgram?.options.workingDirectory ?? action.commandOptions?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            commandTimeout = action.externalProgram?.options.timeoutSeconds ?? action.commandOptions?.timeoutSeconds ?? 300
            if let external = action.externalProgram {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                externalArguments = (try? encoder.encode(external.arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                externalInput = (try? encoder.encode(external.input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
        }
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
                let program = try ExternalProgram(executable: action.target, arguments: arguments, input: input, options: options).validated()
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
            dismiss()
        } else {
            errorMessage = "保存失败或配置已被外部修改。请取消后重新打开编辑；草稿仍保留在此窗口。"
        }
    }
}

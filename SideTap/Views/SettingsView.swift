import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: AppStore
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
            gestureTab.tabItem { Label("边缘唤出", systemImage: "rectangle.dashed") }
        }
        .padding(20).frame(width: 680, height: 620)
        .sheet(item: $editingAction) { action in
            ActionEditor(action: action, categoryID: store.categoryID(for: action.id) ?? activeCategory?.id ?? "",
                         inDock: store.isInDock(action.id), categories: store.categories) { task, categoryID, pinned in
                store.save(task, categoryID: categoryID, inDock: pinned)
                selectedID = task.id
                selectedCategoryID = categoryID
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
            Text("分类与子任务").font(.headline)
            Text("这里显示全部任务。仅勾选“显示在 Dock”的子任务会出现在图标栏中。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
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
                Button("编辑…") { editingAction = selectedAction }.disabled(selectedAction == nil)
                Button("删除任务…") { confirmingDelete = true }.disabled(selectedAction == nil)
                Spacer()
                Button { if let id = selectedID { store.move(id, by: -1) } } label: { Image(systemName: "arrow.up") }
                    .disabled(selectedID == nil || activeCategory?.tasks.first?.id == selectedID).help("任务上移").accessibilityLabel("任务上移")
                Button { if let id = selectedID { store.move(id, by: 1) } } label: { Image(systemName: "arrow.down") }
                    .disabled(selectedID == nil || activeCategory?.tasks.last?.id == selectedID).help("任务下移").accessibilityLabel("任务下移")
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
            Button("编辑…") { editingAction = task }
            Button(store.isInDock(task.id) ? "从 Dock 移除" : "添加到 Dock") {
                store.setInDock(task.id, enabled: !store.isInDock(task.id))
            }
            Button("删除…", role: .destructive) { selectedID = task.id; confirmingDelete = true }
        }
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
    let categories: [TaskCategory]
    let onSave: (QuickAction, String, Bool) -> Void
    @State private var errorMessage = ""
    private let symbols = ["globe", "folder", "arrow.down.circle", "app", "terminal", "star", "bolt", "doc", "link", "gearshape"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(action.title.isEmpty ? "添加子任务" : "编辑子任务").font(.title3.weight(.semibold))
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
                    action.symbol = kind == .website ? "globe" : kind == .folder ? "folder" : "app"
                    errorMessage = ""
                }
                HStack {
                    TextField(action.kind == .website ? "网址" : action.kind == .folder ? "文件夹路径" : "应用标识", text: $action.target)
                    if action.kind != .website {
                        Button("选择…", action: chooseTarget)
                    }
                }
                Picker("图标", selection: $action.symbol) {
                    ForEach(Array(Set(symbols + [action.symbol])).sorted(), id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
            }
            Text(action.kind == .application ? "选择已安装的 .app，图标列将使用应用本身的图标。" : action.kind == .folder ? "选择要打开的文件夹，也可填写绝对路径或 ~/ 开头的路径。" : "支持 HTTP / HTTPS 网址；省略协议时自动使用 HTTPS。")
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
        .padding(24).frame(width: 460)
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = action.kind == .folder
        panel.canChooseFiles = action.kind == .application
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
        switch action.kind {
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
        case .folder:
            let expanded = (action.target as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded).path
            var isDirectory: ObjCBool = false
            guard !action.target.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                errorMessage = "文件夹不存在，请重新选择。"; return
            }
            action.target = path
        }
        onSave(action, categoryID, inDock)
        dismiss()
    }
}

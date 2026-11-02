import AppKit
import SwiftUI

enum WorkspaceDestination: Hashable {
    case tasks, task(String), category(String), activities, workflows, runs, settings
    #if DEBUG
    case previews
    #endif
}

struct TaskNavigationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var activities: RunActivityCenter
    let destination: WorkspaceDestination
    let select: (WorkspaceDestination) -> Void
    let newTask: () -> Void
    let newCategory: () -> Void
    let importTasks: () -> Void
    let editTask: (QuickAction) -> Void
    let deleteTask: (QuickAction) -> Void
    let renameCategory: (TaskCategory) -> Void
    let deleteCategory: (TaskCategory) -> Void
    @State private var search = ""
    @State private var filter = "全部"
    @State private var collapsed = Set<String>()

    private var recentIDs: Set<String> {
        var ids = Set<String>()
        for run in store.commandRuns.sorted(by: { $0.startedAt > $1.startedAt }) {
            ids.insert(run.taskID)
            if ids.count == 20 { break }
        }
        return ids
    }
    private var activeCount: Int { activities.activities.filter { !$0.state.isTerminal && $0.parentWorkflowRunID == nil }.count }
    private func tasks(in category: TaskCategory) -> [QuickAction] {
        let recent = filter == "最近" ? recentIDs : []
        return category.tasks.filter {
            (filter != "Dock" || store.isInDock($0.id)) && (filter != "最近" || recent.contains($0.id)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || category.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap.fill").foregroundStyle(Color.accentColor)
                Text("TapDone").font(.headline)
                Spacer()
                Menu {
                    Button("添加任务", action: newTask).disabled(store.categories.isEmpty)
                    Button("添加分类", action: newCategory)
                    Divider()
                    Button("导入任务…", action: importTasks)
                } label: { Image(systemName: "plus.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("新建").accessibilityLabel("新建任务或分类")
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 16)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索任务或分类", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.bottom, 12)
            VStack(spacing: 3) {
                navigation("全部任务", symbol: "square.grid.2x2", to: .tasks)
                navigation("活动", symbol: "waveform.path", to: .activities, count: activeCount)
                navigation("流程", symbol: "point.3.connected.trianglepath.dotted", to: .workflows)
                navigation("运行记录", symbol: "clock.arrow.circlepath", to: .runs)
            }.padding(.horizontal, 10)
            Divider().padding(.horizontal, 14).padding(.vertical, 14)
            HStack {
                Text("任务分类").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: newCategory) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("添加分类").accessibilityLabel("添加分类")
            }.padding(.horizontal, 18).padding(.bottom, 8)
            Picker("筛选任务", selection: $filter) {
                ForEach(["全部", "Dock", "最近"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 6)
            List {
                ForEach(store.categories) { category in
                    let visible = tasks(in: category)
                    if !visible.isEmpty || (search.isEmpty && filter == "全部") {
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsed.contains(category.id) || !search.isEmpty },
                            set: { if $0 { collapsed.remove(category.id) } else { collapsed.insert(category.id) } })) {
                            ForEach(visible) { task in
                                taskButton(task)
                            }
                            if visible.isEmpty { Text("暂无任务").font(.caption).foregroundStyle(.tertiary) }
                        } label: {
                            Button { select(.category(category.id)) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(category.name).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text("\(visible.count)").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .foregroundStyle(destination == .category(category.id) ? Color.accentColor : Color.primary)
                        }
                        .contextMenu {
                            Button("查看分类") { select(.category(category.id)) }
                            Button("重命名…") { renameCategory(category) }
                            Button("上移") { store.moveCategory(category.id, by: -1) }.disabled(store.categories.first?.id == category.id)
                            Button("下移") { store.moveCategory(category.id, by: 1) }.disabled(store.categories.last?.id == category.id)
                            Divider()
                            Button("删除分类…", role: .destructive) { deleteCategory(category) }
                        }
                        .listRowSeparator(.hidden)
                    }
                }
            }.listStyle(.sidebar)
                .overlay {
                    if store.categories.isEmpty { Text("创建分类，整理你的常用操作").font(.caption).foregroundStyle(.secondary).padding().allowsHitTesting(false) }
                    else if !store.categories.contains(where: { !tasks(in: $0).isEmpty }) && (!search.isEmpty || filter != "全部") {
                        Text("没有匹配的任务").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            Divider().padding(.horizontal, 14)
            #if DEBUG
            navigation("效果预览", symbol: "rectangle.on.rectangle", to: .previews)
                .padding(.horizontal, 10).padding(.top, 8)
            #endif
            navigation("设置", symbol: "gearshape", to: .settings).padding(10)
        }
        .background(.regularMaterial)
    }

    private func navigation(_ title: String, symbol: String, to target: WorkspaceDestination, count: Int = 0) -> some View {
        Button { select(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(destination == target ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func taskButton(_ task: QuickAction) -> some View {
        Button { select(.task(task.id)) } label: {
            HStack(spacing: 8) {
                TaskIconView(task: task).frame(width: 20, height: 20)
                Text(task.title).lineLimit(1)
                Spacer(minLength: 2)
                if store.execution.isTaskActive(task.id) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("任务进行中")
                }
                if store.isInDock(task.id) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("已添加到 Dock") }
            }.padding(.horizontal, 7).padding(.vertical, 6).contentShape(Rectangle())
                .background(destination == .task(task.id) ? Color.primary.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(destination == .task(task.id) ? .isSelected : [])
            .contextMenu {
                Button("执行") { store.run(task) }.disabled(store.execution.isTaskActive(task.id) || store.updateInstallationPending)
                Button("编辑…") { editTask(task) }
                Button(store.isInDock(task.id) ? "从 Dock 移除" : "添加到 Dock") { store.setInDock(task.id, enabled: !store.isInDock(task.id)) }
                Divider()
                Button("上移") { store.move(task.id, by: -1) }.disabled(store.categories.first(where: { $0.tasks.contains(where: { $0.id == task.id }) })?.tasks.first?.id == task.id)
                Button("下移") { store.move(task.id, by: 1) }.disabled(store.categories.first(where: { $0.tasks.contains(where: { $0.id == task.id }) })?.tasks.last?.id == task.id)
                Divider()
                Button("删除任务…", role: .destructive) { deleteTask(task) }
            }
    }
}

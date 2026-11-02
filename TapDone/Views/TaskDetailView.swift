import AppKit
import SwiftUI

struct TaskDetailView: View {
    @ObservedObject var store: AppStore
    let task: QuickAction
    let edit: () -> Void
    let delete: () -> Void
    let showHistory: () -> Void
    @State private var showConfiguration = false
    private var latest: TaskRun? { store.commandRuns.filter { $0.taskID == task.id }.max { $0.startedAt < $1.startedAt } }
    private var busy: Bool { store.execution.isTaskActive(task.id) }
    private var options: CommandOptions? { task.externalProgram?.options ?? task.commandOptions }

    var body: some View {
        let currentRun = latest
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label(store.categories.first(where: { $0.tasks.contains(where: { $0.id == task.id }) })?.name ?? "任务", systemImage: "folder")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("编辑任务", action: edit)
                        Button("上移") { store.move(task.id, by: -1) }
                        Button("下移") { store.move(task.id, by: 1) }
                        Divider()
                        Button("删除任务…", role: .destructive, action: delete)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("任务操作")
                }
                HStack(alignment: .center, spacing: 18) {
                    TaskIconView(task: task).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(task.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                        Text(task.subtitle.isEmpty ? task.kind.title : task.subtitle).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Button { store.run(task) } label: { Label(busy ? "任务进行中" : "执行任务", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(busy || store.updateInstallationPending)
                    Button("编辑", action: edit).controlSize(.large)
                    Spacer()
                    Toggle("显示在 Dock", isOn: Binding(get: { store.isInDock(task.id) }, set: { store.setInDock(task.id, enabled: $0) }))
                        .toggleStyle(.switch).fixedSize()
                }
                if store.updateInstallationPending {
                    Label("更新正在等待安装，暂时不能启动新任务。", systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                TaskRunSummaryCard(run: currentRun, showHistory: showHistory,
                    openLog: { if let run = currentRun { NSWorkspace.shared.open(run.logURL) } },
                    openResult: { if let url = currentRun?.resultURL { NSWorkspace.shared.open(url) } },
                    stop: { if let run = currentRun { store.stopCommand(run.id) } })
                WorkspaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("任务信息").font(.headline)
                        LabeledContent("类型", value: task.kind.title)
                        if task.kind != .command {
                            LabeledContent(task.kind == .website ? "网址" : task.kind == .application ? "应用标识" : "目标") {
                                Text(task.target).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                            }
                        } else { Text("在后台运行本机命令或脚本。").foregroundStyle(.secondary) }
                        if task.kind == .external {
                            LabeledContent("执行方式", value: task.externalProgram?.asyncOptions == nil ? "同步返回" : "异步提交与查询")
                        }
                    }.font(.callout)
                }
                WorkspaceCard {
                    DisclosureGroup("执行配置", isExpanded: $showConfiguration) {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("任务 ID", value: task.id).font(.caption).textSelection(.enabled)
                            if task.kind == .command { Text("命令").font(.caption).foregroundStyle(.secondary); codeBlock(task.target) }
                            if let options {
                                LabeledContent("工作目录") { Text(options.workingDirectory).textSelection(.enabled) }
                                LabeledContent("单次超时", value: "\(Int(options.timeoutSeconds)) 秒")
                                LabeledContent("环境变量", value: "\(options.environment.count) 项")
                            }
                            if let program = task.externalProgram {
                                LabeledContent("协议版本", value: "v\(program.protocolVersion ?? 1)")
                                if let async = program.asyncOptions {
                                    LabeledContent("查询间隔", value: "\(Int(async.pollIntervalSeconds)) 秒")
                                    LabeledContent("远程总超时", value: "\(Int(async.timeoutSeconds)) 秒")
                                }
                                DisclosureGroup("程序参数") { codeBlock(pretty(program.arguments)) }
                                DisclosureGroup("输入参数") { codeBlock(pretty(program.input)) }
                                LabeledContent("输入约束", value: program.inputContract == nil ? "未声明" : "已配置")
                                LabeledContent("输出约束", value: program.outputContract == nil ? "未声明" : "已配置")
                            }
                            Button("编辑配置", action: edit)
                        }.font(.callout).padding(.top, 14)
                    }.font(.headline)
                }
            }.padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func pretty<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法显示内容"
    }
    private func codeBlock(_ value: String) -> some View {
        Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WorkspaceCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.065)))
    }
}

struct TaskCollectionView: View {
    @ObservedObject var store: AppStore
    let category: TaskCategory?
    let select: (QuickAction) -> Void
    let newTask: () -> Void
    let newCategory: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    private var tasks: [QuickAction] { category?.tasks ?? store.actions }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category?.name ?? "全部任务").font(.system(size: 26, weight: .semibold))
                        Text("\(tasks.count) 个任务 · \(tasks.filter { store.isInDock($0.id) }.count) 个已加入 Dock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if category != nil {
                        Menu {
                            Button("重命名分类…", action: rename)
                            Button("删除分类…", role: .destructive, action: delete)
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Button(action: store.categories.isEmpty ? newCategory : newTask) {
                        Label(store.categories.isEmpty ? "创建分类" : "添加任务", systemImage: "plus")
                    }.buttonStyle(.borderedProminent)
                }
                if tasks.isEmpty {
                    WorkspaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                            Text("把常用操作，变成一次点击").font(.headline)
                            Text(store.categories.isEmpty ? "先创建一个分类，再添加应用、网址、文件或脚本任务。" : "为这个分类添加第一个任务，也可以从左侧的新建菜单导入已有任务。")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 22)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(tasks) { task in
                            WorkspaceCard {
                                HStack(spacing: 14) {
                                    Button { select(task) } label: {
                                        HStack(spacing: 14) {
                                            TaskIconView(task: task).frame(width: 38, height: 38)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(task.title).fontWeight(.medium).foregroundStyle(.primary)
                                                Text(task.kind.title).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if store.isInDock(task.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).help("已加入 Dock") }
                                    Button { store.run(task) } label: { Image(systemName: "play.fill") }
                                        .disabled(store.execution.isTaskActive(task.id) || store.updateInstallationPending)
                                        .help("执行“\(task.title)”").accessibilityLabel("执行“\(task.title)”")
                                }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

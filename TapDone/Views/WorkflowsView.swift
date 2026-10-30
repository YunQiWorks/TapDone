import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct WorkflowsView: View {
    @ObservedObject var runner: WorkflowRunner
    @ObservedObject var store: AppStore
    private struct Review: Identifiable {
        let id: String
        let nodeID: String
        let context: WorkflowReviewContext
        let digest: String
    }
    @State private var review: Review?
    @State private var reviewError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("上下游流程").font(.headline)
                Spacer()
                Button("导入流程…") { importWorkflow() }
            }
            Text("按依赖顺序串行执行，复核后才启动下游。导入不会执行，更新定义不改变已有运行。")
                .font(.caption).foregroundStyle(.secondary)
            if !reviewError.isEmpty { Text(reviewError).font(.caption).foregroundStyle(.red) }
            if !runner.errorMessage.isEmpty { Text(runner.errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            List {
                Section("已添加的流程") {
                    ForEach(runner.definitions) { definition in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(definition.name)
                                Text("\(definition.nodes.count) 个节点").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("执行") { runner.start(definition, library: store.library) }.disabled(store.updateInstallationPending)
                        }
                    }
                    if runner.definitions.isEmpty { Text("导入流程 JSON 后，可在这里一键执行。 ").foregroundStyle(.secondary) }
                }
                Section("流程运行") {
                    ForEach(runner.runs) { run in
                        DisclosureGroup {
                            if let message = run.message { Text(message).font(.caption).textSelection(.enabled) }
                            ForEach(run.nodes) { node in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(run.plan.definition.nodes.first(where: { $0.id == node.id })?.name ?? node.id)
                                        Spacer()
                                        Text(node.state.title).foregroundStyle(.secondary)
                                        if node.state == .waitingReview, let context = node.context {
                                            Button("复核…") {
                                                do { review = Review(id: run.id, nodeID: node.id, context: context, digest: try context.digest()) }
                                                catch { reviewError = "复核内容读取失败：\(error.localizedDescription)" }
                                            }.disabled(store.updateInstallationPending)
                                        }
                                    }
                                    if let message = node.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if let childID = node.childRunID {
                                        HStack {
                                            Text("运行：\(childID)").font(.caption.monospaced()).textSelection(.enabled)
                                            Button("查看日志") {
                                                do {
                                                    let child = try store.execution.history.read(childID)
                                                    NSWorkspace.shared.open(child.logURL)
                                                } catch { reviewError = "子运行日志读取失败：\(error.localizedDescription)" }
                                            }
                                        }
                                    }
                                    if let receipt = node.approval {
                                        Text("\(receipt.reviewer) · \(receipt.approved ? "批准" : "驳回")：\(receipt.reason)").font(.caption).textSelection(.enabled)
                                    }
                                }.padding(.vertical, 4)
                            }
                            HStack {
                                if run.state == .paused { Button("继续流程") { runner.resume(run.id) }.disabled(store.updateInstallationPending) }
                                if !run.state.terminal { Button("停止流程", role: .destructive) { runner.stop(run.id) } }
                            }
                        } label: {
                            HStack { Text(run.plan.definition.name); Spacer(); Text(run.state.title).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .sheet(item: $review) { request in
            WorkflowReviewView(context: request.context, error: runner.errorMessage) { approved, reason in
                runner.decide(request.id, nodeID: request.nodeID, digest: request.digest, approved: approved, reason: reason)
            }
        }
    }
    private func importWorkflow() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { runner.importDefinition(url, library: store.library) }
    }
}

@MainActor
private struct WorkflowReviewView: View {
    let context: WorkflowReviewContext
    let error: String
    let decide: (Bool, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    private var evidence: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(context.inputs)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法读取复核产物。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("复核上游产物").font(.headline)
            Text("批准后将继续执行下游。请核对以下返回数据；路径或网址本身不代表文件内容已验证。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(evidence).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
            TextField("填写批准或驳回理由", text: $reason)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("返回") { dismiss() }
                Spacer()
                Button("驳回", role: .destructive) { if decide(false, reason) { dismiss() } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("批准并继续") { if decide(true, reason) { dismiss() } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 560)
    }
}

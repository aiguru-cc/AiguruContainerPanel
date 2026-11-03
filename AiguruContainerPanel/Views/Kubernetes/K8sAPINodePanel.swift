//
//  K8sAPINodePanel.swift
//  AiguruContainerPanel
//
//  Kubernetes API 节点管理：通过 kindest/node 内置 kubectl + admin.conf 操作，
//  不依赖宿主机安装 kubectl，也不会误用用户当前 context。
//

import SwiftUI

struct K8sAPINodePanel: View {
    @ObservedObject var manager: KubernetesManager
    let cluster: KubernetesCluster

    @State private var nodes: [KubernetesNode] = []
    @State private var selectedNodeName: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nodeDescription: String?
    @State private var showDrainSheet = false
    @State private var showLabelSheet = false
    @State private var showTaintSheet = false

    private var selectedNode: KubernetesNode? {
        nodes.first { $0.name == selectedNodeName } ?? nodes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            nodeToolbar
            Divider()
            if isLoading && nodes.isEmpty {
                Spacer()
                ProgressView("读取 Kubernetes Node API…")
                Spacer()
            } else if let errorMessage, nodes.isEmpty {
                ContentUnavailableView("无法读取节点", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                nodeTable
                Divider()
                if let node = selectedNode {
                    nodeDetail(node)
                } else {
                    ContentUnavailableView("没有节点", systemImage: "server.rack")
                }
            }
        }
        .task(id: cluster.name) { await refresh() }
        .sheet(isPresented: $showDrainSheet) {
            if let node = selectedNode {
                K8sDrainNodeSheet(node: node) { options in
                    await perform("驱逐节点 Pod") {
                        try await manager.drainNode(
                            cluster: cluster.name,
                            node: node.name,
                            ignoreDaemonSets: options.ignoreDaemonSets,
                            deleteEmptyDirData: options.deleteEmptyDirData,
                            force: options.force,
                            gracePeriod: options.gracePeriod
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showLabelSheet) {
            if let node = selectedNode {
                K8sNodeLabelSheet(node: node) { key, value in
                    await perform("更新节点标签") {
                        try await manager.setNodeLabel(cluster: cluster.name, node: node.name, key: key, value: value)
                    }
                }
            }
        }
        .sheet(isPresented: $showTaintSheet) {
            if let node = selectedNode {
                K8sNodeTaintSheet(node: node) { expression, removing in
                    await perform("更新节点污点") {
                        try await manager.setNodeTaint(cluster: cluster.name, node: node.name, expression: expression, removing: removing)
                    }
                }
            }
        }
        .alert("节点操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var nodeToolbar: some View {
        HStack(spacing: 8) {
            Label("Kubernetes 节点", systemImage: "server.rack")
                .font(.headline)
            Text("通过集群 API 管理")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let node = selectedNode {
                statusBadge(node)
                Button(node.unschedulable ? "解除封锁" : "封锁") {
                    Task {
                        if node.unschedulable {
                            await perform("解除节点封锁") { try await manager.uncordonNode(cluster: cluster.name, node: node.name) }
                        } else {
                            await perform("封锁节点") { try await manager.cordonNode(cluster: cluster.name, node: node.name) }
                        }
                    }
                }
                .controlSize(.small)
                .disabled(!node.isReady)
                Button("驱逐…", action: { showDrainSheet = true })
                    .controlSize(.small)
                    .disabled(!node.isReady)
                Menu("配置") {
                    Button("管理标签…") { showLabelSheet = true }
                    Button("管理污点…") { showTaintSheet = true }
                    Divider()
                    Button("读取 describe") { loadDescription(node) }
                }
                .controlSize(.small)
            }
            Button(action: { Task { await refresh() } }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isLoading)
        }
        .padding(10)
    }

    private var nodeTable: some View {
        Table(nodes, selection: $selectedNodeName) {
            TableColumn("节点") { Text($0.name).fontWeight(.medium) }
            TableColumn("状态") { statusBadge($0) }
            TableColumn("角色") { Text($0.roleText) }
            TableColumn("可调度") { Text($0.schedulabilityText).foregroundStyle($0.unschedulable ? .orange : .green) }
            TableColumn("Internal IP") { Text($0.internalIP).monospaced() }
            TableColumn("Kubelet") { Text($0.nodeInfo.kubeletVersion) }
        }
        .frame(minHeight: 130, idealHeight: 150, maxHeight: 190)
        .onChange(of: selectedNodeName) { _, _ in nodeDescription = nil }
    }

    private func nodeDetail(_ node: KubernetesNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    metric("CPU（可分配 / 容量）", node.cpuText, "cpu")
                    metric("内存（可分配 / 容量）", node.memoryText, "memorychip")
                    metric("Pod（可分配 / 容量）", node.podsText, "cube.transparent")
                    metric("Pod CIDR", node.podCIDR ?? "-", "network")
                    metric("容器运行时", node.nodeInfo.containerRuntimeVersion, "shippingbox")
                    metric("系统", "\(node.nodeInfo.osImage) · \(node.nodeInfo.architecture)", "desktopcomputer")
                }

                GroupBox("节点条件") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(node.conditions) { condition in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: condition.status == "True" ? "checkmark.circle.fill" : "minus.circle.fill")
                                    .foregroundStyle(condition.type == "Ready" && condition.status != "True" ? .red : .secondary)
                                Text(condition.type).frame(width: 110, alignment: .leading)
                                Text(condition.status).fontWeight(.medium).frame(width: 48, alignment: .leading)
                                Text(condition.reason ?? "-").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.caption)
                            .help(condition.message ?? "")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 12) {
                    GroupBox("标签（\(node.labels.count)）") {
                        KeyValueList(values: node.labels)
                    }
                    GroupBox("污点（\(node.taints.count)）") {
                        if node.taints.isEmpty {
                            Text("无污点").font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(node.taints) { taint in
                                    Text(taint.expression).font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }

                if let nodeDescription {
                    GroupBox("kubectl describe node \(node.name)") {
                        ScrollView {
                            Text(nodeDescription)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }
            .padding(12)
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.medium)).lineLimit(2)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func statusBadge(_ node: KubernetesNode) -> some View {
        Text(node.isReady ? "Ready" : "NotReady")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((node.isReady ? Color.green : Color.red).opacity(0.16)))
            .foregroundStyle(node.isReady ? .green : .red)
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await manager.fetchKubernetesNodes(cluster: cluster.name)
            nodes = fetched
            if selectedNodeName == nil || !fetched.contains(where: { $0.name == selectedNodeName }) {
                selectedNodeName = fetched.first?.name
            }
            if fetched.isEmpty {
                errorMessage = "Kubernetes Node API 请求成功，但返回的 items 为空。"
            }
        } catch {
            nodes = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDescription(_ node: KubernetesNode) {
        nodeDescription = "读取中…"
        Task { @MainActor in
            nodeDescription = await manager.fetchNodeDescription(cluster: cluster.name, node: node.name)
        }
    }

    private func perform(_ operation: String, action: @escaping () async throws -> Void) async {
        do {
            try await action()
            await refresh()
        } catch {
            errorMessage = "\(operation)失败：\(error.localizedDescription)"
        }
    }
}

private struct KeyValueList: View {
    let values: [String: String]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    Text("\(key)=\(values[key] ?? "")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220, maxHeight: 130)
    }
}

private struct K8sDrainOptions {
    var ignoreDaemonSets = true
    var deleteEmptyDirData = false
    var force = false
    var gracePeriod: Int?
}

private struct K8sDrainNodeSheet: View {
    let node: KubernetesNode
    let onDrain: (K8sDrainOptions) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ignoreDaemonSets = true
    @State private var deleteEmptyDirData = false
    @State private var force = false
    @State private var gracePeriod = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("驱逐节点 \(node.name)", systemImage: "arrow.right.to.line.compact")
                .font(.title3.weight(.semibold))
            Text("驱逐会先封锁节点，阻止新的 Pod 调度，然后按 Kubernetes Eviction API 逐个迁移或终止可驱逐 Pod。DaemonSet 与 mirror Pod 不会被删除。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("忽略 DaemonSet（标准 drain 常用）", isOn: $ignoreDaemonSets)
            Toggle("允许删除 emptyDir 本地数据", isOn: $deleteEmptyDirData)
            Toggle("允许无控制器的 Pod（--force）", isOn: $force)
            TextField("优雅终止秒数（可选）", text: $gracePeriod).textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("开始驱逐", role: .destructive) {
                    let seconds = Int(gracePeriod.trimmingCharacters(in: .whitespaces))
                    Task {
                        await onDrain(K8sDrainOptions(ignoreDaemonSets: ignoreDaemonSets, deleteEmptyDirData: deleteEmptyDirData, force: force, gracePeriod: seconds))
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct K8sNodeLabelSheet: View {
    let node: KubernetesNode
    let onSubmit: (String, String?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var remove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("管理节点标签").font(.title3.weight(.semibold))
            Text("使用标准 kubectl label node。角色标签使用 node-role.kubernetes.io/<role>。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("标签键，例如 workload.example.com/type", text: $key).textFieldStyle(.roundedBorder)
            Toggle("移除这个标签", isOn: $remove)
            if !remove { TextField("标签值", text: $value).textFieldStyle(.roundedBorder) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button(remove ? "移除标签" : "保存标签", role: remove ? .destructive : nil) {
                    Task { await onSubmit(key.trimmingCharacters(in: .whitespaces), remove ? nil : value.trimmingCharacters(in: .whitespaces)); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || (!remove && value.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct K8sNodeTaintSheet: View {
    let node: KubernetesNode
    let onSubmit: (String, Bool) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expression = ""
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("管理节点污点").font(.title3.weight(.semibold))
            Text(removing ? "输入 key 或 key:effect；面板会追加 - 以移除。" : "格式：key=value:NoSchedule、PreferNoSchedule 或 NoExecute。")
                .font(.caption).foregroundStyle(.secondary)
            TextField(removing ? "例如 dedicated:NoSchedule" : "例如 dedicated=gpu:NoSchedule", text: $expression)
                .textFieldStyle(.roundedBorder)
            Toggle("移除污点", isOn: $removing)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button(removing ? "移除污点" : "保存污点", role: removing ? .destructive : nil) {
                    Task { await onSubmit(expression.trimmingCharacters(in: .whitespaces), removing); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

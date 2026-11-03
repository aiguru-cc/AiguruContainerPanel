//
//  K8sAPIPodPanel.swift
//  AiguruContainerPanel
//

import SwiftUI

/// 标准 Kubernetes Pod 视图。数据来自 API Server，而不是 crictl Pod sandbox，
/// 因此可正确展示命名空间、控制器、容器状态和日志。
struct K8sAPIPodPanel: View {
    @ObservedObject var manager: KubernetesManager
    let cluster: KubernetesCluster

    @State private var pods: [KubernetesPod] = []
    @State private var selectedPodID: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var detailText: String?
    @State private var detailTitle = ""
    @State private var selectedContainerName = ""

    private var selectedPod: KubernetesPod? {
        pods.first { $0.id == selectedPodID } ?? pods.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pod 工作负载", systemImage: "cube.transparent")
                    .font(.headline)
                Text("Kubernetes API")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: { Task { await refresh() } }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isLoading)
            }
            .padding(10)
            Divider()

            if isLoading && pods.isEmpty {
                Spacer(); ProgressView("读取 Pod…"); Spacer()
            } else if let errorMessage, pods.isEmpty {
                ContentUnavailableView("无法读取 Pod", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                Table(pods, selection: $selectedPodID) {
                    TableColumn("Pod") { Text($0.name).fontWeight(.medium) }
                    TableColumn("命名空间") { Text($0.namespace) }
                    TableColumn("状态") { phaseBadge($0) }
                    TableColumn("就绪") { Text($0.readyText) }
                    TableColumn("重启") { Text(String($0.containers.reduce(0) { $0 + $1.restartCount })) }
                    TableColumn("节点") { Text($0.nodeName) }
                    TableColumn("IP") { Text($0.podIP).monospaced() }
                }
                .frame(minHeight: 150, idealHeight: 185, maxHeight: 230)
                .onChange(of: selectedPodID) { _, _ in
                    detailText = nil
                    selectedContainerName = selectedPod?.containers.first?.name ?? ""
                }

                Divider()
                if let pod = selectedPod { detailPanel(pod) }
            }
        }
        .task(id: cluster.name) { await refresh() }
        .alert("Pod 查询失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func detailPanel(_ pod: KubernetesPod) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pod.namespace)/\(pod.name)").font(.headline)
                        Text("控制器：\(pod.owner) · 节点：\(pod.nodeName) · IP：\(pod.podIP)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Describe") { loadDescribe(pod) }.controlSize(.small)
                    Button("YAML") { loadYAML(pod) }.controlSize(.small)
                }
                if let reason = pod.reason ?? pod.message {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                GroupBox("容器") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pod.containers) { container in
                            HStack(spacing: 8) {
                                Image(systemName: container.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(container.ready ? .green : .orange)
                                Text(container.name).font(.caption.weight(.medium))
                                Text(container.state).font(.caption).foregroundStyle(.secondary)
                                Text("重启 \(container.restartCount)").font(.caption).foregroundStyle(.secondary)
                                Text(container.image).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button("日志") { loadLogs(pod, container: container.name) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let detailText {
                    GroupBox(detailTitle) {
                        ScrollView {
                            Text(detailText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 270)
                    }
                } else {
                    Text("选择 Describe、YAML 或某个容器的日志查看交互信息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func phaseBadge(_ pod: KubernetesPod) -> some View {
        Text(pod.phase)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((pod.isHealthy ? Color.green : Color.orange).opacity(0.16)))
            .foregroundStyle(pod.isHealthy ? .green : .orange)
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await manager.fetchKubernetesPods(cluster: cluster.name)
            pods = result
            if selectedPodID == nil || !result.contains(where: { $0.id == selectedPodID }) {
                selectedPodID = result.first?.id
            }
            if result.isEmpty { errorMessage = "Kubernetes Pod API 请求成功，但返回的 items 为空。" }
        } catch {
            pods = []
            errorMessage = error.localizedDescription
        }
        selectedContainerName = selectedPod?.containers.first?.name ?? ""
        isLoading = false
    }

    private func loadDescribe(_ pod: KubernetesPod) {
        detailTitle = "kubectl describe pod \(pod.name)"
        detailText = "读取中…"
        Task { @MainActor in detailText = await manager.fetchPodDescription(cluster: cluster.name, namespace: pod.namespace, pod: pod.name) }
    }

    private func loadYAML(_ pod: KubernetesPod) {
        detailTitle = "Pod YAML"
        detailText = "读取中…"
        Task { @MainActor in detailText = await manager.fetchPodYAML(cluster: cluster.name, namespace: pod.namespace, pod: pod.name) }
    }

    private func loadLogs(_ pod: KubernetesPod, container: String) {
        detailTitle = "日志：\(pod.namespace)/\(pod.name) · \(container)"
        detailText = "读取中…"
        Task { @MainActor in detailText = await manager.fetchPodLogs(cluster: cluster.name, namespace: pod.namespace, pod: pod.name, container: container) }
    }
}

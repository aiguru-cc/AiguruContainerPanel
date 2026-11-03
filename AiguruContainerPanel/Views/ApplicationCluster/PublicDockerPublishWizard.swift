import SwiftUI
import AppKit

/// Apple Container → OCI/Docker/Kubernetes 与 VM Appliance 发布任务向导。
struct PublicDockerPublishWizard: View {
    let cluster: ApplicationCluster
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var targets: Set<ClusterPublishTarget> = [.kubernetes]
    @State private var registry = "ghcr.io/organization"
    @State private var namespace = "default"
    @State private var versionTag = "latest"
    @State private var platform = "linux/arm64"
    @State private var includeStoragePlan = true
    @State private var includeHelm = true
    @State private var kernelPath = ""
    @State private var outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    @State private var isGenerating = false
    @State private var generationProgress = 0.0
    @State private var generationMessage = ""
    @State private var errorMessage: String?
    @State private var generatedURL: URL?
    @State private var selectedKubernetesCluster = ""
    @State private var isDeploying = false
    @State private var deploymentMessage: String?
    @ObservedObject private var kubernetesManager = KubernetesManager.shared
    private let manager = ApplicationClusterPublishManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            Group {
                switch step {
                case 0: targetStep
                case 1: configurationStep
                default: reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 620)
        .alert("生成失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .toast()
        .task {
            await kubernetesManager.fetchClusters()
            if selectedKubernetesCluster.isEmpty {
                selectedKubernetesCluster = kubernetesManager.clusters.first(where: \.isRunning)?.name
                    ?? kubernetesManager.clusters.first?.name
                    ?? ""
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用集群发布向导").font(.headline)
                    Text("\(cluster.name) · \(cluster.serviceGroups.count) 个服务 · \(cluster.desiredCount) 个实例")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 6) {
                stepBadge(0, "选择链路")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                stepBadge(1, "配置任务")
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                stepBadge(2, "检查并生成")
            }
        }
    }

    private func stepBadge(_ index: Int, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text("\(index + 1)").font(.caption2.monospaced()).padding(4)
                .background(step == index ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                .foregroundStyle(step == index ? .white : .secondary)
            Text(title).font(.caption.weight(step == index ? .semibold : .regular))
        }
    }

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择一个或两个业务链路。向导只生成任务包，推送和部署任务需要后续明确执行。")
                .font(.caption).foregroundStyle(.secondary)
            targetCard(.kubernetes, icon: "shippingbox.and.arrow.backward", title: "OCI / Docker / Kubernetes",
                       detail: "生成 OCI 标记/推送任务、Docker Compose、Kubernetes YAML、Helm Chart 与 crictl 节点诊断脚本。")
            targetCard(.docker, icon: "shippingbox", title: "Docker / 宝塔 Docker",
                       detail: "生成 OCI tar 镜像包、Docker 导入脚本、Compose 文件和宝塔 Docker 导入说明，可离线复制到目标主机。")
            targetCard(.vmAppliance, icon: "desktopcomputer.and.arrow.down", title: "Apple Container VM Appliance",
                       detail: "导出 OCI 根文件系统、VM 描述和恢复任务。恢复后仍由 Apple Container 启动每容器轻量 VM。")
            GroupBox("边界说明") {
                Text("OCI 镜像可跨 Apple Container、Docker 和 Kubernetes 使用；内核、虚拟硬件与运行中内存状态不会进入 OCI 镜像。crictl 只用于 Linux Kubernetes 节点诊断。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }

    private func targetCard(_ target: ClusterPublishTarget, icon: String, title: String, detail: String) -> some View {
        Button {
            if targets.contains(target) { targets.remove(target) } else { targets.insert(target) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: targets.contains(target) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(targets.contains(target) ? Color.accentColor : Color.secondary)
                Image(systemName: icon).font(.title2).frame(width: 32).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(targets.contains(target) ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targets.contains(target) ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private var configurationStep: some View {
        Form {
            if targets.contains(.kubernetes) {
                Section("OCI / Kubernetes") {
                    TextField("Registry 前缀", text: $registry, prompt: Text("ghcr.io/organization"))
                    TextField("Kubernetes Namespace", text: $namespace)
                    TextField("镜像版本标签", text: $versionTag)
                    Picker("目标平台", selection: $platform) {
                        Text("Linux ARM64").tag("linux/arm64")
                        Text("Linux AMD64").tag("linux/amd64")
                        Text("Linux ARMv7").tag("linux/arm/v7")
                        Text("Linux 386").tag("linux/386")
                    }
                    Toggle("生成 Helm Chart", isOn: $includeHelm)
                    Toggle("生成持久化存储迁移计划", isOn: $includeStoragePlan)
                    Picker("直接部署目标", selection: $selectedKubernetesCluster) {
                        Text("不直接部署").tag("")
                        ForEach(kubernetesManager.clusters) { cluster in
                            Text("\(cluster.name) · \(cluster.state)").tag(cluster.name)
                        }
                    }
                    Text("直接部署会把应用集群使用的本地 OCI 镜像加载到所选节点 containerd，再应用 Kubernetes 清单。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if targets.contains(.docker) {
                Section("Docker / 宝塔 Docker") {
                    Text("将生成 images/*.oci.tar、import-docker.sh、import-baota-docker.sh 和 docker-compose.yml；宝塔主机可在 Docker 模块中导入 Compose。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if targets.contains(.vmAppliance) {
                Section("VM Appliance") {
                    TextField("自定义内核路径（留空使用当前/推荐内核）", text: $kernelPath)
                    Text("Appliance 不保存 VM 内存快照。宿主机挂载只记录映射，数据需要单独迁移。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("输出目录") {
                HStack {
                    Text(outputDirectory).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择…", action: selectOutputDirectory)
                }
            }
            if isGenerating {
                Section("打包进度") {
                    ProgressView(value: generationProgress)
                    Text(generationMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("将生成") {
                VStack(alignment: .leading, spacing: 7) {
                    if targets.contains(.kubernetes) {
                        Label("OCI tag/push 任务和 Docker Compose", systemImage: "shippingbox")
                        Label("Kubernetes YAML\(includeHelm ? "、Helm Chart" : "") 与 crictl 诊断脚本", systemImage: "doc.on.doc")
                    }
                    if targets.contains(.docker) {
                        Label("OCI tar 镜像归档、Docker 导入脚本、Compose 与宝塔 Docker 导入脚本", systemImage: "shippingbox")
                    }
                    if targets.contains(.vmAppliance) {
                        Label("OCI 镜像归档、appliance.json 和 Apple Container 恢复任务", systemImage: "archivebox")
                    }
                    Label("机器可读 task-plan.json 和 README", systemImage: "list.bullet.rectangle")
                }
                .font(.caption).padding(.vertical, 4)
            }
            GroupBox("任务安全") {
                Text("生成过程只写入所选目录。Registry 推送、kubectl/Helm 部署、VM 恢复均标记为需确认任务，本步骤不会执行它们。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if let generatedURL {
                Label("已生成：\(generatedURL.path)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).textSelection(.enabled)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([generatedURL]) }
            }
            if let deploymentMessage {
                Label(deploymentMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button("上一步") { step -= 1 }.disabled(isGenerating) }
            Spacer()
            if step < 2 {
                Button("下一步") { step += 1 }.buttonStyle(.borderedProminent).disabled(step == 0 && targets.isEmpty)
            } else {
                if targets.contains(.kubernetes) {
                    Button(action: deployDirectlyToKubernetes) {
                        if isDeploying { ProgressView().controlSize(.small) }
                        else { Label("部署到 K8s", systemImage: "shippingbox.and.arrow.forward") }
                    }
                    .disabled(isGenerating || isDeploying || selectedKubernetesCluster.isEmpty)
                }
                Button(action: generatePackage) {
                    if isGenerating { ProgressView().controlSize(.small) }
                    else { Label("生成任务包", systemImage: "wand.and.stars") }
                }
                .buttonStyle(.borderedProminent).disabled(isGenerating || targets.isEmpty)
            }
        }
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url.path }
    }

    private func generatePackage() {
        isGenerating = true
        generationProgress = 0
        generationMessage = "准备发布目录"
        generatedURL = nil
        TaskManager.shared.startTask(module: "应用集群", operation: "生成发布任务包", command: "generate \(cluster.name) publish bundle")
        do {
            generatedURL = try manager.generate(
                cluster: cluster,
                options: ClusterPublishOptions(
                    targets: targets, registry: registry, namespace: namespace, versionTag: versionTag,
                    platform: platform, includeStoragePlan: includeStoragePlan, includeHelm: includeHelm, kernelPath: kernelPath
                ),
                outputRoot: URL(fileURLWithPath: outputDirectory, isDirectory: true),
                progress: { value, message in
                    generationProgress = value
                    generationMessage = message
                }
            )
            TaskManager.shared.finishTask(success: true, message: "发布任务包已生成：\(generatedURL?.path ?? outputDirectory)")
            ToastManager.shared.showSuccess("发布任务包已生成")
        } catch {
            errorMessage = error.localizedDescription
            TaskManager.shared.finishTask(success: false, message: "生成失败：\(error.localizedDescription)")
        }
        isGenerating = false
    }

    private func deployDirectlyToKubernetes() {
        guard !selectedKubernetesCluster.isEmpty else { return }
        isDeploying = true
        deploymentMessage = nil
        errorMessage = nil
        let targetCluster = selectedKubernetesCluster
        Task {
            do {
                let images = Set(cluster.serviceGroups.compactMap { $0.containers.first?.image })
                for image in images.sorted() {
                    try await kubernetesManager.loadImage(name: targetCluster, image: image, platform: platform)
                }
                let manifest = try manager.liveKubernetesManifest(cluster: cluster, namespace: namespace)
                try await kubernetesManager.applyManifest(cluster: targetCluster, yaml: manifest)
                await MainActor.run {
                    isDeploying = false
                    deploymentMessage = "已部署到 \(targetCluster) / \(namespace)"
                    ToastManager.shared.showSuccess("应用集群已部署到 K8s")
                }
            } catch {
                await MainActor.run {
                    isDeploying = false
                    errorMessage = "部署失败：\(error.localizedDescription)"
                    ToastManager.shared.showError("K8s 部署失败")
                }
            }
        }
    }
}

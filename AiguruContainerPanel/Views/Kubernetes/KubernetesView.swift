//
//  KubernetesView.swift
//  AiguruContainerPanel
//
//  Kubernetes(k8s) 集群管理视图（PVE 风格）：左侧集群列表，右侧选中节点的平面化控制面板。
//  节点面板封装容器内 crictl 指令：images / ps / pods / rmi / stop / rm / pull / imagefsinfo。
//  集群级命令走官方 k8s 子命令：create / delete / load-image / write-config；
//  1.5 已移除 start，停止后的集群必须删除并重建。
//

import SwiftUI

struct KubernetesView: View {
    @StateObject private var manager = KubernetesManager.shared
    @EnvironmentObject private var environmentManager: EnvironmentManager
    @State private var showCreateSheet = false
    @State private var showLoadImageSheet = false
    @State private var showWriteConfigSheet = false
    @State private var selectedClusterName: String?

    private var sortedClusters: [KubernetesCluster] {
        manager.clusters.sorted { $0.name < $1.name }
    }

    private var selectedCluster: KubernetesCluster? {
        sortedClusters.first { $0.name == selectedClusterName }
    }

    var body: some View {
        HSplitView {
            clusterSidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)
            if let cluster = selectedCluster {
                K8sNodeControlPanel(manager: manager, cluster: cluster)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    .id(cluster.name) // 切换集群时重置面板状态
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { Task { await manager.fetchClusters() } }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新集群列表")

                Button(action: { showCreateSheet = true }) {
                    Label("创建集群", systemImage: "plus.circle")
                }
                .help("创建本地 Kubernetes 集群 (k8s create)")
                .disabled(manager.compatibilityMessage != nil)

                Button(action: {
                    if let first = sortedClusters.first { selectedClusterName = first.name }
                    showLoadImageSheet = true
                }) {
                    Label("加载镜像", systemImage: "tray.and.arrow.down")
                }
                .help("将本地镜像加载进集群 (k8s load-image)")
                .disabled(manager.clusters.isEmpty)

                Button(action: {
                    if let first = sortedClusters.first { selectedClusterName = first.name }
                    showWriteConfigSheet = true
                }) {
                    Label("写 kubeconfig", systemImage: "key")
                }
                .help("获取集群 kubeconfig 并合并到 ~/.kube/config (k8s write-config)")
                .disabled(manager.clusters.isEmpty)
            }
        }
        .onAppear {
            Task { await manager.fetchClusters() }
        }
        .onChange(of: environmentManager.currentEnvironment?.id) { _, _ in
            selectedClusterName = nil
            Task { await manager.fetchClusters() }
        }
        .onChange(of: manager.clusters) { _, clusters in
            // 选中集群被删除后自动回落到第一个
            if let sel = selectedClusterName, !clusters.contains(where: { $0.name == sel }) {
                selectedClusterName = clusters.sorted { $0.name < $1.name }.first?.name
            }
        }
        .alert("错误", isPresented: .constant(manager.errorMessage != nil)) {
            Button("确定") { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateK8sClusterSheet(
                onCreate: { name, nodeImage, cni, cpus, memory, scheme, maxDownloads, removeOnStop in
                    Task {
                        do {
                            try await manager.createCluster(name: name, nodeImage: nodeImage, cni: cni, cpus: cpus, memory: memory, scheme: scheme, maxConcurrentDownloads: maxDownloads, removeOnStop: removeOnStop)
                        } catch {
                            await MainActor.run { manager.errorMessage = "创建集群失败：\(error.localizedDescription)" }
                        }
                    }
                    showCreateSheet = false
                },
                onCancel: { showCreateSheet = false }
            )
        }
        .sheet(isPresented: $showLoadImageSheet) {
            LoadK8sImageSheet(
                clusterNames: sortedClusters.map(\.name),
                initialName: Binding(
                    get: { selectedClusterName ?? sortedClusters.first?.name ?? "k8s-dev" },
                    set: { selectedClusterName = $0 }
                ),
                onLoad: { name, image, platform, pullFirst in
                    Task {
                        if pullFirst {
                            do {
                                try await SourceImageManager.shared.pullImage(name: image, tag: "", platform: platform)
                            } catch {
                                return // 拉取失败已在任务中心记录，不再加载进集群
                            }
                        }
                        try? await manager.loadImage(name: name, image: image, platform: platform)
                    }
                    showLoadImageSheet = false
                },
                onCancel: { showLoadImageSheet = false }
            )
        }
        .sheet(isPresented: $showWriteConfigSheet) {
            WriteKubeconfigSheet(
                clusterNames: sortedClusters.map(\.name),
                initialName: Binding(
                    get: { selectedClusterName ?? sortedClusters.first?.name ?? "k8s-dev" },
                    set: { selectedClusterName = $0 }
                ),
                onWrite: { name, kubeconfig in
                    Task {
                        try? await manager.writeConfig(name: name, kubeconfig: kubeconfig)
                    }
                    showWriteConfigSheet = false
                },
                onCancel: { showWriteConfigSheet = false }
            )
        }
    }

    // MARK: - 左侧集群列表（PVE 资源树）
    private var clusterSidebar: some View {
        VStack(spacing: 0) {
            if manager.isLoading && manager.clusters.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("加载集群列表...")
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if manager.clusters.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "gyroscope").font(.largeTitle).foregroundStyle(.secondary)
                    Text("暂无集群").font(.headline)
                    Text("点击工具栏「创建集群」开始").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedClusterName) {
                    ForEach(sortedClusters) { cluster in
                        HStack(spacing: 8) {
                            Image(systemName: "gyroscope").foregroundStyle(.secondary)
                            Text(cluster.name)
                            Spacer()
                            stateBadge(cluster.state, running: cluster.isRunning)
                        }
                        .tag(cluster.name)
                        .padding(.vertical, 1)
                    }
                }
                .listStyle(.plain) // 普通背景，不用 sidebar 的毛玻璃
                .scrollContentBackground(.visible)
            }
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: String, running: Bool) -> some View {
        if !state.isEmpty {
            Text(state)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(running ? Color.green.opacity(0.18) : Color.orange.opacity(0.18)))
                .foregroundStyle(running ? .green : .orange)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("从左侧选择一个集群节点").font(.title3.weight(.medium))
            Text("右侧面板将直接控制节点容器内的 containerd（crictl）")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 右侧节点控制面板（PVE 风格：顶部状态栏 + 概览 + 平面化 Tab，封装 crictl）
struct K8sNodeControlPanel: View {
    @ObservedObject var manager: KubernetesManager
    let cluster: KubernetesCluster

    @State private var images: [K8sNodeImage] = []
    @State private var containers: [K8sNodeContainer] = []
    @State private var pods: [K8sNodePod] = []
    @State private var imageFsBytes = 0
    @State private var loading = false
    @State private var queryError: String?
    @State private var imageToDelete: K8sNodeImage?
    @State private var containerToDelete: K8sNodeContainer?
    @State private var pullRef = ""
    @State private var pulling = false

    // 选中态（列表 -> 详情联动）
    @State private var selectedImageID: K8sNodeImage.ID?
    @State private var selectedContainerID: K8sNodeContainer.ID?
    @State private var imageDetail: K8sImageDetail?
    @State private var imageUsages: [K8sImageUsage] = []
    @State private var deploymentTarget: K8sNodeImage?
    @State private var containerDetail: K8sContainerDetail?
    @State private var containerStats: K8sContainerStats?
    @State private var logText: String?
    @State private var tagTarget = ""
    @State private var showTagField = false
    @State private var execCommand = ""
    @State private var execOutput: String?
    @State private var showLogs = false
    @State private var showStopConfirmation = false

    private var canRestartStoppedCluster: Bool {
        CLICommandCatalog.shared.path(
            command: "k8s.start",
            version: EnvironmentManager.shared.currentVersion
        ) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            overviewBar
            Divider()
            if loading {
                Spacer()
                ProgressView("查询节点 containerd...")
                Spacer()
            } else if let queryError {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                    Text(queryError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { refresh() }.controlSize(.small)
                }
                Spacer()
            } else {
                TabView {
                    K8sAPINodePanel(manager: manager, cluster: cluster)
                        .tabItem { Label("节点", systemImage: "server.rack") }
                    imageTab.tabItem { Label("镜像", systemImage: "photo.on.rectangle.angled") }
                    containerTab.tabItem { Label("容器", systemImage: "shippingbox") }
                    K8sAPIPodPanel(manager: manager, cluster: cluster)
                        .tabItem { Label("Pod", systemImage: "cube.transparent") }
                    K8sAPIResourcePanel(manager: manager, cluster: cluster, category: .workloads)
                        .tabItem { Label("工作负载", systemImage: "square.stack.3d.up") }
                    K8sAPIResourcePanel(manager: manager, cluster: cluster, category: .networking)
                        .tabItem { Label("网络", systemImage: "network") }
                    K8sAPIResourcePanel(manager: manager, cluster: cluster, category: .configuration)
                        .tabItem { Label("配置存储", systemImage: "externaldrive") }
                    K8sAPIResourcePanel(manager: manager, cluster: cluster, category: .access)
                        .tabItem { Label("访问控制", systemImage: "person.badge.key") }
                    K8sAPIResourcePanel(manager: manager, cluster: cluster, category: .extensions)
                        .tabItem { Label("扩展事件", systemImage: "puzzlepiece.extension") }
                }
                .padding(.top, 8)
            }
        }
        .task(id: cluster.name) { refresh() }
        .confirmationDialog("删除节点镜像", isPresented: Binding(get: { imageToDelete != nil }, set: { if !$0 { imageToDelete = nil } }), titleVisibility: .visible) {
            Button("删除 \((imageToDelete?.displayReference ?? "").abbreviated)", role: .destructive) {
                if let img = imageToDelete { deleteImage(img) }
                imageToDelete = nil
            }
            Button("取消", role: .cancel) { imageToDelete = nil }
        } message: {
            if imageToDelete?.isSystemComponent == true {
                Text("⚠️ \((imageToDelete?.displayReference ?? "").abbreviated) 是集群系统组件镜像。crictl rmi 即使镜像正在使用也可能删除成功，删除后组件一旦重启将无法拉回（registry.k8s.io 通常不可达），集群将损坏且只能删除重建。")
            } else {
                Text("删除前将重新检查 Deployment、StatefulSet、DaemonSet、Job、CronJob 和 Pod 引用；存在任何使用方时会拒绝删除。")
            }
        }
        .confirmationDialog("删除容器", isPresented: Binding(get: { containerToDelete != nil }, set: { if !$0 { containerToDelete = nil } }), titleVisibility: .visible) {
            Button("删除 \(containerToDelete?.name ?? "")", role: .destructive) {
                if let c = containerToDelete { removeContainer(c) }
                containerToDelete = nil
            }
            Button("取消", role: .cancel) { containerToDelete = nil }
        } message: {
            Text("将从节点 containerd 删除已退出的容器 \(containerToDelete?.name ?? "")（所属 Pod: \(containerToDelete?.podName ?? "")）。K8s 控制器可能重建该容器。")
        }
        .confirmationDialog(
            canRestartStoppedCluster ? "停止 Kubernetes 集群" : "停止后必须重建",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) {
                Task {
                    try? await manager.stopCluster(name: cluster.name)
                    await manager.fetchClusters()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(canRestartStoppedCluster
                 ? "将停止集群 \(cluster.name)，之后可再次启动。"
                 : "Apple Container 1.5 已移除 k8s start。停止 \(cluster.name) 后只能删除并重新创建集群。")
        }
        .sheet(item: $deploymentTarget, onDismiss: refresh) { image in
            K8sImageDeploymentSheet(cluster: cluster, image: image, manager: manager)
        }
    }

    // 顶部：节点名 + 状态 + 启停/删除
    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gyroscope").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name).font(.title3.weight(.semibold))
                Text("节点容器 · containerd/crictl").font(.caption2).foregroundStyle(.secondary)
            }
            stateCapsule(cluster.state, isGood: cluster.isRunning)
            Spacer()
            if canRestartStoppedCluster {
                Button {
                    Task {
                        try? await manager.startCluster(name: cluster.name)
                        await manager.fetchClusters()
                    }
                } label: { Label("启动", systemImage: "play.fill") }
                    .controlSize(.small)
                    .disabled(cluster.isRunning)
            } else if !cluster.isRunning {
                Label("需删除后重建", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Apple Container 1.5 已移除 k8s start")
            }
            Button {
                showStopConfirmation = true
            } label: { Label("停止", systemImage: "stop.fill") }
                .controlSize(.small)
                .disabled(!cluster.isRunning)
            Button {
                Task {
                    try? await manager.deleteCluster(name: cluster.name)
                    await manager.fetchClusters()
                }
            } label: { Label("删除", systemImage: "trash") }
                .controlSize(.small)
            Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                .controlSize(.small)
        }
        .padding(12)
    }

    // 概览：镜像数/容器数/Pod 数/containerd 镜像存储占用（crictl imagefsinfo）
    private var overviewBar: some View {
        HStack(spacing: 24) {
            Label("\(images.count) 镜像", systemImage: "photo.on.rectangle.angled")
            Label("\(containers.count) 容器", systemImage: "shippingbox")
            Label("\(pods.count) Pod", systemImage: "cube.transparent")
            Label("镜像存储 \(imageFsBytes.byteCountText)", systemImage: "internaldrive")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // 镜像 Tab：上列表（可选中）+ 下详情卡（inspecti）+ 操作（删除/tag[ctr]/push[ctr]/prune/pull）
    private var imageTab: some View {
        VStack(spacing: 0) {
            Table(images, selection: $selectedImageID) {
                TableColumn("镜像") { img in
                    HStack(spacing: 4) {
                        Text(img.displayReference)
                        if img.isSystemComponent { systemBadge }
                    }
                }
                TableColumn("IMAGE ID") { Text(img8c($0.imageID)) }
                TableColumn("大小", value: \.sizeText)
                TableColumn("") { img in
                    Button { imageToDelete = img } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("从节点 containerd 删除该镜像 (crictl rmi)")
                }
            }
            .onChange(of: selectedImageID) { _, newID in
                imageDetail = nil
                guard let id = newID else { return }
                let clusterName = cluster.name
                Task { @MainActor in
                    let selected = images.first { $0.imageID == id }
                    imageDetail = await manager.fetchImageDetail(cluster: clusterName, imageID: id)
                    if let selected {
                        imageUsages = await manager.fetchImageUsages(cluster: clusterName, references: selected.references)
                    } else {
                        imageUsages = []
                    }
                }
            }
            Divider()
            imageDetailPanel
            Divider()
            // 平面化拉取行 + prune
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                TextField("拉取镜像到节点 (如 docker.io/library/nginx:alpine)", text: $pullRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(pullImage)
                if pulling { ProgressView().controlSize(.small) }
                Button("拉取", action: pullImage)
                    .controlSize(.small)
                    .disabled(pullRef.trimmingCharacters(in: .whitespaces).isEmpty || pulling)
                Divider().frame(height: 14)
                Button {
                    Task {
                        do {
                            try await manager.pruneNodeImages(cluster: cluster.name)
                            await MainActor.run { refresh() }
                        } catch {
                            await MainActor.run { ToastManager.shared.showError(error.localizedDescription) }
                        }
                    }
                } label: { Label("清理未使用", systemImage: "sparkles") }
                    .controlSize(.small)
                    .help("逐项核对 Kubernetes 工作负载引用；控制平面和 CNI 系统镜像永久保留")
            }
            .padding(8)
        }
    }

    // 选中镜像的详情 + 操作（inspecti 数据源）
    @ViewBuilder
    private var imageDetailPanel: some View {
        if let img = images.first(where: { $0.imageID == selectedImageID }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("镜像详情").font(.caption.weight(.semibold))
                    Text(img8c(img.imageID)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if img.isSystemComponent { systemBadge }
                    Spacer()
                    Button { deploymentTarget = img } label: { Label("部署", systemImage: "shippingbox.and.arrow.forward") }
                        .controlSize(.small)
                        .disabled(img.isSystemComponent)
                    // crictl 无 tag/push，用节点内 ctr（k8s.io 命名空间）
                    Button { showTagField.toggle() } label: { Label("打标签", systemImage: "tag") }
                        .controlSize(.small)
                    Button { pushImage(img) } label: { Label("推送", systemImage: "arrow.up.circle") }
                        .controlSize(.small)
                        .disabled(showTagField)
                    Button { imageToDelete = img } label: { Label("删除", systemImage: "trash") }
                        .controlSize(.small).foregroundStyle(.red)
                }
                if showTagField {
                    HStack(spacing: 8) {
                        Text("目标引用:").font(.caption)
                        TextField("registry.example.com/my/nginx:v1", text: $tagTarget)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { tagImage(img) }
                        Button("确认 tag") { tagImage(img) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(tagTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("收起") { showTagField = false }
                            .controlSize(.small)
                    }
                }
                if imageUsages.isEmpty {
                    detailRow("K8s 使用方", "未发现工作负载或 Pod 引用")
                } else {
                    detailRow("K8s 使用方", imageUsages.map(\.displayName).joined(separator: "\n"))
                }
                if let d = imageDetail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            detailRow("架构", "\(d.os)/\(d.architecture)")
                            detailRow("大小", d.sizeBytes.byteCountText + (d.pinned ? " · pinned" : ""))
                            detailRow("创建", String(d.created.prefix(19).replacingOccurrences(of: "T", with: " ")))
                            detailRow("用户/目录", "\(d.user.isEmpty ? "-" : d.user) \u{00b7} \(d.workingDir.isEmpty ? "-" : d.workingDir)")
                            if !d.entrypoint.isEmpty { detailRow("入口", d.entrypoint.joined(separator: " ")) }
                            if !d.repoTags.isEmpty { detailRow("标签", d.repoTags.joined(separator: "\n")) }
                            if !d.repoDigests.isEmpty { detailRow("Digest", d.repoDigests.joined(separator: "\n")) }
                            if !d.labels.isEmpty {
                                detailRow("Labels", d.labels.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                            }
                            if !d.env.isEmpty {
                                detailRow("Env", d.env.joined(separator: "\n"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.monospaced())
                    .frame(maxHeight: 130)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("加载 inspecti...").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }
            .padding(8)
        } else {
            HStack {
                Text("在上方列表选择镜像查看详情与操作").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    // 容器 Tab：上列表（可选中）+ 下详情卡（inspect + stats）+ 操作（停/删/日志/exec）
    private var containerTab: some View {
        VStack(spacing: 0) {
            Table(containers, selection: $selectedContainerID) {
                TableColumn("容器") { Text($0.name) }
                TableColumn("镜像") { c in Text(img8c(c.image)) }
                TableColumn("状态") { c in
                    Text(c.stateText)
                        .foregroundStyle(c.isRunning ? .green : .secondary)
                        .fontWeight(.medium)
                }
                TableColumn("所属 Pod") { Text($0.podName) }
                TableColumn("命名空间") { Text($0.namespace) }
                TableColumn("") { c in
                    HStack(spacing: 6) {
                        if c.isRunning {
                            Button { stopContainer(c) } label: { Image(systemName: "stop.fill") }
                                .buttonStyle(.borderless)
                                .help("停止该容器 (crictl stop)，所属 Pod 将异常/重建")
                        }
                        Button { containerToDelete = c } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(c.isRunning)
                            .help(c.isRunning ? "运行中的容器不能直接删除，请先停止" : "从节点 containerd 删除该容器 (crictl rm)")
                    }
                }
            }
            .onChange(of: selectedContainerID) { _, newID in
                containerDetail = nil
                containerStats = nil
                logText = nil
                execOutput = nil
                guard let id = newID else { return }
                let clusterName = cluster.name
                Task { @MainActor in
                    containerDetail = await manager.fetchContainerDetail(cluster: clusterName, containerID: id)
                    containerStats = await manager.fetchContainerStats(cluster: clusterName, containerID: id)
                }
            }
            Divider()
            containerDetailPanel
        }
    }

    // 选中容器的详情 + 操作（inspect/stats/logs/exec 数据源）
    @ViewBuilder
    private var containerDetailPanel: some View {
        if let c = containers.first(where: { $0.id == selectedContainerID }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("容器详情").font(.caption.weight(.semibold))
                    Text(c.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let s = containerStats {
                        Label(s.cpuText, systemImage: "cpu")
                        Label(s.memText, systemImage: "memorychip")
                    }
                    Button { loadLogs(c) } label: { Label("日志", systemImage: "doc.text") }
                        .controlSize(.small)
                        .disabled(!c.isRunning)
                    if c.isRunning {
                        Button { stopContainer(c) } label: { Label("停止", systemImage: "stop.fill") }
                            .controlSize(.small)
                    }
                    Button { containerToDelete = c } label: { Label("删除", systemImage: "trash") }
                        .controlSize(.small).foregroundStyle(.red)
                        .disabled(c.isRunning)
                }
                if let d = containerDetail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            detailRow("ID", d.containerID)
                            detailRow("PID", String(d.pid))
                            detailRow("创建", d.createdDateText)
                            detailRow("重启次数", d.restartCount)
                            detailRow("镜像", c.image)
                            detailRow("日志路径", d.logPath)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.monospaced())
                    .frame(maxHeight: 80)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("加载 inspect...").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                if showLogs {
                    ScrollView {
                        Text(logText ?? "加载日志...")
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                }
                if c.isRunning {
                    // crictl exec：一次性命令，输出显示在下方
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        TextField("在容器内执行命令 (如 sh -c 'ls /etc')", text: $execCommand)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runExec(c) }
                        Button("执行") { runExec(c) }
                            .controlSize(.small)
                            .disabled(execCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let out = execOutput {
                        ScrollView {
                            Text(out).font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 70)
                    }
                }
            }
            .padding(8)
        } else {
            HStack {
                Text("在上方列表选择容器查看详情与操作")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var systemBadge: some View {
        Text("系统")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
            .help("集群系统组件镜像：删除可能导致集群无法恢复，需重建")
    }

    private func stateCapsule(_ text: String, isGood: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(isGood ? Color.green.opacity(0.18) : Color.orange.opacity(0.18)))
            .foregroundStyle(isGood ? .green : .orange)
    }

    // MARK: 动作（全部封装 crictl / 官方 k8s 指令）
    private func refresh() {
        loading = true
        queryError = nil
        Task {
            async let i = manager.fetchNodeImages(cluster: cluster.name)
            async let c = manager.fetchNodeContainers(cluster: cluster.name)
            async let p = manager.fetchNodePods(cluster: cluster.name)
            async let fs = manager.fetchNodeImageFsInfo(cluster: cluster.name)
            let (imgs, ctrs, pds, fsBytes) = await (i, c, p, fs)
            await MainActor.run {
                images = imgs
                containers = ctrs
                pods = pds
                imageFsBytes = fsBytes
                loading = false
                // 全空通常意味着集群未就绪（apiserver 未启动 / 集群 stopped）
                if imgs.isEmpty && ctrs.isEmpty && !cluster.isRunning {
                    queryError = "集群当前处于 \(cluster.state) 状态。请先启动集群，再查询节点内 containerd。"
                } else if imgs.isEmpty && ctrs.isEmpty {
                    queryError = "未获取到节点 containerd 数据。若集群刚启动请稍候重试；若持续失败，集群控制平面可能异常（可尝试删除后重建集群）。"
                }
            }
        }
    }

    private func pullImage() {
        let ref = pullRef.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !pulling else { return }
        pulling = true
        Task {
            try? await manager.pullNodeImage(cluster: cluster.name, reference: ref)
            await MainActor.run {
                pulling = false
                pullRef = ""
                refresh()
            }
        }
    }

    private func deleteImage(_ img: K8sNodeImage) {
        Task {
            do {
                try await manager.deleteNodeImageSafely(cluster: cluster.name, image: img)
                await MainActor.run { refresh() }
            } catch {
                await MainActor.run { ToastManager.shared.showError(error.localizedDescription) }
            }
        }
    }

    private func stopContainer(_ c: K8sNodeContainer) {
        Task {
            try? await manager.stopNodeContainer(cluster: cluster.name, id: c.id, name: c.name)
            await MainActor.run { refresh() }
        }
    }

    private func removeContainer(_ c: K8sNodeContainer) {
        Task {
            try? await manager.removeNodeContainer(cluster: cluster.name, id: c.id, name: c.name)
            await MainActor.run {
                selectedContainerID = nil
                refresh()
            }
        }
    }

    // 日志（crictl logs --tail，展开/收起切换）
    private func loadLogs(_ c: K8sNodeContainer) {
        if logText != nil { logText = nil; return }
        logText = "加载中..."
        let clusterName = cluster.name
        Task { @MainActor in
            logText = await manager.fetchContainerLogs(cluster: clusterName, containerID: c.id, tail: 100)
        }
    }

    // 打标签（节点内 ctr -n k8s.io images tag）
    private func tagImage(_ img: K8sNodeImage) {
        let target = tagTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        Task {
            try? await manager.tagNodeImage(cluster: cluster.name, from: img.displayReference, to: target)
            await MainActor.run {
                showTagField = false
                tagTarget = ""
                refresh()
            }
        }
    }

    // 推送（节点内 ctr -n k8s.io images push；未 tag 时按当前引用推）
    private func pushImage(_ img: K8sNodeImage) {
        Task {
            try? await manager.pushNodeImage(cluster: cluster.name, reference: img.displayReference)
        }
    }

    // 容器内一次性命令（crictl exec）
    private func runExec(_ c: K8sNodeContainer) {
        let raw = execCommand.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // 支持 sh -c 'xxx' 形式：整体按空格拆分传给 crictl exec
        let parts = raw.split(separator: " ").map(String.init)
        execOutput = "执行中..."
        let clusterName = cluster.name
        Task { @MainActor in
            execOutput = await manager.execInNodeContainer(cluster: clusterName, containerID: c.id, command: parts)
        }
    }
}

private func img8c(_ id: String) -> String {
    String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
    /// 长镜像名截断展示
    var abbreviated: String { count <= 40 ? self : "…" + suffix(39) }
}

// MARK: - 创建集群 Sheet（参数对齐官方 k8s create）
struct CreateK8sClusterSheet: View {
    let onCreate: (String, String?, String?, String?, String?, String?, String?, Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environmentManager: EnvironmentManager
    @StateObject private var cliForm = DynamicCLIFormState()
    @State private var name = "k8s-dev"

    private func value(_ key: String) -> String? {
        cliForm.values[key]?.first?.nilIfEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("创建 Kubernetes 集群").font(.title2.weight(.semibold))
            TextField("集群名称", text: $name).textFieldStyle(.roundedBorder)
            Text("\(environmentManager.currentEnvironment?.name ?? "未选择环境") · \(environmentManager.currentInstructionProfile?.label ?? "没有匹配的指令档位")")
                .font(.caption2)
                .foregroundStyle(environmentManager.currentInstructionProfile == nil ? .orange : .secondary)
            ScrollView {
                DynamicCLIOptionsForm(command: "k8s.create", version: environmentManager.currentVersion, state: cliForm)
            }
            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("创建") {
                    onCreate(name, value("nodeImage"), value("cni"), value("cpus"), value("memory"),
                             value("scheme"), value("maxConcurrentDownloads"),
                             cliForm.values["rm"]?.first == "true")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || environmentManager.currentInstructionProfile == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .onAppear {
            if cliForm.values["scheme"] == nil { cliForm.values["scheme"] = ["https"] }
        }
    }
}

// MARK: - 写 kubeconfig Sheet
struct WriteKubeconfigSheet: View {
    let clusterNames: [String]
    @Binding var initialName: String
    let onWrite: (String, String?) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kubeconfig = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("写入 kubeconfig").font(.title2.weight(.semibold))
            Picker("集群", selection: $initialName) {
                ForEach(clusterNames, id: \.self) { Text($0).tag($0) }
            }
            TextField("kubeconfig 路径 (可选, 默认 ~/.kube/config)", text: $kubeconfig).textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("写入") { onWrite(initialName, kubeconfig.nilIfEmpty); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460, height: 200)
    }
}

private struct K8sImageDeploymentSheet: View {
    let cluster: KubernetesCluster
    let image: K8sNodeImage
    let manager: KubernetesManager

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var namespace = "default"
    @State private var replicas = 1
    @State private var containerPort = ""
    @State private var exposeService = false
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从镜像部署到 Kubernetes").font(.headline)
                    Text("\(cluster.name) · \(image.displayReference)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.disabled(creating)
            }
            Form {
                TextField("Deployment 名称", text: $name)
                TextField("命名空间", text: $namespace)
                Stepper("副本数：\(replicas)", value: $replicas, in: 1...100)
                TextField("容器端口（可选）", text: $containerPort)
                Toggle("同时创建 ClusterIP Service", isOn: $exposeService)
                    .disabled(Int(containerPort) == nil)
            }
            .formStyle(.grouped)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(creating)
                Button {
                    create()
                } label: {
                    if creating { ProgressView().controlSize(.small) }
                    else { Label("创建 Deployment", systemImage: "shippingbox.and.arrow.forward") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 390)
        .onAppear { name = suggestedName }
    }

    private var suggestedName: String {
        let reference = image.displayReference.split(separator: "@").first.map(String.init) ?? image.displayReference
        let leaf = reference.split(separator: "/").last.map(String.init) ?? "app"
        let withoutTag = leaf.split(separator: ":").first.map(String.init) ?? leaf
        return withoutTag.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()
    }

    private func create() {
        creating = true
        errorMessage = nil
        Task {
            do {
                try await manager.createDeploymentFromImage(
                    cluster: cluster.name,
                    reference: image.displayReference,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
                    replicas: replicas,
                    containerPort: Int(containerPort),
                    exposeService: exposeService
                )
                await MainActor.run {
                    creating = false
                    ToastManager.shared.showSuccess("Deployment「\(name)」已创建")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    creating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 加载镜像 Sheet（与容器拉取镜像表单同构：镜像源/私有库/平台，另支持先拉取再加载）
struct LoadK8sImageSheet: View {
    let clusterNames: [String]
    @Binding var initialName: String
    let onLoad: (String, String, String?, Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var imgSrcMgr = ImageSourceManager.shared
    @StateObject private var registryMgr = RegistryManager.shared
    @State private var image = ""
    @State private var tag = "latest"
    @State private var registry = ""
    @State private var platform = "linux/arm64"
    @State private var pullFirst = false

    private var fullImage: String {
        let base = tag.isEmpty ? image : "\(image):\(tag)"
        guard !registry.isEmpty else { return base }
        let clean = registry
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(clean)/\(base)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("加载镜像到集群").font(.title2.weight(.semibold))
            Picker("集群", selection: $initialName) {
                ForEach(clusterNames, id: \.self) { Text($0).tag($0) }
            }
            Picker("镜像源", selection: $imgSrcMgr.currentSource) {
                Text("Docker Hub").tag(nil as ImageSource?)
                ForEach(imgSrcMgr.sources) { src in
                    Text(src.name ?? "").tag(src as ImageSource?)
                }
            }
            .onChange(of: imgSrcMgr.currentSource) { _, src in
                registry = src?.url?
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            }
            TextField("私有仓库地址 (可选)", text: $registry).textFieldStyle(.roundedBorder)
            if !registryMgr.registries.isEmpty {
                HStack(spacing: 8) {
                    Text("已登录私有库").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding<String>(
                        get: { "" },
                        set: { if !$0.isEmpty { registry = $0 } }
                    )) {
                        Text("选择...").tag("")
                        ForEach(registryMgr.registries) { reg in
                            Text(reg.hostname).tag(reg.hostname)
                        }
                    }
                    .frame(width: 200)
                }
            }
            HStack(spacing: 10) {
                TextField("镜像名称 (如 nginx)", text: $image).textFieldStyle(.roundedBorder)
                TextField("标签", text: $tag).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            HStack(spacing: 10) {
                TextField("平台 (如 linux/arm64)", text: $platform).textFieldStyle(.roundedBorder)
                Picker("", selection: $platform) {
                    Text("linux/arm64").tag("linux/arm64")
                    Text("linux/amd64").tag("linux/amd64")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
            Toggle("本地不存在时先拉取", isOn: $pullFirst)
                .controlSize(.small)
                .help("勾选后按上述引用与平台先执行 image pull，拉取成功后再加载进集群")
            Text("加载: \(fullImage)").font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("加载") { onLoad(initialName, fullImage, platform.nilIfEmpty, pullFirst); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(image.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460, height: 430)
    }
}

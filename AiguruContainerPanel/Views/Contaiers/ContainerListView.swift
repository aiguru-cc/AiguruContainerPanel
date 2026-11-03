////
//  ContainerListView.swift
//  AiguruContainerPanel
//
//  容器列表主视图，工具栏已移至窗口标题栏。
//  列表与详情按 4.5 : 5.5 响应式分栏。
//

import SwiftUI

struct ContainerListView: View {
    @EnvironmentObject private var viewModel: ContainerListViewModel
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var filterState: ContainerState? = nil
    @State private var selectedContainerID: String? = nil
    @State private var expandedClusterIDs: Set<String> = []
    @State private var standaloneExpanded = true
    @State private var kubernetesExpanded = true
    @ObservedObject private var kubernetesManager = KubernetesManager.shared
    @ObservedObject private var environmentManager = EnvironmentManager.shared

    var filteredContainers: [Container] {
        var result = viewModel.containers
        if let filterState = filterState {
            result = result.filter { $0.state == filterState }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.image.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var selectedContainer: Container? {
        filteredContainers.first { $0.id == selectedContainerID }
    }

    /// 应用集群由模板部署时写入标签。未带该标签的容器始终归入零散容器，
    /// 不根据名称猜测归属，避免误把用户手动创建的容器收进集群。
    private var applicationClusters: [ContainerListGroup] {
        let grouped = Dictionary(grouping: filteredContainers.compactMap { container -> (String, Container)? in
            guard let cluster = container.labels?["cc.aiguru.application-cluster"], !cluster.isEmpty else { return nil }
            return (cluster, container)
        }, by: \.0)
        return grouped.map { name, members in
            ContainerListGroup(
                id: name,
                name: name,
                containers: members.map(\.1).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var standaloneContainers: [Container] {
        filteredContainers
            .filter {
                $0.labels?["cc.aiguru.application-cluster"]?.isEmpty != false
                    && !isKubernetesContainer($0)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// `container k8s list` 返回的每个集群对应一个底层节点容器；容器内的 Pod/CRI
    /// 资源不属于宿主 container list，继续在 Kubernetes 页面管理。
    private var kubernetesClusterNames: Set<String> {
        Set(kubernetesManager.clusters.map(\.name))
    }

    private var kubernetesContainers: [Container] {
        filteredContainers
            .filter(isKubernetesContainer)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// K8s 插件会给节点容器写入官方标签。标签判断不依赖异步的
    /// `k8s list`，避免加载期间或子命令不可用时被短暂归入“零散容器”。
    /// 名称集合仅用于兼容没有插件标签的早期版本。
    private func isKubernetesContainer(_ container: Container) -> Bool {
        if container.labels?["com.apple.container.plugin"] == "k8s" { return true }
        return kubernetesClusterNames.contains(container.displayName)
    }

    // MARK: - Body (broken up for type-checker)
    var body: some View {
        GeometryReader { proxy in
            let dividerWidth: CGFloat = 1
            let contentWidth = max(0, proxy.size.width - dividerWidth)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: contentWidth * 0.45)
                Divider()
                    .frame(width: dividerWidth)
                detail
                    .frame(width: contentWidth * 0.55)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateContainerView { name, image, ports, env, volumes, options in
                viewModel.createContainer(name: name, image: image, ports: ports, env: env, volumes: volumes, options: options)
            }
        }
        .sheet(isPresented: $viewModel.showLogView) {
            ContainerLogView(viewModel: viewModel)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.refreshContainers()
            }
            Task { await kubernetesManager.fetchClusters() }
        }
        .alert("错误", isPresented: errorAlertVisible) {
            Button("确定") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .toolbar { toolbarContent }
    }

    private var errorAlertVisible: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && viewModel.containers.isEmpty {
                ProgressView("加载容器列表...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredContainers.isEmpty {
                emptySidebar
            } else {
                sidebarList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySidebar: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.box")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("没有容器")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("点击工具栏「创建容器」开始")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarList: some View {
        List {
            if !standaloneContainers.isEmpty {
                DisclosureGroup(isExpanded: $standaloneExpanded) {
                    ForEach(standaloneContainers) { containerRow($0) }
                } label: {
                    groupLabel("零散容器", count: standaloneContainers.count, icon: "cube.box", color: .secondary)
                }
            }

            if !applicationClusters.isEmpty {
                Section("应用集群") {
                    ForEach(applicationClusters) { cluster in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedClusterIDs.contains(cluster.id) },
                                set: { expanded in
                                    if expanded { expandedClusterIDs.insert(cluster.id) }
                                    else { expandedClusterIDs.remove(cluster.id) }
                                }
                            )
                        ) {
                            ForEach(cluster.containers) { containerRow($0) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                                Text(cluster.name).fontWeight(.semibold)
                                Spacer()
                                Text("\(cluster.runningCount)/\(cluster.containers.count)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(cluster.runningCount == cluster.containers.count ? .green : .secondary)
                            }
                        }
                    }
                }
            }

            if !kubernetesContainers.isEmpty {
                DisclosureGroup(isExpanded: $kubernetesExpanded) {
                    ForEach(kubernetesContainers) { containerRow($0) }
                } label: {
                    groupLabel("Kubernetes 集群", count: kubernetesContainers.count, icon: "gyroscope", color: .blue)
                }
            }
        }
        .listStyle(PlainListStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func containerRow(_ container: Container) -> some View {
                ContainerListRow(
                    container: container,
                    isSelected: container.id == selectedContainerID
                )
                .onTapGesture {
                    selectedContainerID = (selectedContainerID == container.id) ? nil : container.id
                    viewModel.selectContainer(container)
                }
                .contextMenu { contextMenuContent(for: container, viewModel: viewModel) }
    }

    private func groupLabel(_ title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).fontWeight(.semibold)
            Spacer()
            Text("\(count)").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = selectedContainer {
            ContainerDetailView(container: selected, viewModel: viewModel)
                .id("\(selected.id)-\(selected.state.rawValue)-\(selected.status)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "info.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("选择一个容器查看详情")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: { viewModel.refreshContainers() }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新容器列表")

            Button(action: { showCreateSheet = true }) {
                Label("创建容器", systemImage: "plus")
            }
            .help("创建新容器")

            Picker("状态", selection: $filterState) {
                Text("全部").tag(nil as ContainerState?)
                Text("运行中").tag(ContainerState.running as ContainerState?)
                Text("已停止").tag(ContainerState.stopped as ContainerState?)
                Text("已暂停").tag(ContainerState.paused as ContainerState?)
                Text("已退出").tag(ContainerState.exited as ContainerState?)
            }
            .frame(width: 120)

            TextField("搜索容器...", text: $searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 180)

            Menu {
                Button("清理所有已停止容器") {
                    viewModel.pruneContainers()
                }
                .foregroundColor(.red)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func contextMenuContent(for container: Container, viewModel: ContainerListViewModel) -> some View {
        Button("启动") { viewModel.startContainer(container) }
        Button("停止") { viewModel.stopContainer(container) }
        Button("重启") { viewModel.restartContainer(container) }
        Divider()
        Toggle("异常停止时自动唤醒", isOn: guardianEnabledBinding(for: container))
        Menu("最大尝试次数") {
            Picker("最大尝试次数", selection: guardianAttemptsBinding(for: container)) {
                ForEach(1...10, id: \.self) { Text("\($0) 次").tag($0) }
            }
        }
        if container.state == .running,
           CLICommandCatalog.shared.supports(command: "container.clean", version: environmentManager.currentVersion) {
            Button("回收文件系统空间") { viewModel.cleanContainer(container) }
        }
        Divider()
        Button("查看日志") { viewModel.fetchLogs(for: container) }
        Button("打开终端") { viewModel.openTerminal(for: container) }
        Divider()
        Button("删除", role: .destructive) { viewModel.deleteContainer(container) }
        Button("强制删除", role: .destructive) { viewModel.forceDeleteContainer(container) }
    }

    private func guardianEnabledBinding(for container: Container) -> Binding<Bool> {
        Binding(
            get: { ContainerGuardian.shared.configuration(for: container.id).enabled },
            set: { ContainerGuardian.shared.setEnabled($0, for: container) }
        )
    }

    private func guardianAttemptsBinding(for container: Container) -> Binding<Int> {
        Binding(
            get: { ContainerGuardian.shared.configuration(for: container.id).maximumAttempts },
            set: { ContainerGuardian.shared.setMaximumAttempts($0, for: container) }
        )
    }
}

private struct ContainerListGroup: Identifiable {
    let id: String
    let name: String
    let containers: [Container]
    var runningCount: Int { containers.filter { $0.state == .running }.count }
}
// MARK: - 列表行
struct ContainerListRow: View {
    let container: Container
    let isSelected: Bool
    @ObservedObject private var guardian = ContainerGuardian.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: container.state.icon)
                .foregroundColor(container.state.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(container.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let version = container.labels?[AppConstants.ContainerLabel.cliVersion], !version.isEmpty {
                        Text("CLI \(version)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                            .foregroundStyle(.blue)
                    }
                    if let service = container.labels?["cc.aiguru.application-service"], !service.isEmpty {
                        Text(service)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.14)))
                            .foregroundStyle(.purple)
                    }
                    if let role = container.labels?["cc.aiguru.application-role"], !role.isEmpty {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }
                Text(container.image)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let ip = container.ipAddress {
                    Text(ip)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }else{
                    Text("启动后显示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { guardian.configuration(for: container.id).enabled },
                set: { guardian.setEnabled($0, for: container) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("异常停止时自动唤醒")

            if guardian.configuration(for: container.id).enabled {
                let configuration = guardian.configuration(for: container.id)
                VStack(spacing: 1) {
                    Image(systemName: configuration.manuallyStopped ? "shield.slash" : "shield.checkered")
                    Text("\(configuration.attempts)/\(configuration.maximumAttempts)")
                        .font(.system(size: 8, design: .monospaced))
                }
                .font(.caption2)
                .foregroundStyle(configuration.manuallyStopped ? Color.secondary : Color.blue)
                .help(configuration.manuallyStopped ? "已手动停止，不自动唤醒" : "守护已启用：已尝试/最大次数")
            }

            Text(container.state.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(container.state.color.opacity(0.15))
                .cornerRadius(4)
                .foregroundColor(container.state.color)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
    }
}

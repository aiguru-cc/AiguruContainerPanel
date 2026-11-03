//
//  ApplicationClusterView.swift
//  AiguruContainerPanel
//
//  应用集群的独立资源面板。模板仅作为创建流程的声明输入。
//

import SwiftUI
import AppKit

struct ApplicationClusterView: View {
    @ObservedObject private var containerManager = ContainerManager.shared
    @ObservedObject private var containerGuardian = ContainerGuardian.shared
    @ObservedObject private var environmentManager = EnvironmentManager.shared
    @State private var selectedClusterID: String?
    @State private var showCreateSheet = false
    @State private var appendTarget: ApplicationCluster?
    @State private var publishTarget: ApplicationCluster?
    @State private var pendingDeletion: ApplicationCluster?
    @State private var operationMessage: String?
    @State private var isOperating = false
    @State private var operationTitle = ""
    @State private var operationCurrentTarget = ""
    @State private var operationCompletedCount = 0
    @State private var operationTotalCount = 0
    @State private var showingForceDNSRefresh = false
    @State private var isRefreshingDNS = false
    @State private var dnsRefreshMessage: String?
    @State private var selectedServiceName: String?
    @State private var selectedDetailTab: ClusterDetailTab = .overview
    @State private var detailContainer: Container?
    @StateObject private var detailContainerViewModel = ContainerListViewModel()

    private var clusters: [ApplicationCluster] {
        ApplicationCluster.discover(in: containerManager.containers)
    }

    private var selectedCluster: ApplicationCluster? {
        clusters.first { $0.id == selectedClusterID }
    }

    var body: some View {
        HSplitView {
            clusterList
            clusterDetail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .overlay(alignment: .topTrailing) {
            if isOperating {
                clusterOperationProgressCard
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isOperating)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCreateSheet, onDismiss: refresh) {
            TemplateView()
                .frame(minWidth: 820, idealWidth: 960, minHeight: 660, idealHeight: 760)
        }
        .sheet(item: $appendTarget, onDismiss: refresh) { cluster in
            CreateContainerView(applicationCluster: cluster) { name, image, ports, environment, volumes, options in
                Task {
                    do {
                        _ = try await containerManager.createContainer(
                            name: name,
                            image: image,
                            ports: ports,
                            env: environment,
                            volumes: volumes,
                            options: options
                        )
                        await containerManager.fetchContainers()
                        await MainActor.run {
                            ToastManager.shared.showSuccess("容器「\(name)」已追加到应用集群")
                        }
                    } catch {
                        await MainActor.run {
                            ToastManager.shared.showError("追加容器失败：\(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        .sheet(item: $publishTarget) { cluster in
            PublicDockerPublishWizard(cluster: cluster)
        }
        .sheet(item: $detailContainer) { container in
            ClusterContainerDetailSheet(container: container, viewModel: detailContainerViewModel)
        }
        .sheet(isPresented: $detailContainerViewModel.showLogView) {
            ContainerLogView(viewModel: detailContainerViewModel)
        }
        .alert("删除应用集群", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { cluster in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除全部容器", role: .destructive) {
                perform(.delete, for: cluster)
                pendingDeletion = nil
            }
        } message: { cluster in
            Text("将删除集群「\(cluster.name)」的 \(cluster.desiredCount) 个容器。卷和镜像不会被删除。")
        }
        .alert("强制刷新 macOS DNS", isPresented: $showingForceDNSRefresh) {
            Button("取消", role: .cancel) { }
            Button("授权并刷新") { forceRefreshMacOSDNS() }
        } message: {
            Text("将短暂重新注册 Apple Container 的本地 DNS 转发域，并清理 macOS DNS 缓存、重新加载 mDNSResponder。不会删除网络或重启容器，但刷新期间所有本地域名可能短暂不可用。")
        }
        .onAppear {
            ensureValidSelection(for: clusters.map(\.id))
            refresh()
        }
        .onChange(of: clusters.map(\.id)) { _, ids in
            ensureValidSelection(for: ids)
        }
        .onChange(of: selectedClusterID) { _, selectedID in
            // List 点击空白会清空 selection；集群仍存在时保持一个稳定选中项，避免详情区域坍塌。
            if selectedID == nil, let fallback = clusters.first?.id {
                selectedClusterID = fallback
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有应用集群")
                .font(.headline)
            Text("从模板创建一个应用集群；创建后这里会显示服务关系与容器资源表。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { showCreateSheet = true } label: {
                Label("创建应用集群", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var clusterList: some View {
        List(selection: $selectedClusterID) {
            Section("应用集群") {
                if clusters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("暂无应用集群", systemImage: "square.stack.3d.up.slash")
                            .font(.caption.weight(.medium))
                        Text("可从模板创建或刷新发现")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(clusters) { cluster in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                            Text(cluster.name).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(cluster.runningCount)/\(cluster.desiredCount)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(cluster.runningCount == cluster.desiredCount ? .green : .orange)
                        }
                        Text("\(cluster.serviceGroups.count) 服务 · \(cluster.desiredCount) 容器")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(cluster.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = cluster
                        } label: {
                            Label("删除应用集群", systemImage: "trash")
                        }
                        .disabled(isOperating)
                    }
                }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(minWidth: 210, idealWidth: 250, maxWidth: 310)
    }

    @ViewBuilder
    private var clusterDetail: some View {
        if let cluster = selectedCluster {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(cluster)
                Divider()
                TabView(selection: $selectedDetailTab) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            serviceOverview(cluster)
                            Divider()
                            containerTable(cluster)
                            operationStatus
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .tabItem { Label("概览", systemImage: "square.grid.2x2") }
                    .tag(ClusterDetailTab.overview)

                    ScrollView {
                        networkOverview(cluster)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .tabItem { Label("网络", systemImage: "network") }
                    .tag(ClusterDetailTab.network)

                    ScrollView {
                        mountOverview(cluster)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .tabItem { Label("挂载", systemImage: "externaldrive") }
                    .tag(ClusterDetailTab.mounts)
                }
            }
        } else {
            emptyState
        }
    }

    private func detailHeader(_ cluster: ApplicationCluster) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name).font(.headline)
                Text("运行 \(cluster.runningCount) / \(cluster.desiredCount) · \(cluster.serviceGroups.count) 个服务 · \(cluster.networkNames.count) 个网络 · \(cluster.mounts.count) 个挂载")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { perform(.start, for: cluster) } label: { Label("启动", systemImage: "play.fill") }
                .disabled(isOperating || cluster.runningCount == cluster.desiredCount)
            Button { perform(.stop, for: cluster) } label: { Label("停止", systemImage: "stop.fill") }
                .disabled(isOperating || cluster.runningCount == 0)
            Button { perform(.restart, for: cluster) } label: { Label("重启", systemImage: "arrow.clockwise") }
                .disabled(isOperating)
            Menu {
                Button { appendTarget = cluster } label: { Label("追加容器", systemImage: "plus") }
                Button { publishTarget = cluster } label: { Label("发布", systemImage: "arrow.up.circle") }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .disabled(isOperating)
            Button(role: .destructive) { pendingDeletion = cluster } label: {
                Label("删除", systemImage: "trash")
            }
                .disabled(isOperating)
                .help("删除集群中的全部容器，不删除卷和镜像")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func networkOverview(_ cluster: ApplicationCluster) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("集群网络", systemImage: "network")
                    .font(.headline)
                Spacer()
                Button {
                    showingForceDNSRefresh = true
                } label: {
                    if isRefreshingDNS {
                        ProgressView().controlSize(.small)
                        Text("正在刷新 DNS")
                    } else {
                        Label("强制刷新 DNS", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingDNS || isOperating)
                .help("重新注册 Container DNS 转发域并清理 macOS DNS 缓存")
            }
            Text("应用集群中全部容器使用的 Apple Container 网络。")
                .font(.caption).foregroundStyle(.secondary)
            if let dnsRefreshMessage {
                Text(dnsRefreshMessage)
                    .font(.caption)
                    .foregroundStyle(dnsRefreshMessage.hasPrefix("DNS 刷新完成") ? Color.green : Color.red)
            }
            if cluster.networkNames.isEmpty {
                ContentUnavailableView("未获取到网络配置", systemImage: "network.slash")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ClusterNetworkTopologyView(cluster: cluster)
                ForEach(cluster.networkNames, id: \.self) { network in
                    HStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network).font(.body.monospaced())
                            Text("\(containerCount(in: network, cluster: cluster)) 个容器")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
    }

    private func containerCount(in network: String, cluster: ApplicationCluster) -> Int {
        cluster.containers.filter { container in
            container.configuration?.networks?.contains(where: { $0.network == network }) == true
        }.count
    }

    private func forceRefreshMacOSDNS() {
        isRefreshingDNS = true
        dnsRefreshMessage = "正在请求管理员授权…"
        Task {
            do {
                let executor = CommandExecutor.shared
                let output = try await executor.execute(CLICommandCatalog.shared.arguments(command: "system.dns.list", options: ["format": ["json"]]))
                var domains = (try? JSONDecoder().decode([String].self, from: Data(output.utf8))) ?? []
                if domains.isEmpty { domains = ["local"] }

                let cli = shellQuote(executor.currentCliPath)
                let refreshDomains = domains.map { domain in
                    let delete = ([cli] + CLICommandCatalog.shared.arguments(command: "system.dns.delete", positionals: [domain]).map(shellQuote)).joined(separator: " ")
                    let create = ([cli] + CLICommandCatalog.shared.arguments(command: "system.dns.create", positionals: [domain]).map(shellQuote)).joined(separator: " ")
                    return "\(delete) >/dev/null 2>&1 || true; \(create)"
                }.joined(separator: "; ")
                let shellCommand = "set -e; \(refreshDomains); /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
                let appleScript = "do shell script \"\(appleScriptString(shellCommand))\" with administrator privileges"
                _ = try await executor.executeSystemCommand(
                    arguments: [AppConstants.CLI.osascriptPath, "-e", appleScript]
                )
                await containerManager.fetchContainers()
                await MainActor.run {
                    dnsRefreshMessage = "DNS 刷新完成：\(domains.joined(separator: "、"))"
                    isRefreshingDNS = false
                    ToastManager.shared.showSuccess("macOS 与 Apple Container DNS 已刷新")
                }
            } catch {
                await MainActor.run {
                    dnsRefreshMessage = "DNS 刷新失败：\(error.localizedDescription)"
                    isRefreshingDNS = false
                    ToastManager.shared.showError("DNS 刷新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func mountOverview(_ cluster: ApplicationCluster) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("卷与挂载", systemImage: "externaldrive")
                .font(.headline)
            Text("展示集群全部挂载，不再截断为前 8 项。")
                .font(.caption).foregroundStyle(.secondary)
            if cluster.mounts.isEmpty {
                ContentUnavailableView("没有挂载", systemImage: "externaldrive.badge.xmark")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(cluster.mounts) { mount in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(mount.source).font(.caption.monospaced()).textSelection(.enabled)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(mount.destination).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Label(mount.services.sorted().joined(separator: ", "), systemImage: "cube.box")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var operationStatus: some View {
        if let operationMessage {
            Divider()
            Text(operationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var clusterOperationProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(operationTitle)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(operationCompletedCount)/\(operationTotalCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(operationCompletedCount),
                total: Double(max(operationTotalCount, 1))
            )
            .progressViewStyle(.linear)
            Text(operationCurrentTarget.isEmpty ? "正在准备…" : operationCurrentTarget)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func serviceOverview(_ cluster: ApplicationCluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("服务关系").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(cluster.serviceGroups) { service in
                    Button {
                        selectedServiceName = selectedServiceName == service.name ? nil : service.name
                    } label: { HStack(spacing: 6) {
                        Image(systemName: "cube.box.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(service.name).font(.caption.weight(.medium)).lineLimit(1)
                                if let role = service.role {
                                    Text(role).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                                }
                            }
                            Text("\(service.runningCount)/\(service.containers.count) 运行")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    } }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(selectedServiceName == service.name ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(serviceStatusColor(service))
                                .frame(width: 6, height: 6)
                            Text("\(service.runningCount)/\(service.containers.count)")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }
                }
            }
        }
        .padding(12)
    }

    private func containerTable(_ cluster: ApplicationCluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedServiceName == nil ? "容器实例" : "容器实例 · \(selectedServiceName!)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if selectedServiceName != nil {
                    Button("显示全部") { selectedServiceName = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    tableHeader("容器")
                    tableHeader("服务 / 角色")
                    tableHeader("运行")
                    tableHeader("守护")
                    tableHeader("端口")
                    tableHeader("IP / DNS")
                }
                Divider().gridCellColumns(6)
                ForEach(cluster.containers.filter { selectedServiceName == nil || $0.labels?["cc.aiguru.application-service"] == selectedServiceName }) { container in
                    GridRow {
                        Button {
                            detailContainerViewModel.selectContainer(container)
                            detailContainer = container
                        } label: {
                            Text(container.displayName)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("打开容器详情")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(container.labels?["cc.aiguru.application-service"] ?? "—").font(.caption)
                            if let role = container.labels?["cc.aiguru.application-role"] { Text(role).font(.caption2).foregroundStyle(.tint) }
                        }
                        Button {
                            toggleContainerState(container)
                        } label: {
                            Image(systemName: container.state == .running ? "play.circle.fill" : "stop.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(container.state == .running ? Color.green : Color.red)
                        }
                        .buttonStyle(.plain)
                        .help(container.state == .running ? "运行中，点击停止" : "已停止，点击启动")
                        HStack(spacing: 4) {
                            Toggle("", isOn: guardianEnabledBinding(for: container))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help("异常停止时自动唤醒")
                            if containerGuardian.configuration(for: container.id).enabled {
                                Menu {
                                    Picker("最大尝试次数", selection: guardianAttemptsBinding(for: container)) {
                                        ForEach(1...10, id: \.self) { Text("\($0) 次").tag($0) }
                                    }
                                } label: {
                                    let configuration = containerGuardian.configuration(for: container.id)
                                    Text("\(configuration.attempts)/\(configuration.maximumAttempts)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(configuration.manuallyStopped ? Color.secondary : Color.blue)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help(configurationHelp(for: container))
                            }
                        }
                        Text(container.formattedPorts)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(container.formattedPorts)
                        VStack(alignment: .leading, spacing: 1) {
                            if let ip = container.ipAddress?.split(separator: "/").first.map(String.init) {
                                copyableInstanceValue(ip, kind: "IP")
                            } else {
                                compactUnavailableValue
                            }
                            if let dns = container.labels?["cc.aiguru.application-dns-name"], !dns.isEmpty {
                                copyableInstanceValue(dns, kind: "DNS")
                            } else {
                                compactUnavailableValue
                            }
                        }
                    }
                    .contextMenu { containerContextMenu(for: container) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tableHeader(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func containerContextMenu(for container: Container) -> some View {
        Button("启动") { detailContainerViewModel.startContainer(container) }
            .disabled(container.state == .running)
        Button("停止") { detailContainerViewModel.stopContainer(container) }
            .disabled(container.state != .running)
        Button("重启") { detailContainerViewModel.restartContainer(container) }
        Divider()
        Toggle("异常停止时自动唤醒", isOn: guardianEnabledBinding(for: container))
        Menu("最大尝试次数") {
            Picker("最大尝试次数", selection: guardianAttemptsBinding(for: container)) {
                ForEach(1...10, id: \.self) { Text("\($0) 次").tag($0) }
            }
        }
        if container.state == .running,
           CLICommandCatalog.shared.supports(command: "container.clean", version: environmentManager.currentVersion) {
            Button("回收文件系统空间") { detailContainerViewModel.cleanContainer(container) }
        }
        Divider()
        Button("查看详情") {
            detailContainerViewModel.selectContainer(container)
            detailContainer = container
        }
        Button("查看日志") { detailContainerViewModel.fetchLogs(for: container) }
        Button("打开终端") { detailContainerViewModel.openTerminal(for: container) }
        Divider()
        Button("删除", role: .destructive) { detailContainerViewModel.deleteContainer(container) }
        Button("强制删除", role: .destructive) { detailContainerViewModel.forceDeleteContainer(container) }
    }

    private func guardianEnabledBinding(for container: Container) -> Binding<Bool> {
        Binding(
            get: { containerGuardian.configuration(for: container.id).enabled },
            set: { containerGuardian.setEnabled($0, for: container) }
        )
    }

    private func guardianAttemptsBinding(for container: Container) -> Binding<Int> {
        Binding(
            get: { containerGuardian.configuration(for: container.id).maximumAttempts },
            set: { containerGuardian.setMaximumAttempts($0, for: container) }
        )
    }

    private func configurationHelp(for container: Container) -> String {
        let configuration = containerGuardian.configuration(for: container.id)
        return configuration.manuallyStopped
            ? "已手动停止，不自动唤醒；点击可设置最大尝试次数"
            : "已尝试/最大次数；点击可设置最大尝试次数"
    }

    private func toggleContainerState(_ container: Container) {
        if container.state == .running {
            containerGuardian.markManualStop(container)
            Task {
                let stopped = await containerManager.stopContainer(id: container.id)
                if !stopped { containerGuardian.markExplicitStart(container) }
            }
        } else {
            containerGuardian.markExplicitStart(container)
            Task { await containerManager.startContainer(id: container.id) }
        }
    }

    private func copyableInstanceValue(_ value: String, kind: String) -> some View {
        Text(value)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                ToastManager.shared.showSuccess("已复制\(kind)：\(value)")
            }
            .help("双击复制\(kind)：\(value)")
    }

    private var compactUnavailableValue: some View {
        Text("—")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func serviceStatusColor(_ service: ApplicationClusterService) -> Color {
        if service.runningCount == service.containers.count { return .green }
        if service.runningCount == 0 { return .red }
        return .orange
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }
            Button { showCreateSheet = true } label: { Label("创建应用集群", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
    }

    private enum ClusterOperation { case start, stop, restart, delete }
    private enum ClusterDetailTab: Hashable { case overview, network, mounts }

    private func refresh() {
        Task { await containerManager.fetchContainers() }
    }

    private func ensureValidSelection(for ids: [String]) {
        guard !ids.isEmpty else {
            selectedClusterID = nil
            return
        }
        if let selectedClusterID, ids.contains(selectedClusterID) { return }
        selectedClusterID = ids.first
    }

    private func perform(_ operation: ClusterOperation, for cluster: ApplicationCluster) {
        if case .delete = operation, selectedClusterID == cluster.id {
            // 删除当前项时预先移到相邻集群；删除非当前项则完全保留原选择。
            // 这样最终列表更新不会无条件跳回第一项。
            let ids = clusters.map(\.id)
            if let deletedIndex = ids.firstIndex(of: cluster.id) {
                let remaining = ids.filter { $0 != cluster.id }
                selectedClusterID = remaining.indices.contains(deletedIndex)
                    ? remaining[deletedIndex]
                    : remaining.last
            }
            selectedServiceName = nil
        }
        let targets: [Container]
        switch operation {
        case .start: targets = cluster.containers.filter { $0.state != .running }
        case .stop: targets = cluster.containers.filter { $0.state == .running }
        case .restart, .delete: targets = cluster.containers
        }
        switch operation {
        case .start: operationTitle = "正在启动「\(cluster.name)」"
        case .stop: operationTitle = "正在停止「\(cluster.name)」"
        case .restart: operationTitle = "正在重启「\(cluster.name)」"
        case .delete: operationTitle = "正在删除「\(cluster.name)」"
        }
        operationCurrentTarget = "正在准备…"
        operationCompletedCount = 0
        operationTotalCount = targets.count
        isOperating = true
        operationMessage = "正在处理集群「\(cluster.name)」…"
        Task {
            for (index, container) in targets.enumerated() {
                await MainActor.run {
                    operationCurrentTarget = container.displayName
                    operationCompletedCount = index
                }
                switch operation {
                case .start:
                    containerGuardian.markExplicitStart(container)
                    await containerManager.startContainer(id: container.id)
                case .stop:
                    containerGuardian.markManualStop(container)
                    let stopped = await containerManager.stopContainer(id: container.id)
                    if !stopped { containerGuardian.markExplicitStart(container) }
                case .restart:
                    containerGuardian.markManualStop(container)
                    let stopped = await containerManager.stopContainer(id: container.id)
                    containerGuardian.markExplicitStart(container)
                    if stopped { await containerManager.startContainer(id: container.id) }
                case .delete:
                    // 集群删除是批处理：逐个执行 CLI，但只在全部完成后刷新一次。
                    containerGuardian.removeConfiguration(for: container)
                    await containerManager.deleteContainer(id: container.id, refreshAfterDeletion: false)
                }
                await MainActor.run {
                    operationCompletedCount = index + 1
                }
            }
            await containerManager.fetchContainers()
            await MainActor.run {
                isOperating = false
                operationCurrentTarget = ""
                operationMessage = "已完成：\(cluster.name)（\(targets.count) 个容器）"
            }
        }
    }
}

/// 以独立 Sheet 承载原容器详情，关闭时不会改变应用集群页面的选择、Tab和滚动状态。
private struct ClusterContainerDetailSheet: View {
    let container: Container
    @ObservedObject var viewModel: ContainerListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("容器详情", systemImage: "cube.box")
                    .font(.headline)
                Text(container.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ContainerDetailView(container: container, viewModel: viewModel)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 620, idealHeight: 760)
    }
}

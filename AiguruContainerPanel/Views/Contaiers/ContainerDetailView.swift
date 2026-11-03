//
//  ContainerDetailView.swift
//  AiguruContainerPanel
//
//  容器详情与操作；按当前环境版本查询 CLICommandCatalog 能力。
//  融合旧版紧凑布局与新版完整功能。
//

import SwiftUI
import AppKit
internal import  UniformTypeIdentifiers

// MARK: - 主视图
struct ContainerDetailView: View {
    let container: Container
    @ObservedObject var viewModel: ContainerListViewModel
    @State private var showingLogs = false
    @State private var showingDeleteConfirmation = false
    @State private var editConfig: ContainerConfig?
    @State private var showingStats = false
    @State private var details: ContainerDetails?
    @State private var isLoadingDetails = false
    @State private var logLines: [String] = []
    @State private var isLogLoading = false
    @State private var logShowBoot = false
    @State private var logTail: Int = 0

    private let logTailChoices = [0, 50, 100, 200, 500]

    private let manager = ContainerManager.shared
    @ObservedObject private var environmentManager = EnvironmentManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题头
                HStack {
                    VStack(alignment: .leading) {
                        Text(container.displayName)
                            .font(.largeTitle)
                            .bold()
                        Text("镜像: \(container.image)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    statusBadge
                }
                Divider()

                // 基本信息卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    InfoCard(title: "ID", value: container.id, icon: "number", color: .blue)
                    InfoCard(title: "状态", value: container.state.displayName, icon: "circle.fill", color: container.state.color)
                    let dateString = details?.createdAt ?? container.createdAt
                    InfoCard(title: "创建时间", value: formatDate(dateString), icon: "calendar", color: .indigo)
                    if let network = details?.network {
                        InfoCard(title: "网络", value: network, icon: "network", color: .cyan)
                    }
                    if let resources = container.resources {
                        if let cpus = resources.cpus {
                            InfoCard(title: "CPU", value: "\(cpus) 核", icon: "cpu", color: .blue)
                        }
                        if let memory = resources.memoryInBytes {
                            let memStr = ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)
                            InfoCard(title: "内存", value: memStr, icon: "memorychip", color: .green)
                        }
                    }
                    if let ip = container.ipAddress ?? details?.ipAddress {
                        let address = ip.split(separator: "/").first.map(String.init) ?? ip
                        InfoCard(title: "IP", value: address, icon: "globe", color: .teal, copyValue: address)
                    }
                    if let dns = container.labels?["cc.aiguru.application-dns-name"], !dns.isEmpty {
                        InfoCard(title: "DNS", value: dns, icon: "network", color: .cyan, copyValue: dns)
                    }
                }

                if let ports = container.ports, !ports.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("端口映射", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
                        ForEach(ports, id: \.containerPort) { port in
                            Text("\(port.hostPortString ?? "?") → \(port.containerPortString)/\(port.protocolType)")
                                .font(.caption.monospaced()).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // 卷挂载
                VStack(alignment: .leading, spacing: 4) {
                    Label("卷挂载", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                    if isLoadingDetails {
                        HStack { ProgressView().scaleEffect(0.6); Text("加载中...").font(.caption).foregroundColor(.secondary) }
                    } else if let volumes = details?.volumes, !volumes.isEmpty {
                        ForEach(volumes) { volume in
                            Text("\(volume.source.isEmpty ? "(匿名)" : volume.source) → \(volume.destination)")
                                .font(.caption.monospaced()).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        }
                    } else {
                        Text("无挂载卷").font(.caption).foregroundColor(.secondary).padding(4)
                    }
                }

                // 操作按钮
                HStack(spacing: 12) {
                    if container.state == .stopped || container.state == .exited {
                        Button("启动") {
                            Task {
                                await manager.startContainer(id: container.id)
                                 viewModel.refreshContainers()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if container.state == .running {
                        Button("停止") {
                            Task {
                                await manager.stopContainer(id: container.id)
                                 viewModel.refreshContainers()
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    Button("强制停止") {
                        Task {
                            do {
                                _ = try await manager.executor.execute(CLICommandCatalog.shared.arguments(command: "container.kill", positionals: [container.id]))
                                ToastManager.shared.showSuccess("容器已强制停止")
                                viewModel.refreshContainers()
                            } catch {
                                ToastManager.shared.showError("强制停止失败: \(error.localizedDescription)")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    if container.state == .running,
                       CLICommandCatalog.shared.supports(command: "container.clean", version: environmentManager.currentVersion) {
                        Button("回收空间") {
                            Task { await manager.cleanContainer(id: container.id) }
                        }
                        .buttonStyle(.bordered)
                        .help("Container 1.4.1：回收运行中容器根文件系统和可写实名卷的未使用块")
                    }
                    Divider()
                    Button("统计") {
                        showingStats = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)

                    Button("终端"){
                        viewModel.openTerminal(for: container)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)

                    Button("查看日志") {
                        showingLogs = true
                        loadLogs()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)

                    Button("复制文件") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            let alert = NSAlert()
                            alert.messageText = "复制到容器"
                            alert.informativeText = "请输入容器内的目标路径 (例如 /tmp/myfile)"
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                            alert.accessoryView = input
                            alert.addButton(withTitle: "确定")
                            alert.addButton(withTitle: "取消")
                            let response = alert.runModal()
                            if response == .alertFirstButtonReturn {
                                let dest = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !dest.isEmpty else { return }
                                Task {
                                    do {
                                        let args = CLICommandCatalog.shared.arguments(
                                            command: "container.copy",
                                            positionals: [url.path, "\(container.id):\(dest)"]
                                        )
                                        _ = try await manager.executor.execute(args)
                                        ToastManager.shared.showSuccess("文件复制成功")
                                    } catch {
                                        ToastManager.shared.showError("复制失败: \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)


                    Button("备份容器") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "tar")!]
                        panel.nameFieldStringValue = "\(container.displayName)-filesystem.tar"
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            Task {
                                do {
                                    try await ContainerBackupManager.shared.createBackup(container: container, archiveURL: url)
                                    ToastManager.shared.showSuccess("备份成功（文件系统、配置和说明）；挂载卷需单独备份")
                                } catch {
                                    ToastManager.shared.showError("备份失败: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)

                    Divider()

                    Button("删除", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .sheet(isPresented: $showingLogs) {
            MiniLogView(
                lines: logLines,
                title: "\(container.displayName) 日志",
                isLoading: isLogLoading,
                showBoot: $logShowBoot,
                tail: $logTail,
                tailChoices: logTailChoices,
                onReload: loadLogs
            )
        }
        .sheet(item: $editConfig) { config in
            EditContainerView(container: container, config: config)
        }
        .sheet(isPresented: $showingStats) {
            StatsView(containerID: container.id)
        }
        .alert("确认删除", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                Task {
                    await manager.deleteContainer(id: container.id)
                    viewModel.refreshContainers()
                }
            }
        } message: {
            Text("确定要删除容器 \"\(container.displayName)\" 吗?此操作不可恢复。")
        }
        // ✅ 状态变化强制刷新详情
        .id(container.id + container.state.rawValue)
        .task(id: container.id) {
            isLoadingDetails = true
            defer { isLoadingDetails = false }
            do {
                let fetched = try await manager.fetchContainerDetails(id: container.id)
                await MainActor.run {
                    details = fetched
                }
            } catch {
                print("⚠️ 获取容器详情失败: \(error)")
            }
        }
    }

    // MARK: - 辅助视图
    private func loadLogs() {
        isLogLoading = true
        Task {
            do {
                let output = try await manager.fetchContainerLogsRaw(
                    id: container.id,
                    boot: logShowBoot,
                    tail: logTail > 0 ? logTail : nil
                )
                logLines = output.split(separator: "\n").map(String.init)
            } catch {
                logLines = ["获取日志失败: \(error.localizedDescription)"]
            }
            isLogLoading = false
        }
    }

    private var statusBadge: some View {
        Text(container.state.displayName)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(container.state.color.opacity(0.2))
            .foregroundColor(container.state.color)
            .cornerRadius(12)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            return dateFormatter.string(from: date)
        }
        return isoString
    }
}

// MARK: - 统计视图(完整实现)
struct StatsView: View {
    let containerID: String
    @Environment(\.dismiss) private var dismiss
    @State private var stats: ContainerStats?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var autoRefresh = false
    @State private var refreshInterval: Double = 3
    @State private var timer: Timer?

    private let manager = ContainerManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题栏
            HStack {
                Text("容器统计")
                    .font(.title)
                    .bold()
                Spacer()
              
            }
            .padding(.bottom, 4)

            Divider()

            if isLoading {
                ProgressView("加载统计信息...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.largeTitle)
                        Text(error)
                            .foregroundColor(.secondary)
                        Button("重试") {
                            loadStats()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minWidth:520,minHeight:520)
            } else if let stats = stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 环形比率
                        HStack(spacing: 20) {
                            Spacer()
                            RingStat(title: "CPU", percentStr: stats.cpuPercent, color: .blue)
                            Spacer()
                            RingStat(title: "内存", percentStr: String(format: "%.1f%%", stats.memPercent), color: .green)
                            Spacer()
                            
                            VStack(spacing: 4) {
                                Text("\(stats.pids)").font(.title2.weight(.semibold)).foregroundColor(.orange)
                                Text("进程").font(.caption2).foregroundColor(.secondary)
                            }
                            .frame(width: 70, height: 70)
                            .background(.orange.opacity(0.08), in: Circle())
                            Spacer()
                        }

                        let netParts = stats.netIO.components(separatedBy: " / ")
                        let diskParts = stats.blockIO.components(separatedBy: " / ")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            MiniStat(title: "内存使用", value: stats.memUsage, color: .green)
                            MiniStat(title: "内存限制", value: stats.memLimit, color: .green)
                            MiniStat(title: "网络接收", value: netParts.first ?? stats.netIO, color: .cyan)
                            MiniStat(title: "网络发送", value: netParts.count > 1 ? netParts[1] : "", color: .cyan)
                            MiniStat(title: "磁盘读", value: diskParts.first ?? stats.blockIO, color: .purple)
                            MiniStat(title: "磁盘写", value: diskParts.count > 1 ? diskParts[1] : "", color: .purple)
                        }

                        // 更新时间戳
                        Text("更新于 \(Date().formatted())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding()
                }
            }

            // 底部操作按钮
            HStack {
                Toggle("自动刷新", isOn: $autoRefresh)
                if autoRefresh {
                    Text("每").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $refreshInterval, in: 1...18, step: 1).frame(width: 80)
                    Text("\(Int(refreshInterval))s").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                }
                Spacer()
                if stats != nil {
                    Button("刷新") { loadStats() }
                        .buttonStyle(.bordered)
                }
                Button("关闭") { stopTimer(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { loadStats() }
        .onDisappear { stopTimer() }
        .onChange(of: autoRefresh) { _, on in on ? startTimer() : stopTimer() }
        .onChange(of: refreshInterval) { _, _ in if autoRefresh { stopTimer(); startTimer() } }
    }

    private func loadStats() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let fetched = try await manager.fetchContainerStats(id: containerID)
                await MainActor.run {
                    stats = fetched
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "加载统计失败: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            loadStats()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
    }
}

// 统计卡片
struct InfoCard: View {
    let title: String; let value: String; let icon: String; let color: Color
    var copyValue: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundColor(color)
                Text(value).font(.caption.weight(.medium)).foregroundColor(color).lineLimit(1)
                Spacer(minLength: 2)
                if let copyValue {
                    Button {
                        copy(copyValue)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("复制\(title)：\(copyValue)")
                }
            }
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let copyValue { copy(copyValue) }
        }
        .help(copyValue == nil ? "" : "双击复制\(title)")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastManager.shared.showSuccess("已复制\(title)：\(text)")
    }
}

// MARK: - 环形统计
struct IDStatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(value.count > 6 ? .headline : .title2)
                .fontWeight(.semibold)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - 环形统计
struct RingStat: View {
    let title: String; let percentStr: String; let color: Color
    private var pct: Double {
        Double(percentStr.replacingOccurrences(of: "%", with: "")) ?? 0
    }
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 6)
            Circle().trim(from: 0, to: min(pct / 100, 1))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: pct)
            VStack(spacing: 1) {
                Text(percentStr).font(.caption.weight(.semibold)).foregroundColor(color)
                Text(title).font(.caption2).foregroundColor(.secondary)
            }
        }.frame(width: 64, height: 64)
    }
}

// MARK: - 紧凑卡片
struct MiniStat: View {
    let title: String; let value: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.caption.weight(.medium)).foregroundColor(color).lineLimit(1)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 日志视图
struct MiniLogView: View {
    let lines: [String]
    let title: String
    let isLoading: Bool
    @Binding var showBoot: Bool
    @Binding var tail: Int
    let tailChoices: [Int]
    let onReload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copyButtonTitle = "复制"
    @State private var isCopyDisabled = false

    var body: some View {
        NavigationStack {
            VStack {
                // 日志筛选栏：启动日志 / 尾部行数
                HStack(spacing: 12) {
                    Toggle("启动日志 (--boot)", isOn: $showBoot)
                        .toggleStyle(.switch).controlSize(.small)
                    Picker("行数", selection: $tail) {
                        ForEach(tailChoices, id: \.self) { n in
                            Text(n == 0 ? "全部" : "\(n) 行").tag(n)
                        }
                    }
                    .frame(width: 110)
                    Button {
                        onReload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isLoading)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if isLoading {
                    ProgressView("加载日志...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    Text("暂无日志")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top) {
                                    Text("\(index+1)")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(copyButtonTitle) {
                        let logText = lines.joined(separator: "\n")
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(logText, forType: .string)
                        copyButtonTitle = "✅ 已复制"
                        isCopyDisabled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copyButtonTitle = "复制"
                            isCopyDisabled = false
                        }
                    }
                    .disabled(lines.isEmpty || isCopyDisabled)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
}

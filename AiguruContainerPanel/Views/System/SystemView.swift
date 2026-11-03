//
//  SystemView.swift
//  AiguruContainerPanel
//
//  系统状态管理视图:双列卡片布局。
//

import SwiftUI
internal import UniformTypeIdentifiers

struct SystemView: View {
    @EnvironmentObject private var containerManager: ContainerManager
    @EnvironmentObject private var machineManager: MachineManager
    @EnvironmentObject private var sourceImageManager: SourceImageManager
    @EnvironmentObject private var pluginManager: PluginManager
    @EnvironmentObject private var environmentManager: EnvironmentManager
    @StateObject private var viewModel = SystemViewModel()

    @State private var currentKernel: String? = nil
    @State private var isLoadingKernel = false
    @State private var isInstallingKernel = false
    @State private var isUninstallingKernel = false
    @State private var showUninstallKernelConfirmation = false
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var resetLog: [String] = []

    // CLI 安装/卸载
    @State private var cliSudoMode: CliSudoMode = .install
    @State private var pendingInstallSource: URL?
    @State private var showCliSudoPrompt = false
    @State private var showUninstallCliConfirm = false
    @State private var cliSudoPassword = ""
    @State private var cliSudoBusy = false
    @State private var cliSudoError: String?

    private var containerCount: Int { containerManager.containers.count }
    private var runningContainerCount: Int { containerManager.containers.filter { $0.state == .running }.count }
    private var machineCount: Int { machineManager.machines.count }
    private var imageCount: Int { sourceImageManager.images.count }
    private var pluginCount: Int { pluginManager.installedPluginNames.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("系统状态").font(.largeTitle)

                // Row 2: 环境信息 | CLI 管理 + 内核管理
                HStack(alignment: .top, spacing: 16) {
                    envInfoCard.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        cliManageCard
                        kernelCard
                    }
                    .frame(maxWidth: .infinity)
                }

                // Row 3: 资源目录 | 系统工具
                HStack(alignment: .top, spacing: 16) {
                    containerDirsCard.frame(maxWidth: .infinity)
                    systemToolsCard.frame(maxWidth: .infinity)
                }

                // Row 3.5: 磁盘占用
                HStack(alignment: .top, spacing: 16) {
                    diskUsageCard.frame(maxWidth: .infinity)
                }

                resetLogView
            }
            .padding()
        }
        .onAppear { viewModel.startMonitoring(); viewModel.loadConfig(); viewModel.checkCLIInstalled(); Task { await loadKernelStatus() } }
        .onDisappear { viewModel.stopMonitoring() }
        .onChange(of: environmentManager.currentEnvironment) { _, _ in
            viewModel.refreshAll()
            Task { await loadKernelStatus() }
        }
        .confirmationDialog(
            "清理当前工作环境的未使用资源",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理悬空镜像") { viewModel.performCleanup(.danglingImages) }
                .disabled(!viewModel.supportsCleanup(.danglingImages))
            Button("清理已停止容器", role: .destructive) { viewModel.performCleanup(.stoppedContainers) }
                .disabled(!viewModel.supportsCleanup(.stoppedContainers))
            Button("清理未使用网络", role: .destructive) { viewModel.performCleanup(.unusedNetworks) }
                .disabled(!viewModel.supportsCleanup(.unusedNetworks))
            Button("取消", role: .cancel) {}
        } message: {
            Text("镜像仅清理无标签的悬空内容，不使用 image prune --all；不直接删除 \(viewModel.cacheDir)。清理结果不可恢复。")
        }
        .alert("卸载当前环境内核", isPresented: $showUninstallKernelConfirmation) {
            Button("取消", role: .cancel) {}
            Button("停止服务并卸载", role: .destructive) { uninstallKernels() }
        } message: {
            Text("将停止 Apple Container 服务，并把当前环境 kernels 目录中的全部内核移到废纸篓。容器、镜像、卷和配置不会被删除；再次运行容器前需要重新安装内核。")
        }
        .alert("重置当前工作环境", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("停止并重新启动") { resetEnvironment() }
        } message: {
            Text("将短暂停止 \(viewModel.currentEnvironmentName) 中的所有容器服务，并使用当前数据、安装和日志目录重新启动。不会删除容器、镜像、卷或配置。")
        }
        .sheet(isPresented: $showCliSudoPrompt) {
            SudoPasswordSheet(
                title: cliSudoMode == .install ? "安装 CLI" : "卸载 CLI",
                message: cliSudoMode == .install
                    ? "将通过系统命令通道以管理员权限执行官方安装命令：installer -pkg \(pendingInstallSource?.path ?? "") -target /（当前环境：\(viewModel.currentEnvironmentName)）"
                    : "将通过系统命令通道以管理员权限执行：rm -f \(viewModel.currentEnvironmentCliPath)（当前环境：\(viewModel.currentEnvironmentName)，容器数据目录不受影响）",
                password: $cliSudoPassword,
                busy: cliSudoBusy,
                error: cliSudoError
            ) {
                guard !cliSudoBusy else { return }
                cliSudoBusy = true
                cliSudoError = nil
                Task {
                    let err: String?
                    if cliSudoMode == .install, let src = pendingInstallSource {
                        err = await viewModel.installCLI(from: src, password: cliSudoPassword)
                    } else if cliSudoMode == .uninstall {
                        err = await viewModel.uninstallCLI(password: cliSudoPassword)
                    } else {
                        err = "缺少安装来源"
                    }
                    await MainActor.run {
                        cliSudoBusy = false
                        if let err {
                            cliSudoError = err
                        } else {
                            cliSudoPassword = ""
                            showCliSudoPrompt = false
                            pendingInstallSource = nil
                        }
                    }
                }
            }
        }
        .alert("卸载 CLI", isPresented: $showUninstallCliConfirm) {
            Button("取消", role: .cancel) { }
            Button("卸载", role: .destructive) {
                cliSudoMode = .uninstall
                cliSudoPassword = ""
                cliSudoError = nil
                showCliSudoPrompt = true
            }
        } message: {
            Text("将删除当前环境（\(viewModel.currentEnvironmentName)）的 CLI：\(viewModel.currentEnvironmentCliPath)。卸载后本应用在该环境下无法调用 CLI，其他环境不受影响。容器数据目录（\(viewModel.dataRoot)）不会被删除。此操作需要管理员权限。")
        }
    }

    // MARK: - Cards

    private var envInfoCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CLI 版本:").font(.caption2).foregroundStyle(.secondary)
                    Text(viewModel.version).font(.caption2.monospaced())
                    Spacer()
                    Circle().fill(viewModel.isServiceRunning ? .green : .red).frame(width: 5, height: 5)
                    Text(viewModel.isServiceRunning ? "运行中" : "未运行").font(.caption2)
                }
                HStack(spacing: 4) {
                    Text("指令库:").font(.caption2).foregroundStyle(.secondary)
                    Text("v\(CLICommandCatalog.shared.schemaVersion) · \(environmentManager.currentInstructionProfile?.label ?? "等待匹配 CLI 版本")")
                        .font(.caption2.monospaced())
                    Spacer()
                    if let url = CLICommandCatalog.shared.documentationURL {
                        Link("官方文档", destination: url).font(.caption2)
                    }
                }
                if environmentManager.currentVersion.isKnown {
                    let patched = CLICommandCatalog.shared.supportsCapability(
                        "containerization.securityBaseline1_5_0",
                        version: environmentManager.currentVersion
                    )
                    HStack(spacing: 4) {
                        Image(systemName: patched ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        Text(patched
                             ? (environmentManager.currentVersion >= CLIVersion("1.6.0") ? "Container 1.6 安全基线（继承 1.5 kubeconfig 净化）" : "Container 1.5 安全基线（含 kubeconfig 净化）")
                             : "建议升级到 Container 1.5.0")
                    }
                    .font(.caption2)
                    .foregroundStyle(patched ? .green : .orange)
                }
                Divider()
                HStack(spacing: 8) {
                    cap("CPU", "\(viewModel.hostResources.logicalCPUs) 核", "cpu")
                    cap("内存", viewModel.hostResources.memoryDescription, "memorychip")
                    cap("架构", viewModel.hostResources.architecture, "desktopcomputer")
                    cap("系统",viewModel.hostResources.operatingSystem,"apple.logo")
                }
                if !viewModel.versionComponents.isEmpty {
                    Divider()
                    ForEach(viewModel.versionComponents) { comp in
                        HStack(spacing: 8) {
                            Text(comp.appName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(comp.version).font(.caption.monospaced()).lineLimit(1)
                        }
                        if comp.appName.localizedCaseInsensitiveContains("apiserver") {
                            Text("apiserver 版本按同主版本 XPC API 兼容策略运行，不代表 CLI 未升级")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.vertical, 2)
        } label: {
            Text("环境信息").font(.caption2)
        }
    }

    private var diskUsageCard: some View {
        GroupBox("磁盘占用 (system df)") {
            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.diskUsageItems.isEmpty {
                    ForEach(viewModel.diskUsageItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: iconForType(item.type)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.type).font(.caption.weight(.medium))
                                Text("\(item.active)/\(item.total) 个 · 大小 \(item.sizeDescription) · 可回收 \(item.reclaimableDescription)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                } else if !viewModel.diskUsageRaw.isEmpty {
                    ScrollView {
                        Text(viewModel.diskUsageRaw).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else {
                    HStack { ProgressView().scaleEffect(0.6); Text("加载中...").font(.caption) }
                }
            }.padding(.vertical, 4)
        }
    }

    private func iconForType(_ type: String) -> String {
        let lower = type.lowercased()
        if lower.contains("image") { return "photo" }
        if lower.contains("container") { return "shippingbox" }
        if lower.contains("volume") { return "externaldrive" }
        return "internaldrive"
    }

    private var kernelCard: some View {
            GroupBox("内核管理") {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingKernel {
                        HStack { ProgressView().scaleEffect(0.6); Text("检测中...").font(.caption) }
                    } else if let k = currentKernel {
                        HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(k).font(.subheadline) }
                    } else {
                        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("未配置").foregroundStyle(.orange) }
                    }
                    HStack {
                        Button("安装推荐") { installRecommendedKernel() }.buttonStyle(.borderedProminent).controlSize(.small).disabled(isInstallingKernel || isUninstallingKernel)
                        Button("安装自定义内核") { selectKernelFile() }.buttonStyle(.bordered).controlSize(.small).disabled(isInstallingKernel || isUninstallingKernel)
                        Button("卸载", role: .destructive) { requestKernelUninstall() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(currentKernel == nil || isInstallingKernel || isUninstallingKernel)
                    }
                    if isInstallingKernel { ProgressView("安装中...").scaleEffect(0.6) }
                    if isUninstallingKernel { ProgressView("卸载中...").scaleEffect(0.6) }
                    Text("推荐内核约 500 MB；卸载会先停止服务，文件移入废纸篓。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider()

                }.padding(.vertical, 4)
            }

    }

    private var containerDirsCard: some View {
        GroupBox("资源目录 · 当前环境：\(viewModel.currentEnvironmentName)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("数据根目录以当前 CLI 的 system status 为准；未启动服务时回退到该环境 HOME 下的官方默认目录。刷新仅探查，不创建目录。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(viewModel.directories) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.kind.icon).foregroundStyle(d.exists ? Color.accentColor : .secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.kind.title).font(.caption.weight(.medium))
                            Text(d.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(d.sizeDescription).font(.caption2).foregroundStyle(.secondary)
                        Button("打开") { viewModel.openDirectory(d) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(!d.exists)
                    }
                    if d.id != viewModel.directories.last?.id { Divider() }
                }
               
                if !viewModel.startTime.isEmpty { dirRow("启动时间", viewModel.startTime) }
            }.padding(.vertical, 4)
        }
    }

    private var cliManageCard: some View {
        GroupBox("CLI 管理 · 当前环境：\(viewModel.currentEnvironmentName)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.cliInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(viewModel.cliInstalled ? .green : .orange)
                    Text(viewModel.cliInstalled ? "已安装: \(viewModel.currentEnvironmentCliPath)" : "未安装（\(viewModel.currentEnvironmentCliPath)）")
                        .font(.caption)
                    if viewModel.cliInstalled && viewModel.version != "未知" {
                        Text("(\(viewModel.version))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("安装 CLI") { selectCLISource() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("选择 Apple Container GitHub Releases 提供的官方签名安装包，通过系统命令通道执行 installer -pkg ... -target /")
                    Button("卸载 CLI") { showUninstallCliConfirm = true }
                        .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
                        .disabled(!viewModel.cliInstalled)
                        .help("删除 \(viewModel.currentEnvironmentCliPath)（数据目录不受影响）")
                    Spacer()
                }
                Text("安装原则：官方签名 pkg 始终先安装到默认系统路径 \(AppConstants.CLI.executablePath)；若当前工作环境配置了其他路径，再将同版本 CLI 同步到该环境。运行、检测、重置和卸载均只使用当前工作环境的绝对路径，不从 PATH 猜测。卸载不删除 \(viewModel.dataRoot) 等数据目录或其他环境。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// 选择官方签名 CLI 安装包，确认后进入管理员密码弹窗
    private func selectCLISource() {
        let panel = NSOpenPanel()
        panel.title = "选择官方 CLI 安装包 (.pkg)"
        if let pkgType = UTType(filenameExtension: "pkg") {
            panel.allowedContentTypes = [pkgType]
        } else {
            panel.allowedContentTypes = [.package]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pendingInstallSource = url
            cliSudoMode = .install
            cliSudoPassword = ""
            cliSudoError = nil
            showCliSudoPrompt = true
        }
    }

    private var systemToolsCard: some View {
        GroupBox("系统工具") {
            VStack(alignment: .leading, spacing: 8) {
                // 操作按钮
                HStack(spacing: 8) {
                    Button("启动服务") { viewModel.startService() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(viewModel.isServiceRunning)
                    Button("刷新") { viewModel.refreshAll(); Task { await loadKernelStatus() } }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("清理资源") { showClearConfirmation = true }
                        .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
                    Button(action: { showResetConfirmation = true }) {
                        if isResetting {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        } else {
                            Text("重置环境")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isResetting)
                    .help("停止服务 → 启动服务 → 检查内核 → 刷新状态")
                }

                Divider()

                // 配置编辑（config.toml）
                HStack(spacing: 8) {
                    Text("config.toml").font(.caption.weight(.medium))
                    Spacer()
                    Button("读取") { viewModel.loadConfig() }.buttonStyle(.bordered).controlSize(.mini)
                    Button("保存") { viewModel.saveConfig() }.buttonStyle(.borderedProminent).controlSize(.mini)
                }
                TextEditor(text: $viewModel.configContent)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                Text("保存到容器实际读取的配置（同步 ~/.config/container/config.toml），重启服务后生效。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var resetLogView: some View {
        Group {
            if !resetLog.isEmpty {
                GroupBox("重置日志") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(resetLog.indices, id: \.self) { i in
                                Text(resetLog[i])
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(resetLog[i].hasPrefix("❌") ? .red : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    // MARK: - Helpers

    private func dirRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text("\(label):").font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack {
            Text("\(label):").font(.caption).foregroundStyle(.secondary)
            Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            Spacer()
            Button("打开") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                .buttonStyle(.bordered).controlSize(.mini)
        }
    }

    private func cap(_ title: String, _ value: String, _ icon: String) -> some View {
        Label { VStack(alignment: .leading, spacing: 1) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption2.weight(.medium)) }
        }
        icon: { Image(systemName: icon).foregroundColor(.accentColor).scaleEffect(0.8) }
    }

    // MARK: - Kernel methods
    private func loadKernelStatus() async {
        isLoadingKernel = true
        currentKernel = await machineManager.fetchCurrentKernel(appRoot: viewModel.dataRoot)
        isLoadingKernel = false
    }
    private func installRecommendedKernel() {
        let a = NSAlert(); a.messageText = "安装推荐内核"; a.informativeText = "约 500 MB,继续?"
        a.addButton(withTitle: "安装"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            Task { isInstallingKernel = true
                do { try await machineManager.installRecommendedKernel(); await loadKernelStatus() }
                catch { ToastManager.shared.showError("安装失败: \(error.localizedDescription)") }
                isInstallingKernel = false }
        }
    }
    private func selectKernelFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [
            UTType(filenameExtension: "tar")!, UTType(filenameExtension: "zst")!, .zip,
            UTType(filenameExtension: "bin")!, UTType(filenameExtension: "vmlinux")!
        ]; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.begin { r in if r == .OK, let u = p.url {
            Task { isInstallingKernel = true
                do { try await machineManager.installCustomKernel(fileURL: u, binaryName: nil); await loadKernelStatus() }
                catch { ToastManager.shared.showError("安装失败: \(error.localizedDescription)") }
                isInstallingKernel = false }
        }}
    }

    private func requestKernelUninstall() {
        Task {
            isLoadingKernel = true
            await containerManager.fetchContainers()
            await machineManager.fetchMachines()
            isLoadingKernel = false

            let runningContainers = containerManager.containers.filter { $0.state == .running }.count
            let runningMachines = machineManager.machines.filter { $0.state == .running }.count
            guard runningContainers == 0, runningMachines == 0 else {
                ToastManager.shared.showError("请先停止运行中的容器（\(runningContainers)）和 Machine（\(runningMachines)）")
                return
            }
            showUninstallKernelConfirmation = true
        }
    }

    private func uninstallKernels() {
        Task {
            isUninstallingKernel = true
            defer { isUninstallingKernel = false }
            do {
                let count = try await machineManager.uninstallKernels(appRoot: viewModel.dataRoot)
                await loadKernelStatus()
                viewModel.refreshServiceStatus()
                if count == 0 {
                    ToastManager.shared.showInfo("当前环境没有可卸载的内核")
                } else {
                    ToastManager.shared.showSuccess("已卸载 \(count) 项内核资源，可从废纸篓恢复")
                }
            } catch {
                ToastManager.shared.showError("卸载失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 重置环境
    private func resetEnvironment() {
        isResetting = true
        resetLog = []
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss"

        func log(_ msg: String, error: Bool = false) {
            let prefix = error ? "❌" : "✅"
            let line = "\(prefix) [\(ts.string(from: Date()))] \(msg)"
            resetLog.append(line)
        }

        Task {
            let succeeded = await viewModel.resetEnvironment { message, isError in
                log(message, error: isError)
            }
            if succeeded { log("重置流程完成") }
            await loadKernelStatus()
            isResetting = false
        }
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let label: String; let value: String; let sub: String?; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(color)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - CLI 安装/卸载模式
enum CliSudoMode {
    case install
    case uninstall
}

//
//  MainView.swift
//  AiguruContainerPanel
//
//  主窗口布局：侧边栏通底，内容区底部集成折叠日志面板。
//  注入 ContainerListViewModel 供侧边栏使用，进度条始终存在。
//

import SwiftUI
internal import UniformTypeIdentifiers

struct MainView: View {
    @State private var selectedTab: Tab = .containers
    /// 浮动日志默认关闭；用户通过工具栏手动打开后记住选择。
    @AppStorage("main.showFloatingLogPanel") private var showLogPanel = false
    @StateObject private var systemViewModel = SystemViewModel()
    @StateObject private var taskManager = TaskManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var systemMonitor = SystemMonitor.shared
    
    @StateObject private var containerManager = ContainerManager.shared
       @StateObject private var machineManager = MachineManager.shared
       @StateObject private var sourceImageManager = SourceImageManager.shared
    
    @StateObject private var environmentManager = EnvironmentManager.shared
    @StateObject private var containerListVM = ContainerListViewModel()
    @EnvironmentObject private var appSettings: AppSettings

    @State private var showAddEnvironmentSheet = false
    @State private var newEnvName = ""
    @State private var newEnvPath = ""
    @State private var pendingEnvironmentDeletion: ContainerEnvironment?
    @State private var isRestoringContainerBackup = false

    private var selectedEnvironmentID: Binding<UUID> {
        Binding(
            get: {
                environmentManager.currentEnvironment?.id
                    ?? environmentManager.availableEnvironments.first(where: { $0.type == .system })?.id
                    ?? ContainerEnvironment.systemEnvironment.id
            },
            set: { id in
                guard let environment = environmentManager.availableEnvironments.first(where: { $0.id == id }) else {
                    return
                }
                environmentManager.selectEnvironment(environment)
            }
        )
    }

    enum Tab: Hashable {
        case containers
        case images
        case networks
        case volumes
        case machines
        case k8s
        case templates
        case plugins
        case system
        case logs
        case help
        case plugin(id: String, name: String)

        var title: String {
            switch self {
            case .containers: return "容器"
            case .images: return "镜像"
            case .networks: return "网络"
            case .volumes: return "卷"
            case .machines: return "Machine"
            case .k8s: return "Kubernetes"
            case .templates: return "应用集群"
            case .plugins: return "插件"
            case .system: return "系统"
            case .logs: return "日志"
            case .help: return "帮助"
            case .plugin(_, let name): return name
            }
        }

        var icon: String {
            switch self {
            case .containers: return "cube.box"
            case .images: return "photo"
            case .networks: return "network"
            case .volumes: return "externaldrive"
            case .machines: return "macpro.gen1"
            case .k8s: return "gyroscope"
            case .templates: return "square.stack.3d.up"
            case .plugins: return "puzzlepiece"
            case .system: return "gear"
            case .logs: return "doc.text"
            case .help: return "questionmark.circle"
            case .plugin: return "puzzlepiece.extension"
            }
        }

        var isPlugin: Bool {
            if case .plugin = self { return true }
            return false
        }

        var pluginID: String? {
            if case .plugin(let id, _) = self { return id }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // 侧边栏（通底）
                SidebarView(selectedTab: $selectedTab)
                    .frame(minWidth: 180, idealWidth: 205, maxWidth: 225)
                    .layoutPriority(0)

                // 内容区：日志和任务面板覆盖在内容之上，不参与主布局高度计算。
                ZStack(alignment: .bottom) {
                    ZStack {
                        // 内置视图（非插件 tab 时显示）
                        Group {
                            if !selectedTab.isPlugin {
                                contentView(for: selectedTab)
                            }
                        }
                        // 插件层：常驻窗口，永不销毁 → 插件内部状态不丢失
                        PluginHostLayer(pluginManager: pluginManager, selectedID: selectedTab.pluginID)
                            .opacity(selectedTab.isPlugin ? 1 : 0)
                            .allowsHitTesting(selectedTab.isPlugin)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 6) {
                        if taskManager.showTaskPanel {
                            CommandProgressView()
                                .environmentObject(taskManager)
                                .environmentObject(containerListVM)
                                .frame(maxHeight: 92)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 1)
                        }

                        if showLogPanel {
                            LogPanelView()
                                .frame(height: 170)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 2)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.18), value: showLogPanel)
                }
                .frame(minWidth: 400)
                .layoutPriority(1)
            }
            .frame(minHeight: 160)
        }
        .controlSize(.small)
        .toolbar {
            // 添加环境
            ToolbarItem(placement: .automatic) {
                Button(action: { showAddEnvironmentSheet = true }) {
                    Label("添加环境", systemImage: "plus.circle")
                }
                .help("添加自定义 container 环境")
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    let customEnvironments = environmentManager.availableEnvironments.filter { $0.type == .custom }
                    if customEnvironments.isEmpty {
                        Text("没有可删除的自定义环境")
                    } else {
                        ForEach(customEnvironments) { env in
                            Button("删除 \(env.name)", role: .destructive) {
                                pendingEnvironmentDeletion = env
                            }
                        }
                    }
                } label: {
                    Label("删除环境", systemImage: "trash")
                }
                .help("删除自定义工作环境配置；不会删除 CLI 文件")
            }

            // 环境选择
            ToolbarItem(placement: .automatic) {
                Picker("环境", selection: selectedEnvironmentID) {
                    ForEach(environmentManager.availableEnvironments) { env in
                        HStack {
                            Image(systemName: env.type.icon)
                            Text(env.name)
                            if env.isActive {
                                Text("✓").foregroundColor(.green)
                            }
                        }
                        .tag(env.id)
                    }
                }
                .frame(width: 180)
                .help("切换容器环境")
                .disabled(environmentManager.isDetecting)
            }

            // 检测环境
            ToolbarItem(placement: .automatic) {
                Button(action: { environmentManager.detectEnvironments() }) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .help("重新检测所有环境")
                .disabled(environmentManager.isDetecting)
            }

            ToolbarItem(placement: .automatic) {
                Button(action: chooseContainerBackupToRestore) {
                    Label("恢复容器", systemImage: "arrow.counterclockwise.circle")
                }
                .help("选择导出时生成的 .backup.json，恢复文件系统和可移植配置")
                .disabled(isRestoringContainerBackup)
            }

            // 日志面板切换
            ToolbarItem(placement: .automatic) {
                Button(action: { showLogPanel.toggle() }) {
                    Label("日志面板", systemImage: "dock.rectangle")
                }
            }

            // 执行模式选择
            ToolbarItem(placement: .automatic) {
                Picker("执行模式", selection: $appSettings.executionMode) {
                    ForEach(ExecutionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(width: 150)
                .help("选择 CLI 执行模式")
            }
        }
        .sheet(isPresented: $showAddEnvironmentSheet) {
            VStack(spacing: 16) {
                Text("添加自定义 Container 环境")
                    .font(.title)
                    .padding(.top)
                TextField("环境名称（如：Homebrew）", text: $newEnvName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                HStack {
                    TextField("container 可执行文件路径", text: $newEnvPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.title = "选择 container 可执行文件"
                        panel.showsHiddenFiles = true
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowedContentTypes = [.executable]
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                newEnvPath = url.path
                            }
                        }
                    }) {
                        Image(systemName: "folder")
                    }
                    .help("浏览选择文件")
                }
                HStack {
                    Button("取消") {
                        showAddEnvironmentSheet = false
                        newEnvName = ""
                        newEnvPath = ""
                    }
                    Spacer()
                    Button("添加") {
                        if !newEnvName.isEmpty && !newEnvPath.isEmpty {
                            environmentManager.addCustomEnvironment(name: newEnvName, executablePath: newEnvPath)
                            showAddEnvironmentSheet = false
                            newEnvName = ""
                            newEnvPath = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newEnvName.isEmpty || newEnvPath.isEmpty)
                }
                .padding(.top)
            }
            .padding()
            .frame(width: 450, height: 250)
        }
        .alert("删除工作环境", isPresented: Binding(
            get: { pendingEnvironmentDeletion != nil },
            set: { if !$0 { pendingEnvironmentDeletion = nil } }
        ), presenting: pendingEnvironmentDeletion) { env in
            Button("取消", role: .cancel) { pendingEnvironmentDeletion = nil }
            Button("删除", role: .destructive) {
                environmentManager.removeCustomEnvironment(env)
                pendingEnvironmentDeletion = nil
            }
        } message: { env in
            Text("仅删除“\(env.name)”的工作环境配置，不会删除 \(env.resolvedCliPath) 或容器数据。")
        }
        .environmentObject(taskManager)
        .environmentObject(pluginManager)
        .environmentObject(systemMonitor)
        .environmentObject(environmentManager)
        .environmentObject(containerListVM)
        .environmentObject(systemViewModel)
        .environmentObject(containerManager)
             .environmentObject(machineManager)
             .environmentObject(sourceImageManager)
        .toast()
        .onAppear {
            systemMonitor.refreshSystemInfo()
            environmentManager.detectEnvironments()
            containerListVM.refreshContainers()
        }
        .onChange(of: pluginManager.hostedPlugins.map(\.id)) {
            // 插件卸载后清理缓存控制器
            pluginManager.pruneCachedControllers(activeIDs: Set(pluginManager.hostedPlugins.map(\.id)))
        }
    }

    private func chooseContainerBackupToRestore() {
        let panel = NSOpenPanel()
        panel.title = "选择容器备份说明文件"
        panel.message = "请选择备份时与 filesystem.tar、inspect.json 一起生成的 .backup.json 文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.lastPathComponent.hasSuffix(".backup.json") else {
                ToastManager.shared.showError("请选择 .backup.json 容器备份说明文件")
                return
            }
            isRestoringContainerBackup = true
            Task {
                do {
                    let restoredName = try await ContainerBackupManager.shared.restoreBackup(manifestURL: url)
                    await MainActor.run {
                        isRestoringContainerBackup = false
                        ToastManager.shared.showSuccess("容器「\(restoredName)」恢复成功；挂载卷需单独恢复")
                    }
                } catch {
                    await MainActor.run {
                        isRestoringContainerBackup = false
                        ToastManager.shared.showError("恢复失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    

    @ViewBuilder
    private func contentView(for tab: Tab) -> some View {
        switch tab {
        case .containers:
            ContainerListView()
                .environmentObject(containerListVM)
        case .images:
            SourceImageView()
        case .networks:
            NetworkView()
        case .volumes:
            VolumeListView()
        case .machines:
            MachineListView()
        case .k8s:
            KubernetesView()
        case .templates:
            ApplicationClusterView()
        case .plugins:
            PluginListView()
        case .system:
            SystemView()
        case .logs:
            LogView()
        case .help:
            HelpView()
        case .plugin(_, _):
            // 插件视图由常驻 PluginHostLayer 渲染（见 body ZStack）
            EmptyView()
        }
    }
}

// MARK: - 常驻插件层（NSViewController 容器）

/// 常驻窗口层级，所有插件控制器保持挂载（isHidden 切换），
/// 视图永不离开窗口 → NSHostingController 的 SwiftUI 状态永不重置。
struct PluginHostLayer: NSViewControllerRepresentable {
    let pluginManager: PluginManager
    let selectedID: String?

    func makeNSViewController(context: Context) -> NSViewController {
        let container = NSViewController()
        container.view = NSView()
        container.view.wantsLayer = true
        return container
    }

    func updateNSViewController(_ container: NSViewController, context: Context) {
        let available = container.view.bounds

        // 所有插件控制器保持为容器子视图，仅切换可见性（插件状态常驻保留）
        for hosted in pluginManager.hostedPlugins {
            let child = pluginManager.cachedController(for: hosted)

            if child.parent !== container {
                container.addChild(child)
                child.view.frame = available
                child.view.autoresizingMask = [.width, .height]
                child.view.isHidden = true
                container.view.addSubview(child.view)
            } else {
                child.view.frame = available
            }
            child.view.isHidden = (hosted.id != selectedID)
        }

        // 移除已卸载插件的控制器（延迟到下一个 runloop，避免在布局过程中改视图层级导致崩溃）
        let activeControllers = pluginManager.hostedPlugins.map { pluginManager.cachedController(for: $0) }
        let stale = container.children
            .filter { ctrl in !activeControllers.contains(where: { $0 === ctrl }) }
        if !stale.isEmpty {
            DispatchQueue.main.async { [weak container] in
                guard let container else { return }
                for ctrl in stale {
                    if ctrl.parent === container {
                        ctrl.view.removeFromSuperview()
                        ctrl.removeFromParent()
                    }
                }
            }
        }
    }
}

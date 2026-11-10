//
//  AiguruContainerPanelApp.swift
//  AiguruContainerPanel
//
//  应用程序主入口，注入所有全局服务。
//

import SwiftUI

@main
struct AiguruContainerPanelApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var taskManager = TaskManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var systemMonitor = SystemMonitor.shared
    @StateObject private var environmentManager = EnvironmentManager.shared
    @StateObject private var appSettings = AppSettings()   // 新增

    init() {
        _ = ImageSourceManager.shared
        // 应用插件市场已下线；保留注册表对象仅用于兼容旧数据与 Kubernetes 插件能力。
        print("✅ 应用初始化完成")
        AgentAPIServer.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(taskManager)
                .environmentObject(pluginManager)
                .environmentObject(systemMonitor)
                .environmentObject(AcpPluginRegistry.shared)
                .environmentObject(environmentManager)
                .environmentObject(appSettings)          // 注入
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
    }
}

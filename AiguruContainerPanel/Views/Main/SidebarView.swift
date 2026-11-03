//
//  SidebarView.swift
//  AiguruContainerPanel
//
//  侧边导航栏,顶部显示统计卡片,下方显示服务状态与控制。
//  所有数据基于当前选择的环境,切换环境时自动刷新。
//  优先刷新服务状态,其他数据异步加载。
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: MainView.Tab

    @EnvironmentObject private var containerManager: ContainerManager
    @EnvironmentObject private var machineManager: MachineManager
    @EnvironmentObject private var sourceImageManager: SourceImageManager
    @EnvironmentObject private var pluginManager: PluginManager
    @EnvironmentObject private var environmentManager: EnvironmentManager
    @EnvironmentObject private var registry: AcpPluginRegistry
    @StateObject private var systemViewModel = SystemViewModel()

    private var containerCount: Int { containerManager.containers.count }
    private var runningContainerCount: Int { containerManager.containers.filter { $0.state == .running }.count }
    private var machineCount: Int { machineManager.machines.count }
    private var runningMachineCount: Int { machineManager.machines.filter { $0.isRunning }.count }
    private var imageCount: Int { sourceImageManager.images.count }
    private var pluginCount: Int { pluginManager.installedPluginNames.count }

    private var containerDisplay: String { "\(runningContainerCount)/\(containerCount)" }
    private var machineDisplay: String { "\(runningMachineCount)/\(machineCount)" }
    private var imageDisplay: String { "\(imageCount)" }
    private var pluginDisplay: String { "\(pluginCount)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 统计卡片
            HStack(spacing: 6) {
                StatItem(label: "容器", value: containerDisplay, subValue: nil, color: .blue, isLoading: containerManager.isLoading)
                StatItem(label: "虚拟机", value: machineDisplay, subValue: nil, color: .purple, isLoading: machineManager.isLoading)
                StatItem(label: "镜像", value: imageDisplay, subValue: nil, color: .green, isLoading: sourceImageManager.isLoading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // 服务状态与控制
            HStack {
                Image(systemName: systemViewModel.isServiceRunning ? "power.circle.fill" : "power.circle")
                    .foregroundColor(systemViewModel.isServiceRunning ? .green : .gray)
                Text(systemViewModel.isServiceRunning ? "服务运行中" : "服务已停止")
                    .font(.caption)
                    .foregroundColor(systemViewModel.isServiceRunning ? .green : .secondary)
                Spacer()
                Button(action: {
                    systemViewModel.isServiceRunning ? systemViewModel.stopService() : systemViewModel.startService()
                }) {
                    Image(systemName: systemViewModel.isServiceRunning ? "stop.circle" : "play.circle")
                        .font(.title3)
                        .foregroundColor(systemViewModel.isServiceRunning ? .red : .green)
                }
                .buttonStyle(.borderless)
                .disabled(systemViewModel.isLoading)
                .help(systemViewModel.isServiceRunning ? "停止容器服务" : "启动容器服务")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(6)
            .padding(.horizontal, 8)

            // 当前环境
            if let env = environmentManager.currentEnvironment {
                HStack {
                    Image(systemName: env.type.icon)
                        .foregroundColor(.accentColor)
                    Text(env.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
//                    if env.isActive {
//                        Image(systemName: "checkmark.circle.fill")
//                            .foregroundColor(.green)
//                            .font(.caption)
//                    } else {
//                        Image(systemName: "exclamationmark.triangle.fill")
//                            .foregroundColor(.orange)
//                            .font(.caption)
//                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(6)
                .padding(.horizontal, 8)
            }

            // 导航列表
            List(selection: $selectedTab) {
                Label("容器", systemImage: "cube.box").tag(MainView.Tab.containers)
                Label("镜像", systemImage: "photo").tag(MainView.Tab.images)
                Label("网络", systemImage: "network").tag(MainView.Tab.networks)
                Label("卷", systemImage: "externaldrive").tag(MainView.Tab.volumes)
                Label("Machine", systemImage: "macpro.gen1").tag(MainView.Tab.machines)
                Label("Kubernetes", systemImage: "gyroscope").tag(MainView.Tab.k8s)
                Label("应用集群", systemImage: "square.stack.3d.up").tag(MainView.Tab.templates)
                Label("系统", systemImage: "gear").tag(MainView.Tab.system)
                Label("日志", systemImage: "doc.text").tag(MainView.Tab.logs)
                Label("帮助", systemImage: "questionmark.circle").tag(MainView.Tab.help)
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 180)
        }
        .onAppear {
            systemViewModel.refreshServiceStatus()
            systemViewModel.startMonitoring()
            Task {
                await containerManager.fetchContainers()
                await machineManager.fetchMachines()
                await sourceImageManager.fetchImages()
            }
        }
        .onDisappear {
            systemViewModel.stopMonitoring()
        }
        .onChange(of: environmentManager.currentEnvironment) { _, _ in
            systemViewModel.refreshServiceStatus()
            systemViewModel.refreshAll()
            Task {
                await containerManager.fetchContainers()
                await machineManager.fetchMachines()
                await sourceImageManager.fetchImages()
            }
        }
    }
}

// MARK: - 统计卡片
struct StatItem: View {
    let label: String
    let value: String
    let subValue: String?
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 1) {
            if isLoading {
//                ProgressView()
//                    .progressViewStyle(CircularProgressViewStyle())
//                    .scaleEffect(0.5)
            } else {
                Text(value)
                    .font(.headline)
                    .foregroundColor(color)
                if let sub = subValue {
                    Text(sub)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

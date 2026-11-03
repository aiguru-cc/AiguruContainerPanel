//
//  PluginListView.swift
//  AiguruContainerPanel
//
//  插件管理视图：列表 + 详情（对齐容器详情布局），工具栏嵌入市场切换/操作，错误折叠面板。
//

import SwiftUI

struct PluginListView: View {
    @StateObject private var viewModel = PluginViewModel()
    @StateObject private var pluginManager = PluginManager.shared
    @State private var showMarketManager = false
    @State private var installMessage = ""
    @State private var showInstallAlert = false
    @State private var showClearCacheAlert = false
    @State private var search = ""
    @State private var selName: String? = nil

    var filtered: [PanelPlugin] {
        var r = viewModel.plugins
        if !search.isEmpty {
            r = r.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
        }
        return r
    }
    var sel: PanelPlugin? { filtered.first { $0.name == selName } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Load errors banner (skipped plugins during fetch)
                if !viewModel.loadErrors.isEmpty {
                    errorsBanner
                }

                if viewModel.isLoading && viewModel.plugins.isEmpty {
                    Spacer()
                    ProgressView("正在从 \(pluginManager.selectedSource?.name ?? "市场") 拉取插件…")
                    Spacer()
                } else if let err = viewModel.errorMessage, viewModel.plugins.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Label(err, systemImage: "wifi.slash").foregroundStyle(.red)
                        Button("重试") { viewModel.refreshPlugins() }
                    }
                    Spacer()
                } else if viewModel.plugins.isEmpty && viewModel.loadErrors.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                        Text("暂无插件").font(.title2).foregroundStyle(.secondary)
                        Text("点击工具栏「添加市场」配置插件源").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("没有匹配的插件").font(.title2).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(selection: $selName) {
                        ForEach(filtered) { plugin in
                            PluginCard(plugin: plugin, onInstall: {
                                viewModel.installPlugin(plugin) { ok, msg in
                                    installMessage = msg; showInstallAlert = true
                                }
                            }, onUninstall: {
                                viewModel.uninstallPlugin(plugin) { ok, msg in
                                    installMessage = msg; showInstallAlert = true
                                }
                            })
                            .tag(plugin.name)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
            .layoutPriority(0)

            if let p = sel {
                PluginDetailView(plugin: p, viewModel: viewModel, onResult: { msg in
                    installMessage = msg; showInstallAlert = true
                })
                .frame(minWidth: 320)
                .layoutPriority(1)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("选择插件查看详情").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.2))
                .layoutPriority(1)
            }
        }
        .sheet(isPresented: $showMarketManager) {
            MarketSourceManagerView()
        }
        .alert("操作结果", isPresented: $showInstallAlert) {
            Button("确定") {}
        } message: {
            Text(installMessage)
        }
        .alert("清理缓存", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) {
                let result = pluginManager.clearPluginCache()
                installMessage = "已清理 \(result.removed) 个文件，释放 \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))"
                showInstallAlert = true
            }
        } message: {
            Text("将清除所有下载缓存和安装失败的插件残留。已成功安装的插件不受影响。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Picker("市场", selection: Binding<PluginSourceConfig?>(
                    get: { pluginManager.selectedSource },
                    set: { if let s = $0 { viewModel.switchSource(s) } }
                )) {
                    ForEach(pluginManager.sources) { src in
                        Text(src.name).tag(src as PluginSourceConfig?)
                    }
                }
                .frame(width: 150)

                Button(action: { viewModel.refreshPlugins() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新当前市场")

                Button(action: { showMarketManager = true }) {
                    Label("添加市场", systemImage: "plus")
                }
                .help("管理插件市场源")

                Button(action: { showClearCacheAlert = true }) {
                    Label("清理缓存", systemImage: "trash")
                }
                .help("清除下载缓存和安装失败的插件残留")

                TextField("搜索插件...", text: $search)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 160)
                    .help("按名称或描述搜索")

//                if viewModel.isLoading {
//                    ProgressView()
//                        .progressViewStyle(.circular)
//                        .scaleEffect(0.6)
//                }
            }
        }
        .onAppear {
            if viewModel.plugins.isEmpty, let src = pluginManager.selectedSource {
                viewModel.switchSource(src)
            }
        }
    }

    private var errorsBanner: some View {
        DisclosureGroup("\(viewModel.loadErrors.count) 个插件加载失败（已跳过）") {
            ForEach(viewModel.loadErrors, id: \.self) { err in
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - 插件详情（对齐容器详情布局）

struct PluginDetailView: View {
    let plugin: PanelPlugin
    @ObservedObject var viewModel: PluginViewModel
    let onResult: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题头
                HStack {
                    VStack(alignment: .leading) {
                        Text(plugin.name).font(.largeTitle).bold()
                        Text("作者: \(plugin.author)").font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                    statusBadge
                }
                Divider()

                // 基本信息卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    InfoCard(title: "版本", value: plugin.version, icon: "tag", color: .blue)
                    InfoCard(title: "作者", value: plugin.author, icon: "person", color: .indigo)
                    InfoCard(title: "来源", value: plugin.source.rawValue, icon: "globe", color: .teal)
                    InfoCard(title: "仓库", value: plugin.repositoryURL.absoluteString, icon: "link", color: .orange)
                    InfoCard(title: "状态", value: statusText, icon: "circle.fill", color: statusColor)
                    if let path = plugin.installPath {
                        InfoCard(title: "安装路径", value: path, icon: "folder", color: .green)
                    }
                }

                // 描述
                VStack(alignment: .leading, spacing: 4) {
                    Label("描述", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
                    Text(plugin.description)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }

                // 操作按钮
                HStack(spacing: 12) {
                    if plugin.isInstalled {
                        Button("卸载") {
                            viewModel.uninstallPlugin(plugin) { _, msg in onResult(msg) }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    } else {
                        Button("安装") {
                            viewModel.installPlugin(plugin) { _, msg in onResult(msg) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private var statusText: String {
        if plugin.isInstalled { return plugin.isEnabled ? "已启用" : "已安装" }
        return "未安装"
    }

    private var statusColor: Color {
        if plugin.isInstalled { return plugin.isEnabled ? .green : .blue }
        return .gray
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(12)
    }
}

// MARK: - Plugin Card
struct PluginCard: View {
    let plugin: PanelPlugin
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.headline)
                Text(plugin.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text("v\(plugin.version)").font(.caption2)
                    Text("·").foregroundStyle(.secondary)
                    Text(plugin.author).font(.caption2).foregroundStyle(.secondary)
                    Text(plugin.source.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer()
            if plugin.isInstalled {
                Button("卸载", action: onUninstall).buttonStyle(.bordered).tint(.red)
            } else {
                Button("安装", action: onInstall).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        let n = plugin.name
        if n.contains("网络") { return "network" }
        if n.contains("日志") { return "doc.text.magnifyingglass" }
        if n.contains("资源") || n.contains("看板") { return "chart.bar" }
        if n.contains("监控") { return "gauge.with.dots.needle.50percent" }
        if n.contains("安全") { return "lock.shield" }
        return "puzzlepiece.extension"
    }
}

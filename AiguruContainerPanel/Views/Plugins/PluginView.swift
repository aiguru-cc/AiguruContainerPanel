//
//  PluginView.swift
//  AiguruContainerPanel
//
//  插件列表视图（兼容旧版入口：自定义 URL 加载 + 市场列表）。
//

import SwiftUI

struct PluginView: View {
    @StateObject private var viewModel = PluginViewModel()
    @StateObject private var pluginManager = PluginManager.shared
    @State private var customURLString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("插件管理").font(.largeTitle)
                Spacer()
                TextField("自定义市场 URL", text: $customURLString)
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 300)
                Button("加载") {
                    let trimmed = customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
                    pluginManager.addCustomSource(name: "临时源", url: trimmed)
                    if let src = pluginManager.sources.last {
                        viewModel.switchSource(src)
                    }
                }
                .disabled(customURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("刷新") { viewModel.refreshPlugins() }
            }
            .padding(.horizontal)

            if viewModel.isLoading {
                ProgressView("加载中...").frame(maxWidth: .infinity).padding()
            } else if let error = viewModel.errorMessage {
                Text(error).foregroundColor(.red).padding()
            } else {
                List(viewModel.plugins) { plugin in
                    PluginRowView(plugin: plugin, viewModel: viewModel)
                }
                .listStyle(.plain)
            }
            Spacer()
        }
        .padding()
        .onAppear {
            if let src = pluginManager.selectedSource {
                viewModel.switchSource(src)
            }
        }
    }
}

/// Plugin row for PluginView
struct PluginRowView: View {
    let plugin: PanelPlugin
    @ObservedObject var viewModel: PluginViewModel
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.headline)
                Text(plugin.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("v\(plugin.version) · by \(plugin.author) · \(plugin.source.rawValue)")
                    .font(.caption2).foregroundStyle(.gray)
            }
            Spacer()
            if plugin.isInstalled {
                Text("已安装").font(.caption).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Button("卸载") {
                    viewModel.uninstallPlugin(plugin) { _, msg in alertMessage = msg; showAlert = true }
                }.buttonStyle(.bordered).tint(.red)
            } else {
                Button("安装") {
                    viewModel.installPlugin(plugin) { _, msg in alertMessage = msg; showAlert = true }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .alert("操作结果", isPresented: $showAlert) {
            Button("确定") {}
        } message: { Text(alertMessage) }
    }
}

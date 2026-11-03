//
//  PluginViewModel.swift
//  AiguruContainerPanel
//
//  插件视图模型，负责将 PluginManager 的状态导出给 UI。
//

import Foundation
import Combine

class PluginViewModel: ObservableObject {
    @Published var plugins: [AiguruContainerPanel.PanelPlugin] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var loadErrors: [String] = []

    private let pluginManager = PluginManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        pluginManager.$plugins
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.plugins = $0 }
            .store(in: &cancellables)
        pluginManager.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &cancellables)
        pluginManager.$loadErrors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errs in
                self?.loadErrors = errs
                self?.errorMessage = errs.isEmpty ? nil : errs.first
            }
            .store(in: &cancellables)
    }

    func refreshPlugins() {
        if let source = pluginManager.selectedSource {
            pluginManager.fetchPlugins(from: source)
        } else {
            errorMessage = "没有选中的市场"
        }
    }

    func switchSource(_ source: PluginSourceConfig) {
        pluginManager.selectedSource = source
        pluginManager.fetchPlugins(from: source)
    }

    func installPlugin(_ plugin: AiguruContainerPanel.PanelPlugin, completion: @escaping (Bool, String) -> Void) {
        // 使用真实的插件包安装（下载 .tar.gz）
        pluginManager.installPluginPackage(from: plugin.repositoryURL, name: plugin.name, completion: completion)
    }

    func uninstallPlugin(_ plugin: AiguruContainerPanel.PanelPlugin, completion: @escaping (Bool, String) -> Void) {
        pluginManager.uninstallPlugin(plugin, completion: completion)
    }
}

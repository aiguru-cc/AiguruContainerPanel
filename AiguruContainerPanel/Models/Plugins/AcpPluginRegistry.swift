//
//  AcpPluginRegistry.swift
//  AcpPlugins
//
//  插件注册中心。
//

import SwiftUI
import Combine

/// 全局插件注册表
public final class AcpPluginRegistry: ObservableObject, @unchecked Sendable {
    public static let shared = AcpPluginRegistry()

    @Published public private(set) var plugins: [AcpPlugin] = []

    private init() {}

    public func register(_ plugin: AcpPlugin) {
        guard !plugins.contains(where: { $0.name == plugin.name }) else { return }
        plugins.append(plugin)
    }

    public func unregister(named name: String) {
        plugins = plugins.filter { $0.name != name }
    }

    public func plugin(named name: String) -> AcpPlugin? {
        plugins.first { $0.name == name }
    }

    public var pluginNames: [String] { plugins.map(\.name) }
}

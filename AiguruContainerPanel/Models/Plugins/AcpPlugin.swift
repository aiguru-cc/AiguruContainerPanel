//
//  AcpPlugin.swift
//  AcpPlugins
//
//  插件协议 — 所有 ACP 插件必须实现此协议。
//  主应用通过 AcpPluginRegistry 发现并加载插件。
//

import SwiftUI

/// ACP 插件协议
public protocol AcpPlugin {
    /// 唯一标识（显示在侧边栏和插件列表）
    var name: String { get }
    /// 版本号
    var version: String { get }
    /// 作者
    var author: String { get }
    /// 功能描述
    var description: String { get }
    /// 插件图标（SF Symbol 名称）
    var icon: String { get }
    /// 创建插件主视图
    func makeView() -> AnyView
}

/// 默认实现
public extension AcpPlugin {
    var icon: String { "puzzlepiece.extension" }
}

/// 从 pluginInfo.json 注册的轻量插件包装器
struct PluginInfoWrapper: AcpPlugin {
    let name: String
    let version: String
    let author: String
    let description: String
    let icon: String

    func makeView() -> AnyView {
        // 路由由 MainView.contentView 处理
        return AnyView(
            VStack(spacing: 16) {
                Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
                Text(name).font(.title2)
                Text(description).foregroundStyle(.secondary)
                Text("v\(version) by \(author)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

//
//  PanelPlugin.swift
//  AiguruContainerPanel
//
//  面板插件管理模型，用于系统内部存储和展示插件信息。
//  与开发者协议 Plugin 分开，避免混淆。
//

import Foundation

/// 插件来源类型
enum PluginSource: String, Codable {
    case github
    case gitee
    case custom
}

/// 面板插件模型（系统管理用）
nonisolated struct PanelPlugin: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let description: String
    let version: String
    let author: String
    let source: PluginSource
    let repositoryURL: URL
    var installPath: String?
    var isInstalled: Bool = false
    var isEnabled: Bool = false

    // 排除 id/isInstalled/isEnabled 避免 JSON 解码时要求必须存在
    //（它们有默认值，JSON 中不应出现）
    enum CodingKeys: String, CodingKey {
        case name, description, version, author, source, repositoryURL
        case installPath
    }

    init(name: String, description: String, version: String, author: String,
         source: PluginSource, repositoryURL: URL, installPath: String? = nil,
         isInstalled: Bool = false, isEnabled: Bool = false) {
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.source = source
        self.repositoryURL = repositoryURL
        self.installPath = installPath
        self.isInstalled = isInstalled
        self.isEnabled = isEnabled
    }

    /// 从 repositoryURL 提取包名（如 .../AcpApiClientPlugin-v1.0.0.tar.gz → AcpApiClientPlugin）。
    /// 用于安装状态匹配：市场名可能与磁盘插件内部名/.market_name 不一致，但包名是一致的。
    var packageName: String? {
        let last = repositoryURL.deletingPathExtension().lastPathComponent
        if let range = last.range(of: "-v\\d", options: .regularExpression) {
            return String(last[..<range.lowerBound])
        }
        return last
    }

    /// 是否已安装：按市场名或包名匹配已安装集合（内部名 / .market_name / 磁盘目录包名）
    func isInstalled(knownNames: Set<String>, installedPackages: Set<String>) -> Bool {
        if knownNames.contains(name) { return true }
        if let pkg = packageName, installedPackages.contains(pkg) { return true }
        return false
    }
}

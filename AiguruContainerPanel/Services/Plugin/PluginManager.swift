//
//  PluginManager.swift
//  AiguruContainerPanel
//
//  插件管理服务，管理市场源注册、插件拉取（真实网络）、安装/卸载。
//  加载插件时对出错条目静默跳过，记录日志不中断整体流程。
//

import Foundation
import Combine
import AppKit

/// 宿主托管的动态插件（通过 dlopen + C ABI 加载）
struct HostedPlugin: Identifiable {
    let id: String            // 插件名（唯一）
    let name: String
    let version: String
    let author: String
    let description: String
    let icon: String
    let makeController: () -> NSViewController
}

/// 插件源配置
struct PluginSourceConfig: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var isCustom: Bool

    init(name: String, url: String, isCustom: Bool = false) {
        self.name = name
        self.url = url
        self.isCustom = isCustom
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, isCustom
    }
    
    // 让 id 也参与 Codable，保持持久化一致性
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        isCustom = try c.decode(Bool.self, forKey: .isCustom)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(isCustom, forKey: .isCustom)
    }
}

/// 市场返回的插件清单 JSON 结构
nonisolated struct PluginManifest: Codable {
    let plugins: [PanelPlugin]
}

/// 单个插件加载结果
struct PluginLoadResult {
    let plugin: PanelPlugin
    let error: String?       // 解析/加载错误（nil = 成功）
}

/// 插件管理器（单例）
class PluginManager: ObservableObject {
    static let shared = PluginManager()
    private var cancellables = Set<AnyCancellable>()
    private init() {
        loadSources()
        loadInstalledPlugins()
        // 启动即扫描已安装插件（dlopen 动态插件）
        loadInstalledPluginsFromDisk()
        // 环境切换时重新扫描插件
        EnvironmentManager.shared.$currentEnvironment
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("📦 环境已切换，重新扫描插件...")
                self?.loadInstalledPluginsFromDisk()
            }
            .store(in: &cancellables)
    }

    @Published var sources: [PluginSourceConfig] = []
    @Published var selectedSource: PluginSourceConfig?
    @Published var plugins: [PanelPlugin] = []
    @Published var installedPluginNames: Set<String> = []
    /// 磁盘上已安装插件的包名（目录名去版本后缀，如 AcpApiClientPlugin-v1.0.0 → AcpApiClientPlugin）。
    /// 用于市场名与磁盘内部名不一致时的安装状态匹配。
    @Published var installedPackages: Set<String> = []
    @Published var hostedPlugins: [HostedPlugin] = []   // 动态加载的插件
    @Published var isLoading = false
    @Published var loadErrors: [String] = []   // 加载过程中跳过的插件错误信息

    /// 托管插件控制器缓存（保持插件内部状态；单例持有，App 生命周期内稳定）
    private var pluginControllerCache: [String: NSViewController] = [:]

    /// 取插件控制器：优先复用缓存，首次创建并缓存
    func cachedController(for plugin: HostedPlugin) -> NSViewController {
        if let cached = pluginControllerCache[plugin.id] { return cached }
        let created = plugin.makeController()
        pluginControllerCache[plugin.id] = created
        return created
    }

    /// 插件卸载/移除时清理缓存
    func removeCachedController(id: String) {
        pluginControllerCache.removeValue(forKey: id)
    }

    /// 清理不在活跃插件列表中的缓存控制器
    func pruneCachedControllers(activeIDs: Set<String>) {
        for key in Array(pluginControllerCache.keys) where !activeIDs.contains(key) {
            pluginControllerCache.removeValue(forKey: key)
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - 源管理

    func loadSources() {
        var customSources: [PluginSourceConfig] = []
        if let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKey.pluginSources),
           let decoded = try? JSONDecoder().decode([PluginSourceConfig].self, from: data) {
            // 只保留用户自定义添加的源（isCustom == true），丢弃旧版内置源
            customSources = decoded.filter { $0.isCustom }
        }
        // 内置源始终从 AppConstants 取最新值，自定义源追加在后面
        let builtinSources = AppConstants.Plugin.defaultSources.map {
            PluginSourceConfig(name: $0.name, url: $0.url, isCustom: false)
        }
        self.sources = builtinSources + customSources
        saveSources()
        if selectedSource == nil, let first = sources.first {
            selectedSource = first
        }
    }

    func saveSources() {
        if let encoded = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(encoded, forKey: AppConstants.UserDefaultsKey.pluginSources)
        }
    }

    func addCustomSource(name: String, url: String) {
        let source = PluginSourceConfig(name: name, url: url, isCustom: true)
        sources.append(source)
        saveSources()
        selectedSource = source
        fetchPlugins(from: source)
    }

    func deleteSource(_ source: PluginSourceConfig) {
        sources.removeAll { $0.id == source.id }
        saveSources()
        if selectedSource?.id == source.id {
            selectedSource = sources.first
            if let newSource = selectedSource {
                fetchPlugins(from: newSource)
            } else {
                plugins = []
            }
        }
    }

    func updateSource(_ source: PluginSourceConfig, name: String, url: String) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        var updated = source
        updated.name = name
        updated.url = url
        sources[idx] = updated
        saveSources()
    }

    // MARK: - 拉取插件（真实网络请求 + 错误跳过）

    func fetchPlugins(from source: PluginSourceConfig) {
        guard let url = URL(string: source.url) else {
            loadErrors = ["无效的地址: \(source.url)"]
            return
        }

        isLoading = true
        loadErrors = []

        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadErrors = ["网络请求失败: \(error.localizedDescription)"]
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadErrors = ["无数据返回"]
                }
                return
            }

            // 先尝试解析为 [PanelPlugin]，再尝试解析为 { "plugins": [...] }
            var loaded: [PanelPlugin] = []
            var errors: [String] = []

            // 方式 1：直接数组
            if let directArray = try? JSONDecoder().decode([PanelPlugin].self, from: data) {
                loaded = self.mergeInstallStatus(directArray)
            }
            // 方式 2：manifest 包裹
            else if let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) {
                loaded = self.mergeInstallStatus(manifest.plugins)
            }
            // 方式 3：逐条尝试解码（容错：跳过解析失败的条目）
            else if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for (idx, item) in rawArray.enumerated() {
                    do {
                        let itemData = try JSONSerialization.data(withJSONObject: item)
                        let plugin = try JSONDecoder().decode(PanelPlugin.self, from: itemData)
                        let merged = self.mergeOneInstallStatus(plugin)
                        loaded.append(merged)
                    } catch {
                        let name = item["name"] as? String ?? "条目 #\(idx)"
                        errors.append("「\(name)」解析失败: \(error.localizedDescription)")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadErrors = ["数据格式无法识别"]
                }
                return
            }

            DispatchQueue.main.async {
                self.plugins = loaded
                self.loadErrors = errors
                self.isLoading = false
            }
        }.resume()
    }

    private func mergeInstallStatus(_ plugins: [PanelPlugin]) -> [PanelPlugin] {
        plugins.map { mergeOneInstallStatus($0) }
    }

    private func mergeOneInstallStatus(_ plugin: PanelPlugin) -> PanelPlugin {
        var p = plugin
        p.isInstalled = p.isInstalled(knownNames: installedPluginNames, installedPackages: installedPackages)
        return p
    }

    // MARK: - 安装/卸载

    func installPlugin(_ plugin: PanelPlugin, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            var installed = self.installedPluginNames
            installed.insert(plugin.name)
            DispatchQueue.main.async {
                self.installedPluginNames = installed
                if let index = self.plugins.firstIndex(where: { $0.id == plugin.id }) {
                    var updated = plugin
                    updated.isInstalled = true
                    self.plugins[index] = updated
                }
                UserDefaults.standard.set(Array(self.installedPluginNames), forKey: AppConstants.UserDefaultsKey.installedPlugins)
                completion(true, "安装成功")
            }
        }
    }

    func uninstallPlugin(_ plugin: PanelPlugin, completion: @escaping (Bool, String) -> Void) {
        let name = plugin.name
        let taskManager = TaskManager.shared
        let dir = pluginsDirectory
        let log = LogService.shared

        print("🗑️ 开始卸载: \(name), 目录: \(dir.path)")

        DispatchQueue.main.async {
            taskManager.startTask(module: "插件", operation: "卸载", command: name)
            taskManager.appendOutput("正在卸载 \(name)...")

            // 1. 先清理下载缓存（所有 .tar.gz）——避免目录匹配后 break 跳过清理
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in contents where !url.hasDirectoryPath
                    && url.lastPathComponent.hasSuffix("." + AppConstants.Plugin.packageExtension) {
                    self.forceRemovePluginDir(at: url)
                    print("🗑️ 下载缓存已删除: \(url.lastPathComponent)")
                }
            }

            // 2. 扫描目录找到匹配的插件，读取实际名用于 Registry 移除
            var actualPluginName: String? = nil
            var removedDir: URL? = nil
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                print("🗑️ 扫描到 \(contents.count) 项")
                let dirs = contents.filter(\.hasDirectoryPath)

                // 先按 pluginInfo.json 的 name（权威）匹配
                for url in dirs {
                    let infoPath = url.appendingPathComponent("pluginInfo.json")
                    if let data = try? Data(contentsOf: infoPath),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let jsonName = json["name"],
                       jsonName == name {
                        actualPluginName = jsonName
                        self.setPluginStatus(at: url, status: "uninstalled")
                        removedDir = url
                        self.forceRemovePluginDir(at: url)
                        print("🗑️ 插件目录已删除(按 jsonName): \(url.lastPathComponent)")
                        break
                    }
                }
                // 未按 jsonName 匹配到，再按 .market_name 兜底
                if actualPluginName == nil {
                    for url in dirs {
                        let marketName = (try? String(contentsOf: url.appendingPathComponent(".market_name"), encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if marketName == name {
                            // 兜底命中时也要读取 pluginInfo.json 的真实名，用于后续移除 registry/hostedPlugins
                            let infoPath = url.appendingPathComponent("pluginInfo.json")
                            let jsonName = (try? JSONSerialization.jsonObject(with: Data(contentsOf: infoPath)) as? [String: String])?["name"]
                            actualPluginName = jsonName ?? name
                            self.setPluginStatus(at: url, status: "uninstalled")
                            removedDir = url
                            self.forceRemovePluginDir(at: url)
                            print("🗑️ 插件目录已删除(按 market_name): \(url.lastPathComponent) (内部名: \(actualPluginName ?? "?"))")
                            break
                        }
                    }
                }
                // 仍未匹配到，再按包名兜底（市场 repositoryURL 包名 == 磁盘目录名去版本后缀）
                // 覆盖市场名与磁盘内部名/.market_name 都不一致的情况（如 API客户端 vs API 测试）
                if actualPluginName == nil, let pkg = plugin.packageName {
                    for url in dirs {
                        if self.packageName(fromDirectoryName: url.lastPathComponent) == pkg {
                            let infoPath = url.appendingPathComponent("pluginInfo.json")
                            let jsonName = (try? JSONSerialization.jsonObject(with: Data(contentsOf: infoPath)) as? [String: String])?["name"]
                            actualPluginName = jsonName ?? name
                            self.setPluginStatus(at: url, status: "uninstalled")
                            removedDir = url
                            self.forceRemovePluginDir(at: url)
                            print("🗑️ 插件目录已删除(按包名): \(url.lastPathComponent) (内部名: \(actualPluginName ?? "?"))")
                            break
                        }
                    }
                }
            } else {
                print("🗑️ 无法读取目录: \(dir.path)")
            }

            // 校验：匹配到目录但删除未成功 → 如实报告失败，避免“卸载成功但文件残留”
            if let dir = removedDir, FileManager.default.fileExists(atPath: dir.path) {
                taskManager.finishTask(success: false, message: "卸载失败：目录删除未成功（文件被占用？）")
                log.log(result: CLIResult(command: "uninstall \(name)", output: "目录删除失败", exitCode: -1, duration: 0, mode: .async),
                        module: "插件", operationType: "卸载失败")
                completion(false, "卸载失败：目录删除未成功（文件被占用？）")
                return
            }

            // 2. 从 Registry 移除（用实际插件名，同时兜底市场名）
            let registryName = actualPluginName ?? name
            AcpPluginRegistry.shared.unregister(named: registryName)
            AcpPluginRegistry.shared.unregister(named: name)   // 双名兜底
            print("🗑️ Registry 已移除: \(registryName) (剩余 \(AcpPluginRegistry.shared.pluginNames.count) 项)")
            // 从动态托管插件移除（内部名 + 市场名都匹配）
            self.hostedPlugins.removeAll { $0.id == registryName || $0.id == name }
            print("🗑️ 托管插件已移除: \(registryName) (剩余 \(self.hostedPlugins.count) 项)")

            // 3. 从记录移除（目录已删除，从磁盘重建剩余状态，避免残留已卸载的包名/名字）
            let diskState = self.collectDiskInstalledState()
            self.installedPluginNames = diskState.names
            self.installedPackages = diskState.packages
            if let idx = self.plugins.firstIndex(where: { $0.id == plugin.id }) {
                var u = plugin; u.isInstalled = false; self.plugins[idx] = u
            }
            UserDefaults.standard.set(Array(diskState.names), forKey: AppConstants.UserDefaultsKey.installedPlugins)
            UserDefaults.standard.set(Array(diskState.packages), forKey: AppConstants.UserDefaultsKey.installedPluginPackages)
            taskManager.finishTask(success: true, message: "\(name) 已卸载")
            log.log(result: CLIResult(command: "uninstall \(name)", output: "OK", exitCode: 0, duration: 0, mode: .async),
                     module: "插件", operationType: "卸载")
            completion(true, "卸载成功")
        }
    }

    func loadInstalledPlugins() {
        if let list = UserDefaults.standard.array(forKey: AppConstants.UserDefaultsKey.installedPlugins) as? [String] {
            self.installedPluginNames = Set(list)
        } else {
            self.installedPluginNames = []
        }
        if let packages = UserDefaults.standard.array(forKey: AppConstants.UserDefaultsKey.installedPluginPackages) as? [String] {
            self.installedPackages = Set(packages)
        } else {
            self.installedPackages = []
        }
    }

    // MARK: - 插件磁盘加载（dlopen）

    /// 从磁盘扫描并加载已安装的插件（含日志）。
    /// 安全审查为 IO/CPU 密集操作（读 dylib + 正则扫描 + nm 子进程），
    /// 全部在后台执行，避免阻塞主线程导致启动时界面无法显示。
    func loadInstalledPluginsFromDisk() {
        let dir = pluginsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("📦 插件: 目录不存在，跳过扫描")
            return
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        print("📦 插件: 扫描 \(dir.path) → \(contents.count) 项")

        let candidates = contents.filter { url in
            let name = url.lastPathComponent
            return !(name.hasSuffix("." + AppConstants.Plugin.packageExtension) || name.hasPrefix("."))
                && url.hasDirectoryPath
        }
        guard !candidates.isEmpty else { return }

        // 后台：安全审查（危险插件跳过）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var approved: [URL] = []
            var rejected: [(name: String, report: PluginSecurityReport)] = []
            for url in candidates {
                let report = PluginSecurityAuditor.shared.audit(packageDirectory: url)
                if report.allowed {
                    if report.warningCount > 0 {
                        print("⚠️ 插件: \(url.lastPathComponent) 安全审查警告: \(report.summary)")
                    }
                    approved.append(url)
                } else {
                    print("🛡️ 插件: \(url.lastPathComponent) 安全审查未通过，跳过加载: \(report.summary)")
                    rejected.append((url.lastPathComponent, report))
                }
            }

            // 主线程：更新 @Published 状态（registry / loadErrors / installedPluginNames / installedPackages）+ 审查结果入操作日志
            DispatchQueue.main.async {
                for item in approved {
                    let report = PluginSecurityAuditor.shared.audit(packageDirectory: item)
                    LogService.shared.log(result: CLIResult(command: "audit \(item.lastPathComponent)", output: self.auditLogOutput(report), exitCode: 0, duration: 0, mode: .async),
                                          module: "插件", operationType: "安全审查")
                }
                for item in rejected {
                    LogService.shared.log(result: CLIResult(command: "audit \(item.name)", output: self.auditLogOutput(item.report), exitCode: -1, duration: 0, mode: .async),
                                          module: "插件", operationType: "安全审查拦截")
                }
                if !rejected.isEmpty {
                    self.loadErrors.append(contentsOf: rejected.map { "\($0.name): 安全审查未通过（\($0.report.summary)）" })
                }
                // 磁盘上成功注册的插件同步进已安装列表，保证市场状态一致
                // （即使 installedPluginNames 记录丢失/被清空，启动扫描也能自动恢复）
                let diskState = self.collectDiskInstalledState()
                let mergedNames = self.installedPluginNames.union(diskState.names)
                let mergedPackages = self.installedPackages.union(diskState.packages)
                if mergedNames != self.installedPluginNames || mergedPackages != self.installedPackages {
                    self.installedPluginNames = mergedNames
                    self.installedPackages = mergedPackages
                    UserDefaults.standard.set(Array(mergedNames), forKey: AppConstants.UserDefaultsKey.installedPlugins)
                    UserDefaults.standard.set(Array(mergedPackages), forKey: AppConstants.UserDefaultsKey.installedPluginPackages)
                }
                for url in approved {
                    self.registerPluginFromDisk(at: url)
                }
                // dlopen（含 dylib 复审）放后台，loadPluginDylib 内部自行切回主线程更新 hostedPlugins
                DispatchQueue.global(qos: .utility).async {
                    for url in approved {
                        if let dylib = self.dylibURL(in: url) {
                            self.loadPluginDylib(at: dylib)
                        }
                    }
                }
            }
        }
    }

    /// 从插件目录解析 dylib 路径（pluginInfo 的 dylib 字段优先，否则目录内任意 .dylib）
    private func dylibURL(in dir: URL) -> URL? {
        let infoPath = dir.appendingPathComponent("pluginInfo.json")
        var dylibName: String? = nil
        if let data = try? Data(contentsOf: infoPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dylibName = json["dylib"]
        }
        if let name = dylibName {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let dylibs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "dylib" }),
           !dylibs.isEmpty {
            return dylibs.first
        }
        return nil
    }

    /// 从 pluginInfo.json 注册插件到主应用 AcpPluginRegistry，返回是否成功注册
    @discardableResult
    private func registerPluginFromDisk(at dir: URL) -> Bool {
        let infoPath = dir.appendingPathComponent("pluginInfo.json")
        guard FileManager.default.fileExists(atPath: infoPath.path),
              let data = try? Data(contentsOf: infoPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = json["name"] else {
            print("⚠️ 插件: \(dir.lastPathComponent) 无有效 pluginInfo.json")
            return false
        }
        // 跳过已标记卸载的插件
        if json["status"] == "uninstalled" {
            print("⏭️ 插件: \(name) 已标记卸载，跳过")
            return false
        }
        let version = json["version"] ?? "0.0.0"
        let author = json["author"] ?? ""
        let desc  = json["description"] ?? ""
        let icon  = json["icon"] ?? "puzzlepiece.extension"

        let wrapper = PluginInfoWrapper(name: name, version: version, author: author, description: desc, icon: icon)
        AcpPluginRegistry.shared.register(wrapper)
        print("✅ 插件: \(name) v\(version) 已注册 (共 \(AcpPluginRegistry.shared.pluginNames.count) 项)")
        return true
    }

    /// 读取插件目录 pluginInfo.json 中的插件名（未安装/无效时返回 nil）
    private func pluginName(in dir: URL) -> String? {
        let infoPath = dir.appendingPathComponent("pluginInfo.json")
        guard let data = try? Data(contentsOf: infoPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = json["name"], json["status"] != "uninstalled" else { return nil }
        return name
    }

    /// 从磁盘扫描重建已安装状态。
    /// names：pluginInfo.json 内部名 + .market_name 市场名；packages：目录包名。
    /// 确保与市场清单任意命名方式都能匹配（三者可能不一致）。
    private func collectDiskInstalledState() -> (names: Set<String>, packages: Set<String>) {
        var names = Set<String>()
        var packages = Set<String>()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil) else {
            return (names, packages)
        }
        for url in contents where url.hasDirectoryPath {
            if let name = pluginName(in: url) {
                names.insert(name)
            }
            if let market = try? String(contentsOf: url.appendingPathComponent(".market_name"), encoding: .utf8) {
                let t = market.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { names.insert(t) }
            }
            // 目录包名（AcpApiClientPlugin-v1.0.0 → AcpApiClientPlugin）
            if let pkg = packageName(fromDirectoryName: url.lastPathComponent) {
                packages.insert(pkg)
            }
        }
        return (names, packages)
    }

    /// 目录名去版本后缀得到包名（AcpApiClientPlugin-v1.0.0 → AcpApiClientPlugin）
    private func packageName(fromDirectoryName name: String) -> String? {
        if let range = name.range(of: "-v\\d", options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name.isEmpty ? nil : name
    }

    /// 生成安全审查日志 output：首行结论 + 逐条明细（对齐容器创建等操作日志的多行格式）
    private func auditLogOutput(_ report: PluginSecurityReport) -> String {
        var lines = [report.summary]
        for f in report.findings {
            lines.append("  [\(f.severity.rawValue)] \(f.category): \(f.detail) @\(f.source)")
        }
        return lines.joined(separator: "\n")
    }

    /// 安装成功后从插件目录解析包名（按 .market_name / pluginInfo 名匹配）
    private func pluginPackageName(from marketName: String, installedDirectory dir: URL) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for url in contents where url.hasDirectoryPath {
            if let market = try? String(contentsOf: url.appendingPathComponent(".market_name"), encoding: .utf8),
               market.trimmingCharacters(in: .whitespacesAndNewlines) == marketName {
                return packageName(fromDirectoryName: url.lastPathComponent)
            }
        }
        for url in contents where url.hasDirectoryPath {
            if pluginName(in: url) == marketName {
                return packageName(fromDirectoryName: url.lastPathComponent)
            }
        }
        return nil
    }

    /// 写入 pluginInfo.json 中的状态标记
    private func setPluginStatus(at dir: URL, status: String) {
        let infoPath = dir.appendingPathComponent("pluginInfo.json")
        guard FileManager.default.fileExists(atPath: infoPath.path),
              let data = try? Data(contentsOf: infoPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("⚠️ 无法读取 pluginInfo.json: \(infoPath.path)")
            return
        }
        json["status"] = status
        do {
            let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try newData.write(to: infoPath, options: .atomic)
            print("📝 状态已更新: \(dir.lastPathComponent) → \(status)")
        } catch {
            print("⚠️ 写入状态失败: \(error.localizedDescription)")
        }
    }

    /// 递归删除目录（包括已 dlopen 的 dylib）
    private func forceRemovePluginDir(at url: URL) {
        let fm = FileManager.default
        print("🗑️ forceRemove: \(url.lastPathComponent)")
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            // 可能是文件而非目录，直接 unlink
            let path = url.path
            if unlink(path) != 0 { try? fm.removeItem(at: url) }
            print("🗑️ forceRemove done (file): \(url.lastPathComponent)")
            return
        }
        for f in files {
            if f.hasDirectoryPath {
                self.forceRemovePluginDir(at: f)
            } else {
                let path = f.path
                print("🗑️   unlink: \(f.lastPathComponent)")
                if unlink(path) != 0 {
                    print("🗑️   unlink failed: \(f.lastPathComponent)")
                    try? fm.removeItem(at: f)
                }
            }
        }
        do {
            try fm.removeItem(at: url)
            print("🗑️ forceRemove done (dir): \(url.lastPathComponent)")
        } catch {
            print("⚠️ forceRemove dir failed: \(url.lastPathComponent) — \(error.localizedDescription)")
            _ = rmdir(url.path)
        }
    }

    @Published var installingPluginName: String? = nil

    /// 安装插件：下载 (tar.gz) 并解压（集成进度条 + 日志）
    func installPluginPackage(from url: URL, name: String, completion: @escaping (Bool, String) -> Void) {
        // 自动将 Gitee tree URL 转为 raw URL
        var downloadURL = url
        let urlStr = url.absoluteString
        if urlStr.contains("gitee.com") && urlStr.contains("/tree/") {
            if let rawURL = URL(string: urlStr.replacingOccurrences(of: "/tree/", with: "/raw/")) {
                downloadURL = rawURL
            }
        }

        let taskManager = TaskManager.shared
        let log = LogService.shared
        let dir = pluginsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destTar = dir.appendingPathComponent("\(name)." + AppConstants.Plugin.packageExtension)

        DispatchQueue.main.async {
            self.installingPluginName = name
            self.isLoading = true
            taskManager.startTask(module: "插件", operation: "安装", command: name)
            taskManager.setIndeterminate(true)
            taskManager.appendOutput("正在下载 \(name)...")
        }

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] localURL, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.isLoading = false; self.installingPluginName = nil
                    taskManager.finishTask(success: false, message: "下载失败: \(error.localizedDescription)")
                }
                completion(false, "下载失败: \(error.localizedDescription)")
                return
            }
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.isLoading = false; self.installingPluginName = nil
                    taskManager.finishTask(success: false, message: "无数据")
                }
                completion(false, "无数据"); return
            }

            do {
                if FileManager.default.fileExists(atPath: destTar.path) { try FileManager.default.removeItem(at: destTar) }
                try FileManager.default.moveItem(at: localURL, to: destTar)

                // 校验下载内容：必须是有效 gzip（1F 8B），否则为 404 页/错误内容
                if let data = try? Data(contentsOf: destTar), data.count >= 2,
                   data[0] != 0x1F || data[1] != 0x8B {
                    try? FileManager.default.removeItem(at: destTar)
                    DispatchQueue.main.async {
                        self.isLoading = false; self.installingPluginName = nil
                        taskManager.finishTask(success: false, message: "下载内容无效（文件不存在或链接错误）")
                    }
                    completion(false, "下载内容无效（文件不存在或链接错误）")
                    return
                }

                DispatchQueue.main.async { taskManager.appendOutput("正在解压...") }

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                task.arguments = ["-xzf", destTar.path, "-C", dir.path]
                // tar 错误输出重定向到临时文件（避免管道缓冲死锁），解压失败时展示具体原因
                let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("tar-\(UUID().uuidString).err")
                defer { try? FileManager.default.removeItem(at: errURL) }
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                task.standardError = FileHandle(forWritingAtPath: errURL.path)
                try task.run(); task.waitUntilExit()

                if task.terminationStatus == 0 {
                    // 全部切换到主线程执行（register/UI 更新必须在 main thread）
                    DispatchQueue.main.async {
                        taskManager.appendOutput("正在注册插件...")
                        // 只处理本次 tar 解压产生的新目录（避免覆盖其它已安装插件的元数据）
                        let freshContents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                        let knownNames = Set(self.installedPluginNames)
                        for item in freshContents where item.hasDirectoryPath && item.lastPathComponent != "." {
                            let infoPath = item.appendingPathComponent("pluginInfo.json")
                            let infoName = (try? JSONSerialization.jsonObject(with: Data(contentsOf: infoPath)) as? [String: String])?["name"]
                            // 新目录 = 含有效 pluginInfo.json 且未被记录为已安装的目录
                            if let infoName, !knownNames.contains(infoName) {
                                // 🛡️ 安全审查：危险插件拒绝安装并清理
                                let report = PluginSecurityAuditor.shared.audit(packageDirectory: item)
                                if !report.allowed {
                                    self.forceRemovePluginDir(at: item)
                                    self.isLoading = false; self.installingPluginName = nil
                                    taskManager.finishTask(success: false, message: "安全审查未通过，已拒绝安装: \(report.summary)")
                                    log.log(result: CLIResult(command: "install \(name)", output: report.summary, exitCode: -1, duration: 0, mode: .async),
                                            module: "插件", operationType: "安装被安全审查拦截")
                                    completion(false, "安全审查未通过（\(report.summary)），已拒绝安装")
                                    return
                                }
                                if report.warningCount > 0 {
                                    taskManager.appendOutput("⚠️ 安全审查警告: \(report.summary)")
                                }
                                // 审查通过结果入操作日志（含明细）
                                log.log(result: CLIResult(command: "install \(name) audit", output: self.auditLogOutput(report), exitCode: 0, duration: 0, mode: .async),
                                        module: "插件", operationType: "安全审查")
                                try? name.write(to: item.appendingPathComponent(".market_name"), atomically: true, encoding: .utf8)
                                self.registerPluginFromDisk(at: item)
                                self.setPluginStatus(at: item, status: "installed")
                            }
                        }
                        self.loadInstalledPluginsFromDisk()
                        var names = self.installedPluginNames
                        names.insert(name)
                        self.installedPluginNames = names
                        // 同步包名到已安装集合（包名匹配市场 repositoryURL）
                        var packages = self.installedPackages
                        if let pkg = self.pluginPackageName(from: name, installedDirectory: dir) {
                            packages.insert(pkg)
                        }
                        self.installedPackages = packages
                        // 更新市场插件列表中的 isInstalled 状态
                        if let idx = self.plugins.firstIndex(where: { $0.name == name }) {
                            var updated = self.plugins[idx]
                            updated.isInstalled = true
                            self.plugins[idx] = updated
                        }
                        self.isLoading = false
                        self.installingPluginName = nil
                        taskManager.finishTask(success: true, message: "\(name) 安装成功 ✅")
                        UserDefaults.standard.set(Array(names), forKey: AppConstants.UserDefaultsKey.installedPlugins)
                        UserDefaults.standard.set(Array(packages), forKey: AppConstants.UserDefaultsKey.installedPluginPackages)
                        log.log(result: CLIResult(command: "install \(name)", output: "OK", exitCode: 0, duration: 0, mode: .async),
                                 module: "插件", operationType: "安装")
                        completion(true, "安装成功")
                    }
                } else {
                    let errMsg = (try? String(contentsOf: errURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
                    DispatchQueue.main.async {
                        self.isLoading = false; self.installingPluginName = nil
                        taskManager.finishTask(success: false, message: "解压失败: \(errMsg)")
                    }
                    completion(false, "解压失败: \(errMsg)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false; self.installingPluginName = nil
                    taskManager.finishTask(success: false, message: error.localizedDescription)
                }
                completion(false, "安装失败: \(error.localizedDescription)")
            }
        }.resume()
    }

    /// 插件根目录
    var pluginsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppConstants.Paths.pluginDirectoryName)
    }

    private func loadPluginDylib(at path: URL) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        // 🛡️ dlopen 前安全审查（最后防线，与目录审查双保险）
        let report = PluginSecurityAuditor.shared.audit(dylib: path)
        guard report.allowed else {
            print("🛡️ dlopen 拦截: \(path.lastPathComponent) 安全审查未通过: \(report.summary)")
            let msg = "\(path.lastPathComponent): 安全审查未通过（\(report.summary)）"
            let detail = self.auditLogOutput(report)
            DispatchQueue.main.async { [weak self] in
                self?.loadErrors.append(msg)
                LogService.shared.log(result: CLIResult(command: "dlopen \(path.lastPathComponent)", output: detail, exitCode: -1, duration: 0, mode: .async),
                                      module: "插件", operationType: "安全审查拦截(dlopen)")
            }
            return
        }

        guard let handle = dlopen(path.path, RTLD_NOW) else {
            let err = String(cString: dlerror())
            print("⚠️ dlopen 失败 (\(path.lastPathComponent)): \(err)")
            return
        }

        // 新 C ABI：info + make_view_controller
        guard let infoSym = dlsym(handle, "acp_plugin_info"),
              let makeSym = dlsym(handle, "acp_plugin_make_view_controller") else {
            print("⚠️ dlsym 未找到 acp_plugin_info / acp_plugin_make_view_controller in \(path.lastPathComponent)")
            return
        }

        // 注入数据管理服务（可选符号，旧插件无此符号则跳过）
        if let setServiceSym = dlsym(handle, "acp_plugin_set_data_service") {
            typealias SetServiceFunc = @convention(c) (UnsafeRawPointer?) -> Void
            let setService = unsafeBitCast(setServiceSym, to: SetServiceFunc.self)
            withUnsafePointer(to: dataManagerServiceV1) { ptr in
                setService(UnsafeRawPointer(ptr))
            }
            print("📦 已注入数据管理服务 → \(path.lastPathComponent)")
        }

        // 注入通用命令执行服务（可选符号，旧插件无此符号则跳过）
        if let setServiceSym = dlsym(handle, "acp_plugin_set_command_service") {
            typealias SetServiceFunc = @convention(c) (UnsafeRawPointer?) -> Void
            let setService = unsafeBitCast(setServiceSym, to: SetServiceFunc.self)
            withUnsafePointer(to: commandServiceV1) { ptr in
                setService(UnsafeRawPointer(ptr))
            }
            print("📦 已注入命令执行服务 → \(path.lastPathComponent)")
        }

        // 解析元数据: "name|version|author|description|icon"
        typealias InfoFunc = @convention(c) () -> UnsafeMutablePointer<CChar>?
        typealias MakeFunc = @convention(c) () -> UnsafeMutableRawPointer
        let infoFunc = unsafeBitCast(infoSym, to: InfoFunc.self)
        let makeFunc = unsafeBitCast(makeSym, to: MakeFunc.self)

        guard let cstr = infoFunc() else {
            print("⚠️ acp_plugin_info 返回空 (\(path.lastPathComponent))")
            return
        }
        let parts = String(cString: cstr).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else {
            print("⚠️ acp_plugin_info 格式错误: \(path.lastPathComponent)")
            return
        }
        let name = parts[0]
        let version = parts[1]
        let author = parts[2]
        let desc = parts[3]
        let icon = parts[4]

        // 创建视图控制器工厂
        let plugin = HostedPlugin(id: name, name: name, version: version, author: author,
                                  description: desc, icon: icon) {
            let ptr = makeFunc()
            return Unmanaged<NSViewController>.fromOpaque(ptr).takeRetainedValue()
        }

        DispatchQueue.main.async {
            if let idx = self.hostedPlugins.firstIndex(where: { $0.id == name }) {
                self.hostedPlugins[idx] = plugin
            } else {
                self.hostedPlugins.append(plugin)
            }
            print("✅ 动态插件已加载: \(name) v\(version) (共 \(self.hostedPlugins.count) 项)")
        }
    }

    // MARK: - 缓存清理

    /// 清理下载缓存和未成功安装的插件残留
    func clearPluginCache() -> (removed: Int, freedBytes: Int64) {
        let dir = pluginsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return (0, 0) }

        var count = 0
        var bytes: Int64 = 0

        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else {
            return (0, 0)
        }

        for url in contents {
            let name = url.lastPathComponent
            // 删除 .tar.gz 下载缓存、不以 "Acp" 开头或非目录的残留
            let isTar = name.hasSuffix("." + AppConstants.Plugin.packageExtension)
            let isTmp = name.hasPrefix(".") || name.hasPrefix("tmp")
            if isTar || isTmp {
                if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attrs.fileSize {
                    bytes += Int64(size)
                }
                try? FileManager.default.removeItem(at: url)
                count += 1
            }
        }

        // 重建已安装列表：从磁盘扫描仍存在的插件目录（只清缓存，不清已安装状态）
        // 同时收集内部名、.market_name 市场名与目录包名，避免「已安装的插件在市场显示为未安装」的状态不一致
        let diskState = collectDiskInstalledState()
        self.installedPluginNames = diskState.names
        self.installedPackages = diskState.packages
        UserDefaults.standard.set(Array(diskState.names), forKey: AppConstants.UserDefaultsKey.installedPlugins)
        UserDefaults.standard.set(Array(diskState.packages), forKey: AppConstants.UserDefaultsKey.installedPluginPackages)

        return (count, bytes)
    }
}

import Darwin  // for dlopen/dlsym/dlerror

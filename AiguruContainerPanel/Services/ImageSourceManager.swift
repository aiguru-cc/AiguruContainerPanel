//
//  ImageSourceManager.swift
//  AiguruContainerPanel
//
//  管理镜像源和预定义镜像，使用 Core Data 持久化。
//  预置国内常用镜像源（阿里云、中科大、网易、腾讯云、清华大学等）。
//

import Foundation
import CoreData
import Combine

class ImageSourceManager: ObservableObject {
    @Published var isLoading = false

    static let shared = ImageSourceManager()
    private init() {
        print("📦 ImageSourceManager 初始化")
        _ = PersistenceController.shared.container.viewContext
        populateRecommendedIfNeeded()
        loadSources()
        if let first = sources.first {
            currentSource = first
        }
    }

    private let context = PersistenceController.shared.container.viewContext

    @Published var sources: [ImageSource] = []
    @Published var entriesForCurrentSource: [ImageEntry] = []
    @Published var allEntries: [ImageEntry] = []   // 所有源的常用镜像（不按源筛选）
    @Published var currentSource: ImageSource? {
        didSet {
            print("🔁 当前源切换至: \(currentSource?.name ?? "nil")")
            loadEntries(for: currentSource)
        }
    }

    // MARK: - 加载数据
    // 修改 loadSources 方法
    func loadSources() {
        isLoading = true
        let request: NSFetchRequest<ImageSource> = ImageSource.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ImageSource.order, ascending: true)]
        do {
            sources = try context.fetch(request)
            print("✅ 加载镜像源成功，共 \(sources.count) 个源")
            if currentSource == nil, let first = sources.first {
                currentSource = first
            }
        } catch {
            print("❌ 加载镜像源失败: \(error)")
        }
        isLoading = false
    }

    // 修改 loadEntries 方法
    func loadEntries(for source: ImageSource?) {
        isLoading = true
        defer { isLoading = false }
        guard let source = source else {
            entriesForCurrentSource = []
            return
        }
        let request: NSFetchRequest<ImageEntry> = ImageEntry.fetchRequest()
        request.predicate = NSPredicate(format: "source == %@", source)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ImageEntry.name, ascending: true)]
        do {
            entriesForCurrentSource = try context.fetch(request)
            print("✅ 加载镜像条目成功，共 \(entriesForCurrentSource.count) 个条目")
        } catch {
            print("❌ 加载镜像条目失败: \(error)")
            entriesForCurrentSource = []
        }
    }

    /// 加载所有源的条目（去重，用于快速录入）
    func loadAllEntries() {
        let request: NSFetchRequest<ImageEntry> = ImageEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ImageEntry.name, ascending: true)]
        do {
            let fetched = try context.fetch(request)
            var seen = Set<String>()
            allEntries = fetched.filter {
                let key = "\($0.name ?? ""):\($0.tag ?? "")"
                return seen.insert(key).inserted
            }
            print("✅ 加载全部镜像条目成功，共 \(allEntries.count) 个条目（去重后）")
        } catch {
            print("❌ 加载全部镜像条目失败: \(error)")
            allEntries = []
        }
    }

    // MARK: - 源操作
    func addSource(name: String, url: String, type: String = "custom", isCustom: Bool = true) {
        print("📝 添加镜像源: \(name), URL: \(url)")
        let source = ImageSource(context: context)
        source.id = UUID()
        source.name = name
        source.url = url
        source.type = type
        source.isCustom = isCustom
        source.order = Int16(sources.count)
        do {
            try context.save()
            print("✅ 镜像源保存成功")
            loadSources()
        } catch {
            print("❌ 保存镜像源失败: \(error)")
        }
    }

    func deleteSource(_ source: ImageSource) {
        print("🗑️ 删除镜像源: \(source.name ?? "未知")")
        context.delete(source)
        do {
            try context.save()
            print("✅ 镜像源删除成功")
            loadSources()
        } catch {
            print("❌ 删除镜像源失败: \(error)")
        }
    }

    // MARK: - 镜像条目操作
    func addEntry(name: String, tag: String = "latest", attribute: String? = nil, isRecommended: Bool = false, to source: ImageSource) {
        print("📝 添加镜像条目: \(name):\(tag) 到源 \(source.name ?? "未知")")
        let entry = ImageEntry(context: context)
        entry.id = UUID()
        entry.name = name
        entry.tag = tag
        entry.attribute = attribute
        entry.isRecommended = isRecommended
        entry.source = source
        do {
            try context.save()
            print("✅ 镜像条目保存成功")
            loadEntries(for: source)
        } catch {
            print("❌ 保存镜像条目失败: \(error)")
        }
    }

    func deleteEntry(_ entry: ImageEntry) {
        print("🗑️ 删除镜像条目: \(entry.name ?? "未知")")
        let source = entry.source
        context.delete(entry)
        do {
            try context.save()
            print("✅ 镜像条目删除成功")
            if let src = source {
                loadEntries(for: src)
            }
        } catch {
            print("❌ 删除镜像条目失败: \(error)")
        }
    }

    // MARK: - 远程导入
    func importFromRemote(url: URL, completion: @escaping (Bool, String) -> Void) {
        print("🌐 开始远程导入: \(url)")
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    print("❌ 网络错误: \(error.localizedDescription)")
                    completion(false, "网络错误: \(error.localizedDescription)")
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    print("❌ 无数据返回")
                    completion(false, "无数据返回")
                }
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                guard let items = json else {
                    DispatchQueue.main.async {
                        print("❌ 数据格式无效")
                        completion(false, "数据格式无效")
                    }
                    return
                }
                print("✅ 解析到 \(items.count) 个源")
                for item in items {
                    guard let name = item["name"] as? String,
                          let url = item["url"] as? String else { continue }
                    let type = item["type"] as? String ?? "custom"
                    let source = ImageSource(context: self.context)
                    source.id = UUID()
                    source.name = name
                    source.url = url
                    source.type = type
                    source.isCustom = true
                    source.order = Int16(self.sources.count + 1)
                    if let entries = item["entries"] as? [[String: String]] {
                        for entryDict in entries {
                            let entry = ImageEntry(context: self.context)
                            entry.id = UUID()
                            entry.name = entryDict["name"] ?? "unknown"
                            entry.tag = entryDict["tag"] ?? "latest"
                            entry.attribute = entryDict["attribute"]
                            entry.isRecommended = true
                            entry.source = source
                        }
                    }
                }
                try self.context.save()
                DispatchQueue.main.async {
                    self.loadSources()
                    print("✅ 远程导入成功")
                    completion(true, "导入成功")
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ 解析失败: \(error.localizedDescription)")
                    completion(false, "解析失败: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    // MARK: - 推荐数据填充（预置国内常用镜像源）
    func populateRecommendedIfNeeded() {
        let fetchRequest: NSFetchRequest<ImageSource> = ImageSource.fetchRequest()
           fetchRequest.predicate = NSPredicate(format: "isCustom == false")
           let count = try? context.count(for: fetchRequest)
           guard count == 0 else {
               print("ℹ️ 已有推荐数据，跳过填充")
               return
           }
        print("📝 填充推荐数据（预置国内镜像源）...")

        // 定义常用镜像列表
        let commonImages: [(name: String, tag: String, attribute: String)] = [
            ("nginx", "latest", "高性能 Web 服务器"),
            ("nginx", "alpine", "高性能 Web 服务器（轻量版）"),
            ("mysql", "8.0", "关系型数据库 MySQL 8.0"),
            ("mysql", "5.7", "关系型数据库 MySQL 5.7"),
            ("redis", "alpine", "内存数据库（轻量版）"),
            ("redis", "latest", "内存数据库"),
            ("alpine", "latest", "轻量级 Linux 发行版"),
            ("busybox", "latest", "轻量级工具集"),
            ("ubuntu", "22.04", "Ubuntu 22.04 LTS"),
            ("ubuntu", "20.04", "Ubuntu 20.04 LTS"),
            ("postgres", "15", "PostgreSQL 15"),
            ("postgres", "14", "PostgreSQL 14"),
            ("mongo", "6", "MongoDB 6"),
            ("mongo", "5", "MongoDB 5"),
            ("node", "20", "Node.js 20"),
            ("node", "18", "Node.js 18"),
            ("python", "3.11", "Python 3.11"),
            ("python", "3.10", "Python 3.10"),
            ("golang", "1.21", "Go 1.21"),
            ("golang", "1.20", "Go 1.20"),
            ("rust", "latest", "Rust 最新版"),
            ("jenkins", "lts", "Jenkins LTS"),
            ("gitlab", "latest", "GitLab CE"),
        ]

        // 使用 AppConstants 中定义的镜像源
        for srcConfig in AppConstants.ImageSource.defaultSources {
            let source = createSource(name: srcConfig.name, url: srcConfig.url, type: srcConfig.type, isCustom: false)
            for (name, tag, desc) in commonImages {
                let entry = ImageEntry(context: context)
                entry.id = UUID()
                entry.name = name
                entry.tag = tag
                entry.attribute = srcConfig.name.contains("Docker") ? desc : "\(srcConfig.name) - \(desc)"
                entry.isRecommended = true
                entry.source = source
            }
        }

        do {
            try context.save()
            print("✅ 推荐数据填充成功（共 \(sources.count) 个源，每个源 \(commonImages.count) 个条目）")
            loadSources()
        } catch {
            print("❌ 填充推荐数据失败: \(error)")
        }
    }

    // 辅助：创建源（不保存，返回给调用者添加条目）
    private func createSource(name: String, url: String, type: String, isCustom: Bool) -> ImageSource {
        let source = ImageSource(context: context)
        source.id = UUID()
        source.name = name
        source.url = url
        source.type = type
        source.isCustom = isCustom
        source.order = Int16(sources.count)
        return source
    }
}

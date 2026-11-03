//
//  MachineImageManager.swift
//  AiguruContainerPanel
//
//  Machine 镜像管理服务：从远程 JSON 导入、缓存、查询。
//  与容器镜像管理分离，仅用于 Machine 创建。
//

import Foundation
import CoreData
import Combine

class MachineImageManager: ObservableObject {
    static let shared = MachineImageManager()
    private init() {
        loadImages()
        migrateLegacyDataIfNeeded()
        if images.isEmpty {
            populateRecommendedIfNeeded()
        }
    }

    private let context = PersistenceController.shared.container.viewContext

    @Published var images: [MachineImageCollection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 加载本地缓存
    func loadImages() {
        let request: NSFetchRequest<MachineImageCollection> = MachineImageCollection.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \MachineImageCollection.order, ascending: true)]
        do {
            images = try context.fetch(request)
        } catch {
            print("加载 Machine 镜像失败: \(error)")
        }
    }

    // MARK: - 数据迁移（清除所有旧版推荐镜像，确保重新填入新版数据）
    private func migrateLegacyDataIfNeeded() {
        // 1. 删掉 source 为 nil/空/http 的推荐镜像
        let badRequest: NSFetchRequest<MachineImageCollection> = MachineImageCollection.fetchRequest()
        badRequest.predicate = NSPredicate(format: "isRecommended == YES AND (source == nil OR source == '' OR source BEGINSWITH 'http')")
        if let bad = try? context.fetch(badRequest), !bad.isEmpty {
            for img in bad { context.delete(img) }
            try? context.save()
            loadImages()
        }

        // 2. 删掉 attribute 为纯文本（非 JSON）的推荐镜像 → 强制重新填入带 mirrors 的新版本
        let oldRequest: NSFetchRequest<MachineImageCollection> = MachineImageCollection.fetchRequest()
        oldRequest.predicate = NSPredicate(format: "isRecommended == YES")
        if let all = try? context.fetch(oldRequest) {
            var needsCleanup = false
            for img in all {
                if img.attribute != nil {
                    // 尝试解析为 JSON，解析失败且不为空 → 旧版纯文本
                    if let data = img.attribute?.data(using: .utf8),
                       (try? JSONDecoder().decode(ImageMirrorConfig.self, from: data)) == nil {
                        context.delete(img)
                        needsCleanup = true
                    }
                }
            }
            if needsCleanup {
                try? context.save()
                loadImages()
            }
        }
    }

    // MARK: - 填充推荐镜像（首次启动）
    func populateRecommendedIfNeeded() {
        // ✅ 检查实体是否存在
        guard let entity = NSEntityDescription.entity(forEntityName: "MachineImageCollection", in: context) else {
            print("❌ Core Data 实体 'MachineImageCollection' 不存在，请检查模型配置。")
            return
        }

        // 检查是否已有推荐镜像（迁移已在 init 中完成）
        let request: NSFetchRequest<MachineImageCollection> = MachineImageCollection.fetchRequest()
        request.predicate = NSPredicate(format: "isRecommended == YES")
        let count = try? context.count(for: request)
        guard count == 0 else { return }

        let recommended: [(name: String, tag: String, desc: String, ociRef: String, mirrors: [String])] = [
            ("Alpine", "latest", "轻量级 Linux 发行版", "\(AppConstants.Image.defaultRegistry)/alpine:latest",
             ["ghcr.io/linuxcontainers/alpine:latest"]),
            ("Ubuntu", "22.04", "Ubuntu 22.04 LTS Cloud 镜像", "\(AppConstants.Image.defaultRegistry)/ubuntu:22.04",
             ["registry.cn-hangzhou.aliyuncs.com/library/ubuntu:22.04"]),
            ("Ubuntu", "24.04", "Ubuntu 24.04 LTS Cloud 镜像", "\(AppConstants.Image.defaultRegistry)/ubuntu:24.04",
             ["registry.cn-hangzhou.aliyuncs.com/library/ubuntu:24.04"]),
            ("Debian", "12", "Debian 12 Cloud 镜像", "\(AppConstants.Image.defaultRegistry)/debian:12",
             ["registry.cn-hangzhou.aliyuncs.com/library/debian:12"]),
            ("Fedora", "40", "Fedora 40 Cloud 镜像", "\(AppConstants.Image.defaultRegistry)/fedora:40",
             ["quay.io/fedora/fedora:40"]),
            ("Arch Linux", "latest", "Arch Linux 镜像", "\(AppConstants.Image.defaultRegistry)/archlinux:latest", [])
        ]

        let encoder = JSONEncoder()
        for (index, (name, tag, desc, ociRef, mirrors)) in recommended.enumerated() {
            // ✅ 使用指定实体名创建对象
            let image = NSManagedObject(entity: entity, insertInto: context) as! MachineImageCollection
            image.id = UUID()
            image.name = name
            image.tag = tag
            image.isRecommended = true
            image.source = ociRef
            image.order = Int16(index)
            // 将描述和镜像源列表编码为 JSON 存入 attribute
            let cfg = ImageMirrorConfig(desc: desc, mirrors: mirrors.isEmpty ? nil : mirrors)
            image.attribute = (try? encoder.encode(cfg)).flatMap { String(data: $0, encoding: .utf8) }
        }

        do {
            try context.save()
            loadImages()
        } catch {
            print("填充推荐 Machine 镜像失败: \(error)")
        }
    }

    // MARK: - 从远程 JSON 导入
    func importFromRemote(url: URL, completion: @escaping (Bool, String) -> Void) {
        isLoading = true
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    completion(false, "网络错误: \(error.localizedDescription)")
                    return
                }
                guard let data = data else {
                    completion(false, "无数据返回")
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                    guard let items = json else {
                        completion(false, "数据格式无效")
                        return
                    }

                    // 清空旧数据
                    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = MachineImageCollection.fetchRequest()
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                    try self.context.execute(deleteRequest)

                    // 获取实体
                    guard let entity = NSEntityDescription.entity(forEntityName: "MachineImageCollection", in: self.context) else {
                        completion(false, "Core Data 实体 'MachineImage' 不存在")
                        return
                    }

                    for (index, item) in items.enumerated() {
                        let encoder = JSONEncoder()
                        let image = NSManagedObject(entity: entity, insertInto: self.context) as! MachineImageCollection
                        image.id = UUID()
                        image.name = item["name"] as? String ?? "Unknown"
                        image.tag = item["tag"] as? String ?? "latest"
                        image.isRecommended = item["isRecommended"] as? Bool ?? false
                        // 完整 OCI 镜像引用：优先取 ociRef/imageRef，其次取非 http 的 sourceURL
                        let name = image.name ?? ""
                        let tag = image.tag ?? "latest"
                        let ociRef = item["ociRef"] as? String
                            ?? item["imageRef"] as? String
                            ?? { () -> String? in
                                if let url = item["sourceURL"] as? String, !url.hasPrefix("http") { return url }
                                return nil
                            }()
                        image.source = ociRef ?? "\(AppConstants.Image.defaultRegistry)/\(name):\(tag)"
                        // attribute：镜像描述 + 备用镜像源 → JSON
                        let desc = item["description"] as? String
                        let mirrors = item["mirrors"] as? [String]
                        let cfg = ImageMirrorConfig(desc: desc, mirrors: mirrors)
                        image.attribute = (try? encoder.encode(cfg)).flatMap { String(data: $0, encoding: .utf8) }
                        image.order = Int16(index)
                    }

                    try self.context.save()
                    self.loadImages()
                    completion(true, "成功导入 \(items.count) 个镜像")
                } catch {
                    completion(false, "解析失败: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    /// 获取当前所有可用镜像（供 UI 使用）
    var availableImages: [MachineImageCollection] {
        return images
    }

    /// 获取推荐镜像
    var recommendedImages: [MachineImageCollection] {
        return images.filter { $0.isRecommended }
    }
}

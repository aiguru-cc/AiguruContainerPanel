//
//  MachineImage+CoreDataProperties.swift
//  AiguruContainerPanel
//
//  Machine 镜像属性扩展（与 ContainerPanel.xcdatamodel 严格对齐）
//

import Foundation
import CoreData

// MARK: - 镜像源配置（存入 attribute 字段的 JSON）
struct ImageMirrorConfig: Codable {
    var desc: String?
    var mirrors: [String]?
}

extension MachineImageCollection {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MachineImageCollection> {
        return NSFetchRequest<MachineImageCollection>(entityName: "MachineImageCollection")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var tag: String?
    @NSManaged public var isRecommended: Bool
    @NSManaged public var order: Int16
    @NSManaged public var attribute: String?
    @NSManaged public var source: String?
    @NSManaged public var createdAt: Date?

    /// 从 name + tag 计算显示名称，不持久化到 Core Data。
    @objc var displayName: String? {
        if let name = name, let tag = tag { return "\(name):\(tag)" }
        if let name = name { return name }
        return nil
    }

    /// 解析 attribute 中的镜像配置 JSON；兼容旧版纯文本描述。
    var mirrorConfig: ImageMirrorConfig {
        if let data = attribute?.data(using: .utf8),
           let cfg = try? JSONDecoder().decode(ImageMirrorConfig.self, from: data),
           (cfg.desc != nil || cfg.mirrors != nil) {
            return cfg
        }
        return ImageMirrorConfig(desc: attribute, mirrors: nil)
    }

    /// 描述文本（优先取 JSON 中的 desc，其次取旧版 attribute 原文）
    var imageDescription: String? {
        mirrorConfig.desc ?? attribute
    }

    /// 所有可用镜像源（source + JSON mirrors，去重）。
    var allMirrors: [String] {
        var seen: Set<String> = []
        var result: [String] = []

        func add(_ ref: String) {
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("http://"), !trimmed.hasPrefix("https://") else { return }
            if seen.insert(trimmed).inserted { result.append(trimmed) }
        }

        // 主 source
        if let s = source { add(s) }
        // JSON 中的 mirrors
        for m in (mirrorConfig.mirrors ?? []) { add(m) }
        // 兜底：name + tag → docker.io
        if result.isEmpty {
            let n = (self.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let t = (self.tag ?? "latest").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append("\(AppConstants.Image.defaultRegistry)/\(n):\(t.isEmpty ? "latest" : t)")
        }
        return result
    }

    /// 默认镜像引用（第一个可用镜像源）。
    var fullImageReference: String {
        allMirrors.first ?? "\(name ?? ""):\(tag ?? "latest")"
    }

}

extension MachineImageCollection : Identifiable {

}

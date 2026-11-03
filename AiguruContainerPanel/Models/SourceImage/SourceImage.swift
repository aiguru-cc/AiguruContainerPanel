//
//  SourceImage.swift
//  AiguruContainerPanel
//
//  镜像数据模型，适配 `container image list --format json` 输出。
//

import Foundation

struct SourceImage: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let name: String          // 完整镜像名，如 docker.1ms.run/alpine:latest
    let repository: String    // 仓库名，如 docker.1ms.run/alpine
    let tag: String           // 标签，如 latest
    let digest: String?
    let createdAt: String?
    let size: Int64?

    var displayName: String {
        return name
    }

    var createdDate: Date? {
        guard let createdAt = createdAt else { return nil }
        return ISO8601DateFormatter().date(from: createdAt)
    }

    var sizeString: String {
        guard let size = size else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case variants
    }

    // 自定义解码
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id
        id = try container.decode(String.self, forKey: .id)

        // configuration
        let config = try container.decode(Configuration.self, forKey: .configuration)
        name = config.name
        // 解析 repository 和 tag
        if let lastColon = name.lastIndex(of: ":") {
            repository = String(name[..<lastColon])
            tag = String(name[name.index(after: lastColon)...])
        } else {
            repository = name
            tag = "latest"
        }
        digest = config.descriptor?.digest
        createdAt = config.creationDate

        // 解析 size (取第一个 variant 的 size)
        let variants = try container.decode([Variant].self, forKey: .variants)
        size = variants.first?.size
    }

    // 辅助结构
    struct Configuration: Decodable {
        let creationDate: String?
        let name: String
        let descriptor: Descriptor?
    }

    struct Descriptor: Decodable {
        let digest: String?
    }

    struct Variant: Decodable {
        let size: Int64?
    }
}

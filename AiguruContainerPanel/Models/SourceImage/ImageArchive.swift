//
//  ImageArchive.swift
//  AiguruContainerPanel
//
//  镜像归档模型 — 记录一次 image save 生成的 OCI tar 与元数据。
//

import Foundation

/// 镜像归档（一次 image save 产生的 tar + 元数据）
struct ImageArchive: Identifiable, Codable, Equatable {
    var id = UUID()
    /// 镜像引用，如 docker.io/library/ubuntu:24.04
    let imageName: String
    /// 归档创建时间
    let timestamp: Date
    /// tar 归档文件路径
    let archivePath: String
    /// 归档大小（字节）
    let sizeBytes: Int64
    /// 用户备注
    var note: String?

    var sizeString: String {
        let b = Double(sizeBytes)
        if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(sizeBytes) B"
    }

    var archiveName: String {
        (archivePath as NSString).lastPathComponent
    }
}

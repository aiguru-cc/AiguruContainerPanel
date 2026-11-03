//
//  ContainerStats.swift
//  AiguruContainerPanel
//
//  容器统计信息模型，对应 `container stats` 输出。
//

import Foundation

/// 容器统计信息
struct ContainerStats {
    let containerID: String
    let name: String
    let cpuPercent: String   // "0.57%"
    let memUsage: String
    let memLimit: String
    let memPercent: Double
    let netIO: String
    let blockIO: String
    let pids: Int
}

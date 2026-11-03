//
//  VolumeMapping.swift
//  AiguruContainerPanel
//
//  卷挂载映射模型。
//

import Foundation

/// 卷挂载映射（用于 UI 绑定，支持修改）
struct VolumeMapping: Identifiable, Hashable, Equatable {
    let id = UUID()
    var source: String = ""
    var destination: String = ""
}

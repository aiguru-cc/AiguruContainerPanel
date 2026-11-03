//
//  Plugin.swift
//  AiguruContainerPanel
//
//  插件开发协议，供第三方开发者实现自定义插件。
//  此协议定义插件必须提供的元数据和执行方法。
//

import Foundation

/// 插件协议，所有用户开发的插件必须遵循此协议。
public protocol Plugin {
    /// 插件名称（唯一标识）
    var name: String { get }
    /// 插件版本
    var version: String { get }
    /// 插件描述
    var description: String { get }
    /// 插件作者
    var author: String { get }
    /// 插件执行入口，当用户触发插件时调用
    func execute(with parameters: [String: Any]?) throws
    /// 插件元数据（默认实现）
    func metadata() -> [String: Any]
}

// 默认实现
extension Plugin {
    public func metadata() -> [String: Any] {
        return [
            "name": name,
            "version": version,
            "description": description,
            "author": author
        ]
    }
}

//
//  AppSettings.swift
//  AiguruContainerPanel
//
//  全局应用设置，存储用户偏好，通过 EnvironmentObject 注入。
//

import Foundation
import Combine

class AppSettings: ObservableObject {
    @Published var executionMode: ExecutionMode = .stream   // 默认流式实时
    @Published var selectedTab: MainView.Tab = .containers
}

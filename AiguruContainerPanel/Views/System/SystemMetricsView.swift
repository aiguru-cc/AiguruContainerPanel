//
//  SystemMetricsViewModel.swift
//  AiguruContainerPanel
//
//  系统指标视图模型，负责加载系统指标和容器环境变量。
//  所有存储属性必须在 init 完成前初始化，因此将数据加载移到单独的方法。
//

import Foundation
import Combine

class SystemMetricsViewModel: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    @Published var diskUsage: Double = 0
    @Published var containerEnv: [String: String] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // 初始化时不调用加载方法，由外部（如 onAppear）触发
    init() {
        // 不在这里调用 loadSystemMetrics 或 loadContainerEnv
        // 定时器也不能在此时启动，因为属性尚未完全准备？实际上属性已初始化，但为了安全，可以在外部调用 startTimer
        // 我们改为提供一个 startMonitoring() 方法
    }

    /// 开始监控（在视图出现时调用）
    func startMonitoring() {
        loadSystemMetrics()
        loadContainerEnv()
        // 启动定时器
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.loadSystemMetrics()
        }
    }

    /// 停止监控
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// 加载系统指标（模拟）
    func loadSystemMetrics() {
        isLoading = true
        // 模拟网络/系统调用
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let cpu = Double.random(in: 10...80)
            let memory = Double.random(in: 20...90)
            let disk = Double.random(in: 30...70)
            DispatchQueue.main.async {
                self.cpuUsage = cpu
                self.memoryUsage = memory
                self.diskUsage = disk
                self.isLoading = false
            }
        }
    }

    /// 加载容器环境变量（模拟）
    func loadContainerEnv() {
        // 实际可从 container inspect 获取
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let env = [
                "PATH": "/usr/local/bin:/usr/bin:/bin",
                "HOME": "/root",
                "TERM": "xterm",
                "CONTAINER_RUNTIME": "Apple Container（版本由当前环境动态探测）"
            ]
            DispatchQueue.main.async {
                self.containerEnv = env
            }
        }
    }

    deinit {
        stopMonitoring()
    }
}

//
//  TaskManager.swift
//  AiguruContainerPanel
//
//  全局任务管理器，统一管理所有耗时操作（容器、镜像、Machine等）。
//  提供进度、命令、输出、状态反馈，与 CommandProgressView 集成。
//

import Foundation
import Combine

nonisolated enum TaskStatus {
    case idle
    case running
    case success
    case failure
}

class TaskManager: ObservableObject {
    static let shared = TaskManager()
    private init() {}

    @Published var status: TaskStatus = .idle
    @Published var currentCommand: String = ""
    @Published var currentModule: String = ""
    @Published var currentOperation: String = ""
    @Published var progress: Double = 0.0
    @Published var liveOutput: [String] = []
    @Published var showTaskPanel: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isProgressIndeterminate: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var hasTimeout: Bool = false

    private var countdownTimer: Timer?
    private var taskStartTime: Date = Date()
    private var commandTimeout: TimeInterval = 0

    // MARK: - 开始任务
    func startTask(module: String, operation: String, command: String, timeout: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.currentModule = module
            self.currentOperation = operation
            self.currentCommand = command
            self.progress = 0.0
            self.liveOutput = []
            self.status = .running
            self.showTaskPanel = true
            self.errorMessage = nil
            self.isProgressIndeterminate = true
            // 超时倒计时
            self.countdownTimer?.invalidate()
            if let t = timeout, t > 0 {
                self.hasTimeout = true
                self.commandTimeout = t
                self.taskStartTime = Date()
                self.remainingSeconds = Int(t)
                self.countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self, self.status == .running else { return }
                    let elapsed = Date().timeIntervalSince(self.taskStartTime)
                    let remaining = max(0, Int(self.commandTimeout - elapsed))
                    DispatchQueue.main.async { self.remainingSeconds = remaining }
                }
            } else {
                self.hasTimeout = false
                self.remainingSeconds = 0
            }
        }
    }

    // MARK: - 更新进度
    func updateProgress(_ value: Double) {
        DispatchQueue.main.async {
            self.progress = min(max(value, 0.0), 1.0)
            self.isProgressIndeterminate = false
        }
    }

    func setIndeterminate(_ indeterminate: Bool) {
        DispatchQueue.main.async {
            self.isProgressIndeterminate = indeterminate
        }
    }

    // MARK: - 追加输出行
    func appendOutput(_ line: String) {
        DispatchQueue.main.async {
            self.liveOutput.append(line)
        }
    }

    // MARK: - 完成任务
    func finishTask(success: Bool, message: String? = nil) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        DispatchQueue.main.async {
            self.status = success ? .success : .failure
            self.progress = 1.0
            if let msg = message {
                self.liveOutput.append(msg)
            }
            if !success {
                self.errorMessage = message ?? "操作失败"
            }
            // 3 秒后自动隐藏面板
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Time.taskPanelDismissDelay) {
                self.showTaskPanel = false
                self.status = .idle
                self.currentCommand = ""
                self.progress = 0.0
                self.liveOutput = []
                self.errorMessage = nil
                self.isProgressIndeterminate = false
            }
        }
    }

    // MARK: - 手动关闭
    func dismissPanel() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        DispatchQueue.main.async {
            self.showTaskPanel = false
            self.status = .idle
            self.currentCommand = ""
            self.progress = 0.0
            self.liveOutput = []
            self.errorMessage = nil
            self.isProgressIndeterminate = false
        }
    }
}

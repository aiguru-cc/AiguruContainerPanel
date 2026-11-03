//
//  TostManager.swift
//  AiguruContainerPanel
//
//  Created by samlu on 2026/8/3.
//

import SwiftUI
import Combine

enum ToastType {
    case success
    case error
    case info
    
    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}

class ToastManager: ObservableObject {
    static let shared = ToastManager()
    private init() {}
    
    @Published var isPresenting = false
    @Published var message = ""
    @Published var type: ToastType = .info
    
    private var dismissTask: Task<Void, Never>?
    
    func show(_ message: String, type: ToastType = .info, duration: Double = 3.0) {
        dismissTask?.cancel()
        
        self.message = message
        self.type = type
        withAnimation(.easeIn(duration: 0.3)) {
            self.isPresenting = true
        }
        
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isPresenting = false
                }
            }
        }
    }
    
    func showSuccess(_ message: String, duration: Double = 3.0) {
        show(message, type: .success, duration: duration)
    }
    
    func showError(_ message: String, duration: Double = 3.0) {
        show(message, type: .error, duration: duration)
    }
    
    func showInfo(_ message: String, duration: Double = 3.0) {
        show(message, type: .info, duration: duration)
    }
    
    func hide() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            isPresenting = false
        }
    }
}

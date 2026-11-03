//
//  ToastView.swift
//  Aiguru Container Control Panel
//
//  Created by samlu on 2026/7/3.
//

import SwiftUI

struct ToastView: View {
    let message: String
    let type: ToastType
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.iconName)
                .foregroundColor(type.color)
                .font(.title3)
            Text(message)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(type.color.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

struct ToastModifier: ViewModifier {
    @ObservedObject var toastManager: ToastManager   // 观察单例

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if toastManager.isPresenting {
                    ToastView(message: toastManager.message, type: toastManager.type)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 20)
                        .zIndex(100)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: toastManager.isPresenting)
    }
}

extension View {
    func toast() -> some View {
        modifier(ToastModifier(toastManager: ToastManager.shared))
    }
}

import SwiftUI
import AppKit

/// Applied separately to the window and presented sheets so neither surface
/// remains interactive while a scan, connection or its analysis is running.
struct GlobalLoading: ViewModifier {
    @EnvironmentObject var model: AppModel
    @State private var startedAt = Date()
    func body(content: Content) -> some View {
        content
            .disabled(model.busy)
            .allowsHitTesting(!model.busy)
            .accessibilityHidden(model.busy)
            .overlay {
                if model.busy {
                    ZStack {
                        Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture { }
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text("正在处理，请稍候").font(.headline)
                            Text(model.status).font(.callout).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("已等待 \(max(0, Int(context.date.timeIntervalSince(startedAt)))) 秒")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("完成后将自动恢复操作").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(28).frame(maxWidth: 440)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(24)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("global-loading")
                    }
                    .onAppear { startedAt = Date(); NSApp.keyWindow?.makeFirstResponder(nil) }
                }
            }
            .background(WindowLoadingLock(locked: model.busy))
    }
}

private struct WindowLoadingLock: NSViewRepresentable {
    let locked: Bool
    func makeNSView(context: Context) -> LockView { LockView() }
    func updateNSView(_ view: LockView, context: Context) {
        view.locked = locked
        view.apply()
    }
    static func dismantleNSView(_ view: LockView, coordinator: ()) {
        view.locked = false
        view.apply()
    }
    final class LockView: NSView {
        var locked = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(button)?.isEnabled = !locked
            }
        }
    }
}

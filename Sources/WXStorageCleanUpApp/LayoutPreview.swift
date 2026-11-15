import SwiftUI
import AppKit
import WXStorageCleanUpCore

private final class LayoutCheckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Explicit developer entry point. Always uses generated demo data, never a saved account.
@MainActor enum LayoutPreview {
    static func run(output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let demo = try DemoFactory.createMultiple(parent: output.appendingPathComponent("fixtures"),
            nameSuffix: " · 产品研发设计与运营联合讨论群 / VeryLongConversationNameForLayout", includeUnassigned: true)
        let inventory = try Scanner.scan(root: URL(fileURLWithPath: demo.root.path, isDirectory: true))
        let indexes = try inventory.accounts.map { account in
            try IndexReader.load(snapshot: demo.snapshots[account.id]!, account: account, inventory: inventory)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let imageFixture = output.appendingPathComponent("preview-image.png")
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            for x in 0..<64 { for y in 0..<48 { bitmap.setColor(NSColor(deviceRed: 0.0, green: 0.6, blue: 0.7, alpha: 1), atX: x, y: y) } }
            if let bytes = bitmap.representation(using: .png, properties: [:]) { try bytes.write(to: imageFixture) }
        }
        let cases: [(String, CGFloat, CGFloat, Bool, Bool, String)] = [
            ("image-gallery-900", 900, 650, true, false, ""),
            ("loading-titled-1080", 1080, 700, true, true, ""),
            ("loading-connection-640", 640, 660, true, false, ""),
            ("welcome-1080", 1080, 700, false, false, ""),
            ("initial-1080", 1080, 700, true, false, ""),
            ("initial-1240", 1240, 800, true, false, ""),
            ("selected-1080", 1080, 700, true, true, ""),
            ("selected-1440", 1440, 900, true, true, ""),
            ("chat-interaction-1080", 1080, 700, true, false, ""),
            ("anonymous-1080", 1080, 700, false, false, ""),
            ("empty-search-1080", 1080, 700, true, false, "no-match-demo"),
            ("unassigned-1080", 1080, 700, true, false, ""),
            ("unassigned-empty-1080", 1080, 700, true, false, "no-match-demo"),
            ("unassigned-1240", 1240, 800, true, false, ""),
            ("unassigned-1440", 1440, 900, true, false, ""),
            ("unassigned-titled-1080", 1080, 700, true, false, ""),
            ("unassigned-titled-1240", 1240, 800, true, false, ""),
            ("unassigned-long-notice-1080", 1080, 700, true, false, ""),
            ("unassigned-shared-interaction-1080", 1080, 700, true, false, "共享演示附件"),
            ("navigation-roundtrip-1080", 1080, 700, true, false, ""),
            ("after-cleanup-next-1080", 1080, 700, true, true, ""),
            ("after-cleanup-empty-1080", 1080, 700, true, true, "")
        ]
        var results = [[String: Any]]()
        for (name, width, height, connected, selected, query) in cases {
            let model = AppModel(cleanup: CleanupService(journalDirectory: output.appendingPathComponent("fixture-journal")))
            let isUnassigned = name.hasPrefix("unassigned") || name.hasPrefix("navigation")
            let afterCleanup = name.hasPrefix("after-cleanup")
            if afterCleanup {
                // Exercise the same model/hosting view through an actual fixture cleanup and refresh.
                model.scan(demo.root, demo: true)
                try waitUntilIdle(model)
            }
            model.isDemo = true; model.inventory = inventory
            model.indexes = connected ? Dictionary(uniqueKeysWithValues: indexes.map { ($0.accountID, $0) }) : [:]
            if afterCleanup {
                model.inventory = try Scanner.scan(root: URL(fileURLWithPath: demo.root.path, isDirectory: true))
            }
            model.analysis = Analysis(inventory: model.inventory!, indexes: connected ? indexes : [])
            model.selectedAccount = inventory.accounts.first?.id ?? ""
            model.page = isUnassigned ? .unassigned : .chats
            if isUnassigned { model.unassignedSearch = query }
            else { model.search = query }
            model.notice = "演示模式：所有清理和恢复只操作独立演示目录，不访问真实微信资料。"
            if name.contains("long-notice") { model.notice = String(repeating: "演示提示：已完成附件整理，可在操作记录中查看结果并恢复。", count: 4) }
            if selected { model.selectedConversation = model.visibleConversations.first?.id }
            if afterCleanup {
                model.selectedConversation = model.visibleConversations.first { $0.conversation.internalID == "wxid_demo_mia" }?.id
            }
            if isUnassigned { model.checkedUnassigned = Set(model.visibleUnassigned.map(\.id)) }
            if name.contains("shared-interaction") { model.checkedUnassigned = [] }
            if name.hasPrefix("welcome") {
                model.inventory = nil; model.analysis = nil; model.isDemo = false; model.notice = nil; model.page = .overview
            }
            if name.hasPrefix("loading") {
                model.busy = true
                model.status = "正在扫描本机微信并建立账号索引，请稍候…"
            }
            // Include the actual application shell: navigation, header, banners and footer.
            let contentWidth = width, contentHeight = height
            let surface = name == "image-gallery-900" ? AnyView(ChatImagesView(root: output, paths: ["preview-image.png"])) : name == "loading-connection-640" ? AnyView(ConnectionView()) : AnyView(MainView())
            let view = surface.environmentObject(model).tint(Color.accentGreen)
                .frame(width: contentWidth, height: contentHeight)
                .background(Color.canvas)
            let hosting = NSHostingView(rootView: view)
            let titled = name.contains("titled")
            let window = LayoutCheckWindow(contentRect: NSRect(x: -10000, y: -10000, width: contentWidth, height: contentHeight),
                styleMask: titled ? [.titled, .closable, .resizable] : [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
            window.makeKeyAndOrderFront(nil)
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            if name == "after-cleanup-next-1080" {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                model.previewCurrentConversation()
                try waitUntilIdle(model)
                guard model.plan?.candidates.isEmpty == false else { throw StorageError.invalid("演示聊天没有生成清理计划。") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let trash = output.appendingPathComponent("fixture-trash")
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                model.executePlan(trash: { source in
                    let destination = trash.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.moveItem(at: source, to: destination); return destination
                })
                try waitUntilIdle(model)
                guard model.cleanupCompletion != nil else { throw StorageError.invalid("清理后没有发出废纸篓提示。") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let alertView = window.attachedSheet?.contentView else { throw StorageError.invalid("没有显示清理完成弹窗。") }
                let labels = nativeLabels(alertView)
                guard labels.contains(where: { $0.contains("空间尚未释放") }),
                      labels.contains(where: { $0.contains("在 Finder 查看本次项目") }),
                      labels.contains(where: { $0.contains("清空废纸篓") }) else {
                    throw StorageError.invalid("清理完成弹窗缺少必要提示：\(labels)")
                }
                try JSONSerialization.data(withJSONObject: ["visible": true, "labels": labels], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("cleanup-trash-reminder.json"))
                guard let dismiss = nativeButton("知道了", in: alertView) else { throw StorageError.invalid("清理完成提示没有关闭按钮。") }
                dismiss.performClick(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard model.cleanupCompletion == nil else { throw StorageError.invalid("清理完成提示无法关闭。") }
                model.selectedConversation = model.visibleConversations.first { $0.conversation.internalID == "filehelper" }?.id
                guard model.canCleanCurrentConversation else { throw StorageError.invalid("清理后切换聊天无法再次清理。") }
                model.checkedMessages = Set(model.visibleMessages.filter { !$0.filePaths.isEmpty }.map(\.id))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            if name.contains("shared-interaction") {
                let shared = model.visibleUnassigned.first { $0.identity.links > 1 }
                guard let shared else { throw StorageError.invalid("缺少共享附件演示文件。") }
                try click(NSPoint(x: 260, y: height - 324), in: window)
                guard model.checkedUnassigned.contains(shared.id) else { throw StorageError.invalid("共享附件无法从界面勾选。") }
                model.previewUnassigned()
                try waitUntilIdle(model)
                guard model.plan?.candidates.count == 1, model.plan?.sharedPathCount == 1 else {
                    throw StorageError.invalid("共享附件未进入清理计划。")
                }
                model.plan = nil
            }
            if name.hasPrefix("chat-interaction") {
                let first = model.visibleConversations[0].id
                try click(NSPoint(x: 365, y: height - 292), in: window)
                guard model.selectedConversation == first else { throw StorageError.invalid("聊天行点击未生效。") }
            }
            hosting.layoutSubtreeIfNeeded()
            guard abs(hosting.bounds.width - contentWidth) < 1, abs(hosting.bounds.height - contentHeight) < 1 else {
                throw StorageError.invalid("布局检查窗口尺寸与目标尺寸不一致。")
            }
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw StorageError.invalid("无法创建布局检查图像。")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw StorageError.invalid("无法保存布局检查图像。")
            }
            try data.write(to: output.appendingPathComponent(name + ".png"))
            if name.hasPrefix("navigation") {
                try click(NSPoint(x: 280, y: height - 34), in: window)
                guard model.page == .overview else { throw StorageError.invalid("返回空间概览按钮未生效。") }
                try click(NSPoint(x: 100, y: height - 160), in: window)
                guard model.page == .chats else { throw StorageError.invalid("侧栏无法切换到聊天。") }
                try click(NSPoint(x: 100, y: height - 205), in: window)
                guard model.page == .unassigned else { throw StorageError.invalid("侧栏无法切换到其他文件。") }
            }
            if name == "loading-titled-1080" {
                guard window.standardWindowButton(.closeButton)?.isEnabled == false else {
                    throw StorageError.invalid("加载时窗口关闭按钮未锁定。")
                }
                try click(NSPoint(x: 100, y: height - 115), in: window)
                guard model.page == .chats else { throw StorageError.invalid("加载时仍可切换侧栏。") }
                model.busy = false
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard window.standardWindowButton(.closeButton)?.isEnabled == true else {
                    throw StorageError.invalid("加载完成后窗口关闭按钮未恢复。")
                }
                try click(NSPoint(x: 100, y: height - 115), in: window)
                guard model.page == .overview else { throw StorageError.invalid("加载完成后侧栏未恢复。") }
            }
            results.append(["case": name, "width": width, "height": height,
                "fullWindow": true, "navigationInteractionChecked": name.hasPrefix("navigation"), "returnShown": isUnassigned,
                "standardTitleBar": titled,
                "chatInteractionChecked": name.hasPrefix("chat-interaction"),
                "sharedSelectionChecked": name.contains("shared-interaction"),
                "contentWidth": contentWidth, "contentHeight": contentHeight,
                "conversations": model.visibleConversations.count, "selected": model.currentConversation != nil,
                "canCleanCurrentConversation": model.canCleanCurrentConversation,
                "unassignedFiles": model.visibleUnassigned.count,
                "imageWidth": bitmap.pixelsWide, "imageHeight": bitmap.pixelsHigh])
            window.orderOut(nil); window.close()
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"))
        print("已生成 \(results.count) 个演示数据布局检查：\(output.path)")
    }
    private static func nativeLabels(_ view: NSView) -> [String] {
        var labels = [String]()
        if let text = view as? NSTextField { labels.append(text.stringValue) }
        if let button = view as? NSButton { labels.append(button.title) }
        for child in view.subviews { labels.append(contentsOf: nativeLabels(child)) }
        return labels
    }
    private static func nativeButton(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let button = nativeButton(title, in: child) { return button }
        }
        return nil
    }
    private static func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw StorageError.invalid("无法创建窗口交互检查事件。")
            }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.05)
        while let event = NSApplication.shared.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    private static func waitUntilIdle(_ model: AppModel) throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if model.busy { throw StorageError.invalid("演示操作未在预期时间内完成。") }
        if let error = model.errorMessage { throw StorageError.invalid(error) }
    }
}

import SwiftUI
import AppKit
import WeChatStorageCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 11) {
                    AppBrandIcon(size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("微空间").font(.system(size: 20, weight: .semibold))
                        Text("微信存储管理").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 17).padding(.top, 27)
                VStack(spacing: 6) {
                    ForEach(Page.allCases) { page in
                        Button { model.page = page } label: {
                            Label(page.rawValue, systemImage: page.icon)
                                .font(.system(size: 14, weight: model.page == page ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 11)
                                .background(model.page == page ? Color.accentGreen.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("navigation-" + page.icon)
                            .accessibilityValue(model.page == page ? "当前页面" : "")
                    }
                }.padding(.horizontal, 12).accessibilityIdentifier("main-navigation")
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    Label("数据只在本机处理", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Text(model.appVersion).font(.caption2).foregroundStyle(.tertiary)
                }.padding(18)
            }
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Color.accentGreen.opacity(0.04).background(Color.canvas))
            Divider()
            VStack(spacing: 0) {
                header.fixedSize(horizontal: false, vertical: true)
                if model.isDemo {
                    banner("演示模式 · 仅操作独立的演示文件", icon: "sparkles", color: .orange)
                }
                if let notice = model.notice { banner(notice, icon: "info.circle", color: .accentGreen) }
                GeometryReader { geometry in
                    pageContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small); Button("取消") { model.cancel() }.buttonStyle(.link) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let inventory = model.inventory {
                        Text(inventory.scannedAt, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }.padding(.horizontal, 22).padding(.vertical, 12)
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showingConnection) { ConnectionView() }
        .sheet(item: $model.plan) { plan in PlanView(plan: plan) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("附件已移入废纸篓，空间尚未释放", isPresented: Binding(
            get: { model.cleanupCompletion != nil },
            set: { if !$0 { model.cleanupCompletion = nil } }
        ), presenting: model.cleanupCompletion) { record in
            Button("在 Finder 查看本次项目") {
                model.revealTrash(record)
                model.cleanupCompletion = nil
            }
            Button("知道了", role: .cancel) { model.cleanupCompletion = nil }
        } message: { _ in Text(model.cleanupCompletionMessage) }
    }
    @ViewBuilder private var pageContent: some View {
        if model.page == .history { HistoryView() }
        else if model.inventory == nil { WelcomeView() }
        else {
            switch model.page {
            case .overview: OverviewView()
            case .chats: ChatsView()
            case .unassigned: UnassignedAttachmentsView()
            case .history: HistoryView()
            }
        }
    }
    private var header: some View {
      VStack(alignment: .leading, spacing: 12) {
        if model.page == .unassigned {
            Button { model.page = .overview } label: {
                Label("返回空间概览", systemImage: "chevron.left")
            }.buttonStyle(.link).keyboardShortcut("[", modifiers: .command)
                .accessibilityIdentifier("return-to-overview")
        }
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page.rawValue).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                    .accessibilityIdentifier("page-title")
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let inventory = model.inventory, !inventory.accounts.isEmpty {
                Picker("账号", selection: $model.selectedAccount) {
                    ForEach(inventory.accounts) { account in Text(model.accountLabel(account)).tag(account.id) }
                }.labelsHidden().frame(width: 230).disabled(model.busy)
            }
            Button { model.exportAnalysis() } label: { Image(systemName: "square.and.arrow.up") }
                .help("导出空间分析，文件包含聊天名称，请自行保管")
                .disabled(model.analysis == nil)
            Button { model.refresh() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                .disabled(model.busy || model.inventory == nil)
        }
      }.padding(26).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("page-header")
    }
    private var subtitle: String {
        switch model.page {
        case .overview: "看清空间去向，再决定整理哪些内容"
        case .chats: "按聊天归集附件，也可以进入聊天选择具体消息"
        case .unassigned: "查看尚未识别聊天归属的本地附件，按文件选择整理"
        case .history: "查看移入废纸篓的项目，恢复仍可找回的附件"
        }
    }
    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon); Text(text).fixedSize(horizontal: false, vertical: true); Spacer()
        }.font(.caption).foregroundStyle(color).padding(.horizontal, 24).padding(.vertical, 10).background(color.opacity(0.07))
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            AppBrandIcon(size: 104)
            Text("给重要的聊天，留出空间").font(.system(size: 30, weight: .semibold))
            Text("先扫描微信占用，再按聊天和消息整理附件。\n所有处理都在本机进行，文字与聊天数据库保持保留。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(6)
            VStack(spacing: 16) {
                Button { model.scanDefault() } label: {
                    Label("扫描本机微信", systemImage: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(minWidth: 240).padding(.horizontal, 24).padding(.vertical, 16)
                }.buttonStyle(PrimaryScanButtonStyle()).keyboardShortcut(.defaultAction)
                Button("选择目录…") { model.pickRoot() }
                    .buttonStyle(.link).font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 6).disabled(model.busy)
            Text("支持微信 4.x 数据布局 · macOS \(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0") 及以上")
                .font(.caption).foregroundStyle(.tertiary)
        }.padding(40)
    }
}

private struct AppBrandIcon: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "externaldrive.fill").resizable().scaledToFit().foregroundStyle(Color.accentGreen).padding(size * 0.12)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct PrimaryScanButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(Color.accentGreen.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let note: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(title).font(.callout).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(Color.accentGreen) }
            Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).contentTransition(.numericText())
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.05)))
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    private let colors: [Color] = [.accentGreen, .blue, .orange, .purple, .gray]
    var body: some View {
        ScrollView {
            if let analysis = model.analysis {
                let inventory = analysis.inventory
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 14) {
                        MetricCard(title: "微信占用估算", value: SizeText.format(inventory.allocatedBytes + inventory.applicationAllocatedBytes),
                            note: "扫描范围内数据 + 检测到的应用本体；APFS 共享块可能影响数值", icon: "internaldrive")
                        MetricCard(title: "聊天附件", value: SizeText.format(inventory.files.filter { $0.category == .attachment }.reduce(0) { $0 + $1.identity.bytes }),
                            note: "逻辑大小 · 图片、视频、文件等，包含尚未归属的附件", icon: "photo.on.rectangle")
                        MetricCard(title: "会话目录", value: "\(analysis.conversations.count)",
                            note: "\(analysis.conversations.filter { $0.conversation.named }.count) 个已识别名称，\(analysis.messages.count) 条索引消息", icon: "bubble.left.and.bubble.right")
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("当前账号未归属附件 · \(SizeText.format(model.accountUnassigned.reduce(0) { $0 + $1.identity.bytes }))").font(.headline)
                            Text("\(model.accountUnassigned.count) 个文件尚未归集到聊天。可查看位置并按文件选择清理。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看未归属附件") { model.page = .unassigned }.buttonStyle(.bordered)
                    }.padding(22).background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Text("空间分布").font(.headline); Spacer(); Text("按路径逻辑大小").font(.caption).foregroundStyle(.secondary) }
                        GeometryReader { geometry in
                            HStack(spacing: 3) {
                                ForEach(Array(FileCategory.allCases.enumerated()), id: \.element) { index, category in
                                    let bytes = categoryBytes(category, inventory)
                                    if bytes > 0 {
                                        RoundedRectangle(cornerRadius: 3).fill(colors[index])
                                            .frame(width: max(2, (geometry.size.width - 12) * Double(bytes) / Double(max(1, inventory.logicalBytes))))
                                    }
                                }
                            }
                        }.frame(height: 17)
                        ForEach(Array(FileCategory.allCases.enumerated()), id: \.element) { index, category in
                            HStack {
                                Circle().fill(colors[index]).frame(width: 8, height: 8)
                                Text(category.rawValue); Spacer()
                                Text(SizeText.format(categoryBytes(category, inventory))).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }.padding(23).background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                    HStack(alignment: .top, spacing: 14) {
                        MetricCard(title: "未分配到具体聊天", value: SizeText.format(analysis.unattributedBytes),
                            note: "包括数据库、应用公共数据和未归属附件，不按聊天均摊", icon: "tray")
                        MetricCard(title: "应用本体", value: SizeText.format(inventory.applicationBytes),
                            note: inventory.applicationScanComplete ? "逻辑大小 · 不参与附件清理" : "应用扫描不完整", icon: "app.badge")
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.indexes.isEmpty ? "连接索引，看到真实聊天和消息" : "从最占空间的聊天开始整理").font(.headline)
                            Text("只有精确对应到消息的附件才会进入清理计划。聊天名相同也会按内部标识区分。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.indexes.isEmpty ? "连接聊天索引" : "查看聊天") {
                            if model.indexes.isEmpty { model.showingConnection = true } else { model.page = .chats }
                        }.buttonStyle(.borderedProminent)
                    }.padding(22).background(Color.accentGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    if !model.warnings.isEmpty {
                        DisclosureGroup("扫描与索引说明（\(model.warnings.count)）") {
                            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                    Text("扫描范围：\(inventory.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("未跟随 \(inventory.skippedLinks) 个链接项目；\(inventory.blockedAccountIDs.count) 个账号因内部链接而锁定清理。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("数据逻辑大小 \(SizeText.format(inventory.logicalBytes)) · 已分配空间估算 \(SizeText.format(inventory.allocatedBytes)) · 硬链接按文件身份去重，不能把占用估算视为保证可回收空间。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).padding(.bottom, 26)
            }
        }
    }
    private func categoryBytes(_ category: FileCategory, _ inventory: Inventory) -> Int64 {
        inventory.files.filter { $0.category == category }.reduce(0) { $0 + $1.identity.bytes }
    }
}

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var preferredListWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @FocusState private var listIsFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 9)
            let maximum = max(0, min(460, available - min(360, available * 0.55)))
            let minimum = min(300, maximum)
            let width = min(maximum, max(minimum, preferredListWidth ?? available * 0.42))
            HStack(spacing: 0) {
                conversationList
                    .frame(width: width, height: geometry.size.height)
                    .clipped()
                Rectangle().fill(Color(nsColor: .separatorColor))
                    .frame(width: 1).frame(width: 9, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        preferredListWidth = min(maximum, max(minimum, (dragStartWidth ?? width) + value.translation.width))
                    }.onEnded { _ in dragStartWidth = nil })
                    .onTapGesture(count: 2) { preferredListWidth = nil }
                    .accessibilityElement()
                    .accessibilityLabel("聊天列表宽度")
                    .accessibilityAdjustableAction { direction in
                        let delta: CGFloat = direction == .increment ? 24 : -24
                        preferredListWidth = min(maximum, max(minimum, width + delta))
                    }
                    .help("拖动调整聊天列表宽度，双击恢复默认")
                ConversationDetailView()
                    .frame(width: max(0, available - width), height: geometry.size.height)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索聊天名或标识", text: $model.search).textFieldStyle(.plain)
            }.padding(12).background(Color.card, in: RoundedRectangle(cornerRadius: 8)).padding(14)
            HStack {
                Button("选择当前结果") { model.checkedConversations = Set(model.visibleConversations.filter { $0.conversation.named }.map(\.id)) }
                    .buttonStyle(.link)
                Spacer()
                Text("按附件大小排序").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 15).padding(.bottom, 8)
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleConversations) { usage in
                        ConversationListRow(usage: usage, checked: Binding(get: { model.checkedConversations.contains(usage.id) }, set: {
                                if $0 { model.checkedConversations.insert(usage.id) } else { model.checkedConversations.remove(usage.id) }
                            }), onSelect: { model.selectedConversation = usage.id; listIsFocused = true })
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(model.selectedConversation == usage.id ? Color.accentGreen.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                            .accessibilityAddTraits(model.selectedConversation == usage.id ? [.isSelected] : [])
                            .id(usage.id)
                        Divider().padding(.leading, 80)
                    }
                }
              }
              .focusable().focused($listIsFocused).focusEffectDisabled()
              .onMoveCommand { direction in
                  let chats = model.visibleConversations
                  guard !chats.isEmpty, direction == .up || direction == .down else { return }
                  let index = chats.firstIndex { $0.id == model.selectedConversation }
                  let next = index.map { min(chats.count - 1, max(0, $0 + (direction == .down ? 1 : -1))) } ?? (direction == .up ? chats.count - 1 : 0)
                  model.selectedConversation = chats[next].id
                  proxy.scrollTo(chats[next].id)
              }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .overlay {
                if model.visibleConversations.isEmpty {
                    VStack(spacing: 12) {
                        if model.busy { ProgressView(); Text("正在载入聊天…") }
                        else {
                            Image(systemName: model.search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                                .font(.system(size: 28)).foregroundStyle(.tertiary)
                            Text(model.search.isEmpty ? "此账号暂无可显示的聊天" : "没有匹配的聊天")
                        }
                    }.font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
                }
            }
            Divider()
            HStack {
                Text("已选 \(model.checkedConversations.count) 个聊天").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("预览清理") { model.preview(conversations: true) }
                    .disabled(model.checkedConversations.isEmpty || model.busy)
            }.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationListRow: View {
    let usage: ConversationUsage
    @Binding var checked: Bool
    let onSelect: () -> Void
    private var subtitle: String {
        usage.conversation.named ? "\(usage.filePaths.count) 个附件 · \(usage.messageCount) 条索引消息" : "未连接名称索引 · 仅目录归集"
    }
    var body: some View {
        HStack(spacing: 9) {
            Toggle("选择聊天", isOn: $checked)
                .toggleStyle(.checkbox).controlSize(.small).labelsHidden()
                .frame(width: 18).disabled(!usage.conversation.named)
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: usage.conversation.isGroup ? "person.2.fill" : "bubble.left.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(usage.conversation.named ? Color.accentGreen : .gray)
                        .frame(width: 32, height: 32)
                        .background(Color.accentGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(usage.conversation.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                            .help(usage.conversation.name)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(subtitle)
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text(SizeText.format(usage.logicalBytes))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(width: 76, alignment: .trailing).layoutPriority(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ConversationDetailView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let usage = model.currentConversation {
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(usage.conversation.name).font(.title2.bold()).lineLimit(2)
                    Text(usage.conversation.internalID ?? usage.conversation.directoryHash).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 24) {
                        stat("附件逻辑大小", SizeText.format(usage.logicalBytes))
                        stat("独占分配估算", SizeText.format(usage.allocatedBytes))
                        stat("共享分配估算", SizeText.format(usage.sharedBytes))
                    }
                    Text("已精确定位 \(usage.indexedFilePaths.count)/\(usage.filePaths.count) 个附件。数据库、语音及未归属文件未计入此聊天；这里不是完整聊天数据总量。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !usage.conversation.named {
                        Button("连接索引以显示聊天名和消息") { model.showingConnection = true }
                    }
                }.padding(22)
                Divider()
                HStack {
                    TextField("搜索消息摘要、文件名或消息编号", text: $model.messageSearch)
                    Picker("类型", selection: $model.mediaFilter) {
                        Text("全部").tag("全部")
                        ForEach(MediaKind.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 85)
                }.padding(.horizontal, 18).padding(.top, 15)
                HStack {
                    Toggle("截至日期", isOn: $model.useDateFilter).toggleStyle(.checkbox)
                    DatePicker("日期", selection: $model.beforeDate, displayedComponents: .date).labelsHidden().disabled(!model.useDateFilter)
                    Spacer()
                    Button("选择当前附件") { model.checkedMessages = Set(model.visibleMessages.filter { !$0.filePaths.isEmpty }.map(\.id)) }.buttonStyle(.link)
                }.font(.caption).padding(.horizontal, 18).padding(.vertical, 12)
                if model.visibleMessages.isEmpty {
                    ContentUnavailableView("暂无可显示的消息", systemImage: "text.bubble", description: Text("连接索引后显示消息。筛选条件下没有结果时，可调整类型或日期。"))
                } else {
                    LazyVStack(spacing: 0) {
                      ForEach(model.visibleMessages) { message in
                        HStack(alignment: .top, spacing: 11) {
                            Toggle("选择消息", isOn: Binding(get: { model.checkedMessages.contains(message.id) }, set: {
                                if $0 { model.checkedMessages.insert(message.id) } else { model.checkedMessages.remove(message.id) }
                            })).toggleStyle(.checkbox).labelsHidden().disabled(message.filePaths.isEmpty)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(message.kind.rawValue).font(.caption.weight(.medium)).foregroundStyle(Color.accentGreen)
                                    Text(message.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(SizeText.format(model.analysis?.bytes(for: message) ?? 0)).font(.caption.monospacedDigit())
                                }
                                Text(message.summary).font(.callout).lineLimit(2)
                                Text(message.resolution).font(.caption).foregroundStyle(.secondary)
                                ForEach(message.filePaths, id: \.self) { path in
                                    Button { model.reveal(path) } label: { Label((path as NSString).lastPathComponent, systemImage: "folder") }
                                        .buttonStyle(.link).font(.caption).lineLimit(1)
                                }
                            }
                        }.padding(.vertical, 12).padding(.horizontal, 18)
                        Divider().padding(.leading, 48)
                      }
                    }
                }
              }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已选 \(model.checkedMessages.count) 条消息的附件").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("清理此聊天…") { model.previewCurrentConversation() }
                                .disabled(!model.canCleanCurrentConversation)
                            Spacer(minLength: 8)
                            Button("预览所选消息") { model.preview(conversations: false) }.buttonStyle(.borderedProminent)
                                .disabled(model.checkedMessages.isEmpty || model.busy)
                        }
                    }.padding(18)
                }.background(Color.canvas)
            }
        } else {
            ContentUnavailableView("选择一个聊天", systemImage: "bubble.left.and.bubble.right", description: Text("查看附件占用，或进入聊天选择具体消息。"))
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmErase = false
    @State private var confirmForget = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("连接聊天索引").font(.title2.bold()); Spacer(); Button("完成") { model.showingConnection = false }.disabled(model.busy) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("选择本机账号后自动连接。每个账号的密钥与索引独立保存，切换账号不会沿用上一个账号的清理选择。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let inventory = model.inventory {
                        Picker("当前账号", selection: $model.selectedAccount) {
                            ForEach(inventory.accounts) { Text(model.accountLabel($0)).tag($0.id) }
                        }.disabled(model.busy)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("自动获取密钥并连接", systemImage: "bolt.shield").font(.headline)
                            Text("已有有效连接信息时会直接复用。首次连接会正常退出微信并打开临时连接窗口，请先保存草稿，再在临时微信中进入所选账号。")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("临时窗口仍使用本机账号数据，可能更新登录状态和缓存；请仅用于登录和加载聊天，不要发送消息。工具只重签临时副本，不更改已安装微信的签名或系统保护。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("自动连接所选账号") { model.automaticallyConnect() }
                                .buttonStyle(.borderedProminent).disabled(model.busy || model.isDemo || model.selectedAccount.isEmpty)
                            if model.captureTotal > 0 {
                                ProgressView(value: Double(model.captureVerified), total: Double(model.captureTotal))
                                Text("已验证 \(model.captureVerified)/\(model.captureTotal) 个加密索引").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("密钥仅保存在本机私有目录。首次可能需要手机确认、macOS 开发工具授权或打开聊天以加载所需索引。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("忘记所选账号的自动连接…", role: .destructive) { confirmForget = true }
                                .disabled(model.busy || model.isDemo || model.selectedAccount.isEmpty)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    DisclosureGroup("高级：手动导入") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("你也可以导入当前账号的本地密钥 JSON，或已有的已解密 db_storage。没有原始数据库绑定的外部索引仅供预览。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("选择本地密钥并连接…") { model.importKeys() }.disabled(model.busy)
                            Button("导入已解密索引…") { model.importSnapshot() }.disabled(model.busy)
                            Text("SQLCipher：\(SnapshotService.sqlcipherURL() == nil ? "未检测到" : "已检测到") · 自动取钥需要 Apple Silicon 与 Xcode 开发工具")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    Text("支持普通图片，以及内容校验一致的文件和视频。语音、转发内媒体和不能确认归属的项目会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("清除本工具的索引快照…", role: .destructive) { confirmErase = true }.disabled(model.busy)
                        Spacer()
                        Button("体验多账号演示") { model.showingConnection = false; model.loadDemo() }.disabled(model.busy)
                    }
                }
            }
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text(model.status).font(.caption); Spacer(); Button("取消") { model.cancel() } }
            }
        }.padding(28).frame(width: 640, height: 660)
        .confirmationDialog("清除本工具创建的明文索引快照？", isPresented: $confirmErase) {
            Button("清除快照", role: .destructive) { model.eraseSnapshots() }
        } message: { Text("微信原始数据和已记录的废纸篓项目保持保留。之后需重新连接索引。") }
        .confirmationDialog("忘记账号 \(model.selectedAccount) 的自动连接？", isPresented: $confirmForget) {
            Button("忘记此账号连接", role: .destructive) { model.forgetSelectedConnection() }
        } message: { Text("将删除该账号在本工具中保存的密钥和连接记录。其他账号及微信原始数据保留。") }
    }
}

struct PlanView: View {
    @EnvironmentObject var model: AppModel
    let plan: CleanupPlan
    @State private var acceptsUnknownOwnership = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("确认本次附件清理").font(.title2.bold())
            HStack {
                MetricCard(title: "将移入废纸篓", value: "\(plan.candidates.count) 个文件",
                    note: plan.scope == .unassignedAttachments ? "来自手动选择的未归属附件" : "来自 \(plan.selectedMessages) 条选中消息", icon: "trash")
                MetricCard(title: "选中路径逻辑大小", value: SizeText.format(plan.logicalBytes), note: "去重分配空间估算 \(SizeText.format(plan.allocatedBytes))，不保证回收量", icon: "internaldrive")
            }
            Text("相关附件将无法从原聊天位置打开。文字消息和数据库保留；旧附件不保证能重新下载。移入废纸篓后空间仍被占用，需在 Finder 审阅并清空相关项目。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if plan.scope == .unassignedAttachments {
                if plan.sharedPathCount > 0 {
                    Text("包含 \(plan.sharedPathCount) 个共享文件路径。只移动勾选的路径，其他硬链接保留；仍有其他链接时不能回收该文件的数据空间。逻辑大小可能包含共享数据的重复引用。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("我已核对文件，了解“未归属”不代表无用，清理可能影响聊天中的附件。", isOn: $acceptsUnknownOwnership)
                    .toggleStyle(.checkbox).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(plan.candidates) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text((item.relativePath as NSString).lastPathComponent).lineLimit(1)
                        Text(item.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if item.expectedIdentity.links > 1 {
                            Text("共享文件 · \(item.expectedIdentity.links) 个硬链接 · 仅处理此路径")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("以下项目不会处理") {
                        ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.frame(height: 210)
            HStack {
                Button("取消", role: .cancel) { model.plan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("将 \(plan.candidates.count) 个附件移入废纸篓") { model.executePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.candidates.isEmpty || model.busy || (plan.scope == .unassignedAttachments && !acceptsUnknownOwnership))
            }
        }.padding(28).frame(width: 700)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.records.isEmpty {
            ContentUnavailableView("还没有清理记录", systemImage: "clock.arrow.circlepath", description: Text("每次操作会记录每个文件的结果，方便核对和恢复。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let before = model.availableBefore, let after = model.availableAfter {
                        Text("卷可用空间：操作前 \(SizeText.format(before)) → 当前 \(SizeText.format(after))。差值可能受其他应用影响，不能完全归因于本次操作。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentGreen)
                                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.headline)
                                Spacer()
                                Text(stateName(record.state)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("移入废纸篓 \(record.trashedCount) 个 · 已恢复 \(record.restoredCount) 个 · 本次计划 \(SizeText.format(record.logicalBytes))")
                            if record.scope == .unassignedAttachments { Text("手动选择的未归属附件").font(.caption).foregroundStyle(.secondary) }
                            if let accounts = record.accountIDs { Text("账号：" + accounts.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                            DisclosureGroup("逐项结果") {
                                ForEach(record.items) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text((item.sourceRelativePath as NSString).lastPathComponent).lineLimit(1); Spacer(); Text(stateName(item.state)).foregroundStyle(.secondary) }
                                        if let error = item.error { Text(error).foregroundStyle(.secondary) }
                                    }.font(.caption).padding(.vertical, 5)
                                }
                                ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                            HStack {
                                Button("在 Finder 查看本次项目") { model.revealTrash(record) }.disabled(record.trashedCount == 0)
                                Button("恢复可恢复项目") { model.restore(record) }
                                    .disabled(model.busy || !record.items.contains { ["trashed", "conflict"].contains($0.state) })
                                Spacer()
                            }
                        }.padding(22).background(Color.card, in: RoundedRectangle(cornerRadius: 13))
                    }
                }.padding(26)
            }
        }
    }
    private func stateName(_ state: String) -> String {
        ["completed": "已完成", "partial": "部分完成", "interrupted": "已中断", "running": "进行中",
         "pending": "未开始", "prepared": "待核实", "trashed": "在废纸篓", "skipped": "已跳过", "failed": "失败",
         "indeterminate": "需人工核实", "restored": "已恢复", "conflict": "原位置冲突", "unavailable": "不可恢复"][state] ?? state
    }
}

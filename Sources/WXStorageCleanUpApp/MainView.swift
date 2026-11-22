import SwiftUI
import AppKit
import WXStorageCleanUpCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 11) {
                    AppBrandIcon(size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("微空间").font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.75)
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
        .modifier(GlobalLoading())
        .sheet(isPresented: $model.showingConnection) { ConnectionView() }
        .sheet(item: $model.plan) { plan in PlanView(plan: plan) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("已移入废纸篓，空间尚未释放", isPresented: Binding(
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
            case .legacy: LegacyDataView()
            case .history: HistoryView()
            }
        }
    }
    private var header: some View {
      VStack(alignment: .leading, spacing: 12) {
        if model.page == .unassigned || model.page == .legacy {
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
                Button { model.showingConnection = true } label: {
                    Label(model.indexes[model.selectedAccount] == nil ? "连接聊天" : "管理连接",
                          systemImage: "link")
                        .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(PrimaryScanButtonStyle())
                .disabled(model.busy)
                .help("自动获取密钥并连接所选账号的聊天索引")
                .accessibilityIdentifier("connect-chats")
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
        case .chats: "按聊天查看和清理全部本地附件，也可打开 Finder 文件夹"
        case .unassigned: "查看尚未识别聊天归属的本地附件，按文件选择整理"
        case .legacy: "按文件夹浏览旧版微信留下的数据，确认不再需要后整理"
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
    /// Modules whose expansion differs from the default (only the selected account is expanded).
    @State private var toggled = Set<String>()
    var body: some View {
        ScrollView {
            if let analysis = model.analysis {
                let inventory = analysis.inventory
                VStack(alignment: .leading, spacing: 24) {
                    if let breakdown = model.breakdown {
                        let account = breakdown.total.module(StorageBreakdown.accountID(model.selectedAccount))
                        let chats = breakdown.total.module(StorageBreakdown.chatsID(model.selectedAccount))
                        HStack(alignment: .top, spacing: 14) {
                            MetricCard(title: "微信总占用", value: SizeText.format(breakdown.total.allocatedBytes),
                                note: "磁盘实际占用，等于下方各模块之和", icon: "internaldrive")
                            MetricCard(title: "当前账号", value: SizeText.format(account?.allocatedBytes ?? 0),
                                note: account == nil ? "扫描范围内没有新版账号目录" : "其中聊天附件 \(SizeText.format(chats?.allocatedBytes ?? 0))，与“聊天与消息”合计一致",
                                icon: "person.crop.circle")
                            MetricCard(title: "会话目录", value: "\(analysis.conversations.count)",
                                note: "\(analysis.conversations.filter { $0.conversation.named }.count) 个已识别名称，\(analysis.messages.count) 条索引消息", icon: "bubble.left.and.bubble.right")
                        }
                        StorageBreakdownCard(breakdown: breakdown, isExpanded: isExpanded, toggle: toggle, open: model.open)
                    } else {
                        ProgressView("正在统计空间构成…").frame(maxWidth: .infinity).padding(40)
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
                    if inventory.root.lastPathComponent != "Data" {
                        Text("当前只扫描了所选目录。选择微信的 Data 目录，可一并统计内置浏览器、插件、日志等数据。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("另含应用程序与 \(inventory.relatedLocations.count) 个扩展和共享位置。未跟随 \(inventory.skippedLinks) 个链接项目（如容器中指向桌面、下载的系统链接，不属于微信占用）；\(inventory.blockedAccountIDs.count) 个账号因内部链接而锁定清理。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("占用按磁盘实际分配空间计算，硬链接只计一次。清理移入废纸篓后，清空废纸篓才会释放空间。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).padding(.bottom, 26)
            }
        }
    }
    private func isExpanded(_ id: String) -> Bool {
        (id == StorageBreakdown.accountID(model.selectedAccount)) != toggled.contains(id)
    }
    private func toggle(_ id: String) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }
}

/// The "total → modules" tree: a stacked bar of top-level modules and expandable rows whose sizes add up to the total.
private struct StorageBreakdownCard: View {
    let breakdown: StorageBreakdown
    let isExpanded: (String) -> Bool
    let toggle: (String) -> Void
    let open: (StorageModule.Link) -> Void
    private var total: Int64 { breakdown.total.allocatedBytes }
    private var modules: [StorageModule] { visible(breakdown.total.children) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("空间构成").font(.headline)
                Spacer()
                Text("各项合计 \(SizeText.format(total))，即微信总占用").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 2 * CGFloat(max(0, modules.count - 1)))
                HStack(spacing: 2) {
                    ForEach(modules) { module in
                        Rectangle().fill(color(module.id))
                            .frame(width: max(2, width * CGFloat(module.allocatedBytes) / CGFloat(max(1, total))))
                    }
                }
            }
            .frame(height: 14).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(spacing: 0) {
                ForEach(modules) { module in
                    row(module, depth: 0)
                    if isExpanded(module.id) {
                        ForEach(visible(module.children)) { child in row(child, depth: 1) }
                    }
                    Divider()
                }
            }
            if breakdown.sharedPhysicalFiles > 0 {
                Text("\(breakdown.sharedPhysicalFiles) 个文件可从多个路径访问（硬链接），只计入一个模块，优先计入聊天附件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !breakdown.complete {
                Text("部分位置未能完整读取，合计可能偏小，详见下方扫描说明。").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(23).background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("storage-breakdown")
    }

    private func visible(_ modules: [StorageModule]) -> [StorageModule] {
        modules.filter { $0.allocatedBytes > 0 }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
    private func row(_ module: StorageModule, depth: Int) -> some View {
        let expandable = depth == 0 && !visible(module.children).isEmpty
        return HStack(spacing: 10) {
            if depth == 0 {
                Image(systemName: isExpanded(module.id) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12).opacity(expandable ? 1 : 0)
                Circle().fill(color(module.id)).frame(width: 9, height: 9)
            } else {
                Spacer().frame(width: 41)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(depth == 0 ? .callout.weight(.medium) : .callout).lineLimit(1)
                Text(module.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let link = module.link {
                Button(link.title) { open(link) }.buttonStyle(.link).font(.caption)
            }
            Text(SizeText.format(module.allocatedBytes)).font(.callout.monospacedDigit())
                .frame(minWidth: 72, alignment: .trailing).fixedSize()
            Text(percent(module.allocatedBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if expandable { toggle(module.id) } }
        .help(module.detail)
    }
    private func percent(_ bytes: Int64) -> String {
        let value = Double(bytes) / Double(max(1, total)) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
    /// Accounts share the green, each one lighter, so several accounts stay distinguishable in the bar.
    private func color(_ id: String) -> Color {
        let accounts = breakdown.total.children.filter { $0.id.hasPrefix("account:") }.map(\.id)
        if let index = accounts.firstIndex(of: id) { return Color.accentGreen.opacity(max(0.35, 1 - 0.3 * Double(index))) }
        return Self.color(id)
    }
    static func color(_ id: String) -> Color {
        if id.hasPrefix("account:") { return .accentGreen }
        switch id {
        case "browser": return .blue
        case "plugins": return .indigo
        case "logs": return .orange
        case "app-cache": return .yellow
        case "backup": return .pink
        case "shared-account": return .mint
        case "legacy": return .purple
        case "application": return .brown
        case "related": return .cyan
        default: return .gray
        }
    }
}

extension StorageModule.Link {
    var title: String {
        switch self { case .chats: "查看聊天"; case .unassigned, .legacy: "查看文件" }
    }
}

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var preferredListWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @FocusState private var listIsFocused: Bool

    var body: some View {
      VStack(spacing: 0) {
        ChatSummaryBar(summary: model.currentChatSummary)
            .padding(.horizontal, 14).padding(.top, 14)
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
                if !model.search.isEmpty {
                    Text("匹配 \(model.visibleConversations.count) 个聊天").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if model.currentChatSummary.sharedBytes > 0 {
                    // How the rows add up to the total: each row also includes what it shares with other chats.
                    let summary = model.currentChatSummary
                    Text("合计 = 各聊天独占 \(SizeText.format(summary.exclusiveBytes)) + 共享 \(SizeText.format(summary.sharedBytes))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Text("按占用排序").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 15).padding(.bottom, 8)
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleConversations) { usage in
                        ConversationListRow(usage: usage, onSelect: { model.selectedConversation = usage.id; listIsFocused = true })
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Account-wide totals for the chats page: deduplicated attachment size, counts and a per-type breakdown.
private struct ChatSummaryBar: View {
    let summary: ChatSpaceSummary
    private struct KindStyle { let kind: MediaKind; let color: Color }
    private static let kinds = [KindStyle(kind: .image, color: .accentGreen), KindStyle(kind: .video, color: .blue),
                                KindStyle(kind: .file, color: .orange), KindStyle(kind: .voice, color: .purple)]
    private func bytes(_ kind: MediaKind) -> Int64 { summary.bytesByKind[kind] ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("聊天附件占用").font(.caption).foregroundStyle(.secondary)
                Text(SizeText.format(summary.allocatedBytes))
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }.fixedSize()
            figure(summary.chats, "个聊天")
            figure(summary.files, "个附件")
            figure(summary.messages, "条索引消息")
            VStack(alignment: .leading, spacing: 8) {
                distribution
                ViewThatFits(in: .horizontal) { legend(withSizes: true); legend(withSizes: false) }
            }.frame(minWidth: 150, maxWidth: .infinity)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.05)))
        .help("与“空间概览”中该账号的“聊天附件”一致：按磁盘实际占用计算，同一文件只计一次。合计 = 各聊天独占 \(SizeText.format(summary.exclusiveBytes)) + 多个聊天或硬链接共享 \(SizeText.format(summary.sharedBytes))；逻辑大小 \(SizeText.format(summary.logicalBytes))。")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-summary")
    }
    private func figure(_ value: Int, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.fixedSize()
    }
    private var distribution: some View {
        GeometryReader { geometry in
            let visible = Self.kinds.filter { bytes($0.kind) > 0 }
            let total = max(1, visible.reduce(Int64(0)) { $0 + bytes($1.kind) })
            let width = max(0, geometry.size.width - 2 * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: 2) {
                ForEach(visible, id: \.kind) { style in
                    Rectangle().fill(style.color).frame(width: max(2, width * CGFloat(bytes(style.kind)) / CGFloat(total)))
                }
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private func legend(withSizes: Bool) -> some View {
        HStack(spacing: 12) {
            if summary.files == 0 { Text("暂无本地附件") }
            ForEach(Self.kinds.filter { bytes($0.kind) > 0 }, id: \.kind) { style in
                HStack(spacing: 5) {
                    Circle().fill(style.color).frame(width: 7, height: 7)
                    Text(withSizes ? "\(style.kind.rawValue) \(SizeText.format(bytes(style.kind)))" : style.kind.rawValue)
                }.lineLimit(1).fixedSize()
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct ConversationListRow: View {
    let usage: ConversationUsage
    let onSelect: () -> Void
    private var subtitle: String {
        usage.conversation.named ? "\(usage.filePaths.count) 个附件 · \(usage.messageCount) 条索引消息" : "未连接名称索引 · 仅目录归集"
    }
    var body: some View {
        HStack(spacing: 9) {
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
                    Text(SizeText.format(usage.occupiedBytes))
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
    @State private var showingImages = false
    var body: some View {
        if let usage = model.currentConversation {
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(usage.conversation.name).font(.title2.bold()).lineLimit(2)
                    Text(usage.conversation.internalID ?? usage.conversation.directoryHash).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 24) {
                        stat("附件占用", SizeText.format(usage.occupiedBytes))
                        stat("独占（清理后可释放）", SizeText.format(usage.allocatedBytes))
                        stat("与其他聊天或硬链接共享", SizeText.format(usage.sharedBytes))
                    }
                    Text("\(usage.filePaths.count) 个本地附件，逻辑大小 \(SizeText.format(usage.logicalBytes))；清理预览使用相同清单。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("查看聊天图片") { showingImages = true }
                    Button("在 Finder 中打开聊天附件文件夹") { model.openCurrentConversationFolder() }
                        .buttonStyle(.link)
                    Text("文件与视频可能分散存放在其他目录，清理预览会列出全部附件路径。")
                        .font(.caption).foregroundStyle(.secondary)
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
                }.font(.caption).padding(.horizontal, 18).padding(.vertical, 12)
                if model.analysisLoading { ProgressView("正在整理聊天索引…").padding() }
                if model.visibleMessages.isEmpty {
                    ContentUnavailableView("暂无可显示的消息", systemImage: "text.bubble", description: Text("连接索引后显示消息。筛选条件下没有结果时，可调整类型或日期。"))
                } else {
                    LazyVStack(spacing: 0) {
                      ForEach(model.visibleMessages) { message in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(message.kind.rawValue).font(.caption.weight(.medium)).foregroundStyle(Color.accentGreen)
                                    Text(message.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(SizeText.format(model.analysis?.bytes(for: message) ?? 0)).font(.caption.monospacedDigit())
                                }
                                Text(message.summary).font(.callout).lineLimit(2)
                                Text(message.resolution).font(.caption).foregroundStyle(.secondary)
                                if message.kind == .image, let root = model.inventory?.root, let path = message.filePaths.first {
                                    ChatImageView(root: root, path: path)
                                }
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
                if model.visibleMessages.count < model.filteredMessageCache.count {
                    Button("加载更多消息（每次 200 条）") { model.messageLimit += 200 }.padding()
                }
              }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showingImages) {
                if let root = model.inventory?.root { ChatImagesView(root: root, paths: usage.filePaths) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("清理该聊天的全部 \(usage.filePaths.count) 个本地附件，文字消息保留；消息筛选不改变清理范围。如需删除文字，请先在这里清理附件，再在微信中清空该聊天的聊天记录，否则散放的附件会对应不到这个聊天。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("清理此聊天…") { model.previewCurrentConversation() }
                                .disabled(!model.canCleanCurrentConversation)
                            Spacer(minLength: 8)
                        }
                    }.padding(18)
                }.background(Color.canvas)
            }
        } else {
            ContentUnavailableView("选择一个聊天", systemImage: "bubble.left.and.bubble.right", description: Text("查看该聊天的附件占用、清理全部附件或打开 Finder。"))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("连接聊天索引").font(.title2.bold())
                Spacer()
                Button("完成") { model.showingConnection = false }.disabled(model.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let inventory = model.inventory {
                        Picker("当前账号", selection: $model.selectedAccount) {
                            ForEach(inventory.accounts) { Text(model.accountLabel($0)).tag($0.id) }
                        }.disabled(model.busy)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("自动获取密钥并连接", systemImage: "bolt.shield").font(.headline)
                            Text("已有有效连接信息时会直接复用。首次连接会退出微信并打开临时窗口，请先保存草稿，再登录所选账号。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("自动连接所选账号") { model.automaticallyConnect() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy || model.isDemo || model.selectedAccount.isEmpty)
                            if model.captureTotal > 0 {
                                ProgressView(value: Double(model.captureVerified), total: Double(model.captureTotal))
                                Text("已验证 \(model.captureVerified)/\(model.captureTotal) 个加密索引")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if model.connectionStatus[model.selectedAccount] == "连接中" {
                                Text(model.status).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("需要 Xcode 或 Command Line Tools。请按提示完成手机确认，并打开联系人和历史聊天以加载索引。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("临时微信使用本机账号数据，可能更新登录状态和缓存；请仅用于登录和加载聊天。密钥仅保存在本机。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    if let error = model.errorMessage {
                        Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(28).frame(width: 640, height: 520)
        .modifier(GlobalLoading())
        .interactiveDismissDisabled(model.busy)
    }
}

struct PlanView: View {
    @EnvironmentObject var model: AppModel
    let plan: CleanupPlan
    @State private var acknowledged = false
    private var needsAcknowledgement: Bool { plan.scope == .unassignedAttachments || plan.scope == .legacyData }
    private var source: String {
        switch plan.scope {
        case .conversationAttachments: "该聊天目录与索引中发现的全部附件"
        case .legacyData: "来自手动选择的历史版本数据"
        default: "来自手动选择的其他文件"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(plan.scope == .legacyData ? "确认清理历史版本数据" : "确认本次附件清理").font(.title2.bold())
            HStack {
                MetricCard(title: "将移入废纸篓", value: "\(plan.candidates.count) 个项目", note: source, icon: "trash")
                MetricCard(title: "选中路径逻辑大小", value: SizeText.format(plan.logicalBytes), note: "去重分配空间估算 \(SizeText.format(plan.allocatedBytes))，不保证回收量", icon: "internaldrive")
            }
            if plan.scope == .legacyData {
                Text("选中的旧版微信数据将移入废纸篓。其中若有旧版聊天记录数据库，未迁移到新版的旧聊天记录将无法再查看。已计入聊天附件的旧版图片、视频等保留在原位。移入废纸篓后空间仍被占用，需在 Finder 审阅并清空相关项目。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("相关附件将无法从原聊天位置打开。文字消息和数据库保留；旧附件不保证能重新下载。移入废纸篓后空间仍被占用，需在 Finder 审阅并清空相关项目。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if plan.scope == .conversationAttachments {
                Text("该聊天的专属文件夹整目录移入废纸篓，共用目录中的分散附件单独处理。完成后直接更新列表，不重新扫描。文字消息和数据库保留。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if needsAcknowledgement {
                if plan.sharedPathCount > 0 {
                    Text("包含 \(plan.sharedPathCount) 个共享文件路径。只移动勾选的路径，其他硬链接保留；仍有其他链接时不能回收该文件的数据空间。逻辑大小可能包含共享数据的重复引用。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(plan.scope == .legacyData ? "我已确认需要的旧聊天记录已能在新版微信中查看或已备份，了解清理后可能无法再查看旧版聊天记录。"
                       : "我已核对文件，了解“未匹配聊天”不代表无用，清理可能影响聊天中的附件。", isOn: $acknowledged)
                    .toggleStyle(.checkbox).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(plan.candidates) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text((item.relativePath as NSString).lastPathComponent).lineLimit(1)
                        Text(item.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if item.isDirectory {
                            Text(plan.scope == .legacyData ? "整文件夹移入废纸篓 · \(SizeText.format(item.contentBytes ?? 0))" : "整文件夹移入废纸篓")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !item.isDirectory && item.expectedIdentity.links > 1 {
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
                Button("将 \(plan.candidates.count) 个项目移入废纸篓") { model.executePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.candidates.isEmpty || model.busy || (needsAcknowledgement && !acknowledged))
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
                            if record.scope == .unassignedAttachments { Text("手动选择的其他文件").font(.caption).foregroundStyle(.secondary) }
                            if record.scope == .legacyData { Text("历史版本数据").font(.caption).foregroundStyle(.secondary) }
                            if let accounts = record.accountIDs, !accounts.isEmpty { Text("账号：" + accounts.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
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

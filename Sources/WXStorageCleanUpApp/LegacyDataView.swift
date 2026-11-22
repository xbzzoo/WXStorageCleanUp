import SwiftUI
import WXStorageCleanUpCore

/// Browses the old (3.x) client's data folder by folder; selected folders and files can be moved to the Trash.
struct LegacyDataView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let root = model.legacy.root, let current = model.legacyCurrent {
            content(root: root, current: current)
        } else {
            ContentUnavailableView("没有历史版本数据", systemImage: "archivebox", description: Text(
                model.inventory?.root.lastPathComponent == "Data" ? "扫描范围内没有旧版微信（3.x）留下的数据。"
                    : "当前只扫描了所选目录。选择微信的 Data 目录重新扫描，才能看到旧版微信（3.x）的数据。"))
        }
    }

    private func content(root: LegacyNode, current: LegacyNode) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(root.files) 个文件 · 占用 \(SizeText.format(model.legacyOccupied ?? root.allocatedBytes))").font(.headline)
                        .help("与“空间概览”中的“历史版本数据”一致；逻辑大小合计 \(SizeText.format(root.logicalBytes))。")
                    Spacer()
                    Text("按占用排序").font(.caption).foregroundStyle(.secondary)
                }
                Text("旧版微信（3.x）留下的数据库和文件。已对应到新版聊天的旧版图片、视频等附件计入聊天附件，不在此列，可在“聊天与消息”中按聊天清理。点击文件夹进入，勾选后可清理，清理会将选中项目移入废纸篓。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("清理前请确认需要的旧聊天记录已能在新版微信中查看，或已另行备份。只有旧版账号文件夹内的项目可以清理，其他位置仅供浏览。",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                breadcrumb
                HStack {
                    Button("选择当前列表") { model.selectVisibleLegacy() }.buttonStyle(.link)
                        .disabled(model.busy || !current.children.contains { $0.cleanable && !model.legacyCovered($0.id) })
                    Button("取消选择") { model.checkedLegacy = [] }.buttonStyle(.link).disabled(model.busy || model.checkedLegacy.isEmpty)
                    Button("在 Finder 中打开当前文件夹") { model.reveal(current.id) }.buttonStyle(.link).disabled(model.busy)
                    Spacer()
                    Text("显示 \(model.visibleLegacy.count) / \(current.children.count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            List {
                ForEach(model.visibleLegacy) { node in row(node) }
                if model.visibleLegacy.count < current.children.count {
                    Button("加载更多（每次 200 项）") { model.legacyLimit += 200 }.padding(8)
                }
            }.listStyle(.plain).frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("已选 \(model.checkedLegacy.count) 项 · \(SizeText.format(model.selectedLegacyBytes))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("清理") { model.previewLegacy() }.buttonStyle(.borderedProminent)
                        .disabled(model.checkedLegacy.isEmpty || model.busy)
                }.padding(18)
            }.background(Color.canvas)
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.legacyTrail.enumerated()), id: \.element.id) { offset, node in
                    if offset > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    let title = offset == 0 ? "全部" : Scanner.isHash(node.name) ? String(node.name.prefix(8)) + "…" : node.name
                    if node.id == model.legacyCurrent?.id {
                        Text(title).fontWeight(.medium)
                    } else {
                        Button(title) { model.legacyFolder = node.id }.buttonStyle(.link).disabled(model.busy)
                    }
                }
            }.font(.callout).lineLimit(1)
        }.accessibilityIdentifier("legacy-breadcrumb")
    }

    private func row(_ node: LegacyNode) -> some View {
        let covered = model.legacyCovered(node.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("选择 \(node.name)", isOn: Binding(get: { covered || model.checkedLegacy.contains(node.id) },
                set: { model.setLegacy(node.id, checked: $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(model.busy || covered || !node.cleanable)
                .help(!node.cleanable ? "不在旧版账号文件夹内，仅供浏览。" : covered ? "已随上级文件夹选择。" : "选择此项目")
                .padding(.top, 9)
            Button { model.openLegacy(node) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: node.isDirectory ? "folder" : "doc").foregroundStyle(Color.accentGreen).frame(width: 22)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(node.name).lineLimit(1).truncationMode(.middle).help(node.name)
                            Spacer(minLength: 12)
                            Text(SizeText.format(node.allocatedBytes)).monospacedDigit().fixedSize()
                                .help("逻辑大小 \(SizeText.format(node.logicalBytes))")
                        }
                        if let note = node.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        HStack {
                            if node.isDirectory { Text("\(node.files) 个文件") }
                            Text("修改于")
                            Text(node.modifiedAt, format: .dateTime.year().month().day())
                            if !node.cleanable { Text("· 仅供浏览") }
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary)
                        if node.mixed {
                            Label("部分内容已计入聊天附件，清理时保留在原位", systemImage: "bubble.left.and.bubble.right")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if node.hardlinkedFiles > 0 {
                            Label("含 \(node.hardlinkedFiles) 个硬链接共享文件，仅清理此路径，可能不释放这部分空间", systemImage: "link")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if node.isDirectory {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
                    }
                }.padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy)
                .help(node.isDirectory ? "打开文件夹" : "在 Finder 中显示此文件")
                .accessibilityLabel(node.isDirectory ? "打开 \(node.name)" : "在 Finder 中显示 \(node.name)")
                .accessibilityIdentifier("legacy-" + node.id)
        }
    }
}

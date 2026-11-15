import SwiftUI
import WeChatStorageCore

struct UnassignedAttachmentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(model.accountUnassigned.count) 个附件 · \(SizeText.format(model.accountUnassigned.reduce(0) { $0 + $1.identity.bytes }))")
                        .font(.headline)
                    Spacer()
                    Text("逻辑大小 · 按大小排序").font(.caption).foregroundStyle(.secondary)
                }
                Text("这些附件尚未识别聊天归属，可能仍被消息使用。清理将选中路径移入废纸篓，可从操作记录恢复；共享文件仍有其他硬链接时，空间不会因此释放。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("搜索文件名或路径", text: $model.unassignedSearch)
                    Picker("类型", selection: $model.unassignedType) {
                        Text("全部").tag("全部")
                        ForEach([MediaKind.video, .image, .file, .voice], id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 100)
                }
                HStack {
                    Button("选择当前结果") {
                        model.checkedUnassigned.formUnion(model.visibleUnassigned.map(\.id))
                    }.buttonStyle(.link).disabled(model.busy)
                    Button("取消选择") { model.checkedUnassigned = [] }.buttonStyle(.link).disabled(model.busy)
                    Spacer()
                    Text("显示 \(model.visibleUnassigned.count) 个")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            List(model.visibleUnassigned) { file in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("选择 \(file.name)", isOn: Binding(get: { model.checkedUnassigned.contains(file.id) }, set: {
                        if $0 { model.checkedUnassigned.insert(file.id) } else { model.checkedUnassigned.remove(file.id) }
                    })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                        .help(model.busy ? "任务进行中，完成后可选择。" : "选择此附件路径")
                    Image(systemName: file.attachmentKind == .video ? "video" : file.attachmentKind == .image ? "photo" : "doc")
                        .foregroundStyle(Color.accentGreen).frame(width: 22)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
                            Spacer(minLength: 12)
                            Text(SizeText.format(file.identity.bytes)).monospacedDigit().fixedSize()
                        }
                        Text(file.relativePath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(file.relativePath)
                        HStack {
                            Text(file.attachmentKind.rawValue)
                            Text("修改于")
                            Text(file.modifiedAt, format: .dateTime.year().month().day())
                            Spacer()
                            Button("在 Finder 中查看") { model.reveal(file.relativePath) }.buttonStyle(.link)
                        }.font(.caption).foregroundStyle(.secondary)
                        if file.identity.links > 1 {
                            Label("共享文件 · \(file.identity.links) 个硬链接 · 仅清理选中路径", systemImage: "link")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 9)
            }.listStyle(.plain).frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .overlay {
                    if model.visibleUnassigned.isEmpty {
                        ContentUnavailableView(model.accountUnassigned.isEmpty ? "没有未归属附件" : "没有匹配的附件",
                            systemImage: "tray", description: Text(model.accountUnassigned.isEmpty ? "当前账号没有扫描到尚未归属聊天的附件。" : "调整搜索或类型筛选后重试。"))
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("已选 \(model.checkedUnassigned.count) 个 · \(SizeText.format(model.selectedUnassignedBytes))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("预览清理") { model.previewUnassigned() }.buttonStyle(.borderedProminent)
                        .disabled(model.checkedUnassigned.isEmpty || model.busy)
                }.padding(18)
            }.background(Color.canvas)
        }
    }
}

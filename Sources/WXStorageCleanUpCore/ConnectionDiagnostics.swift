import Foundation

private struct ConnectionDiagnostic: Codable {
    let version: Int
    let toolVersion: String
    let macOSVersion: String
    let wechatVersion: String
    let helperExitStatus: Int32
    let lldbVersion: String?
    let targetArchitecture: String?
    let events: [CaptureEvent]
}

extension AccountConnectionStore {
    private func diagnosticFile(root: URL, accountID: String) -> URL {
        accountDirectory(root: root, accountID: accountID).appendingPathComponent("last-connection-diagnostic.json")
    }

    func saveDiagnostic(_ result: LocalCommandResult, root: URL, accountID: String, application: URL) throws {
        let info = NSDictionary(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let report = ConnectionDiagnostic(version: 1,
            toolVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            wechatVersion: String((version + " (" + build + ")").prefix(120)), helperExitStatus: result.status,
            lldbVersion: result.events.first(where: { $0.lldbVersion != nil })?.lldbVersion,
            targetArchitecture: result.events.first(where: { $0.targetArchitecture != nil })?.targetArchitecture,
            events: Array(result.events.suffix(24)))
        let file = diagnosticFile(root: root, accountID: accountID)
        try FileSafety.privateDirectory(file.deletingLastPathComponent())
        // Encode typed metadata only. Raw stdout/stderr, keys and request paths
        // are deliberately absent from this report.
        try FileSafety.writePrivate(report, to: file)
    }

    public func diagnosticText(root: URL, accountID: String) throws -> String {
        let file = diagnosticFile(root: root, accountID: accountID)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw StorageError.invalid("暂无所选账号的连接诊断。请用当前版本尝试自动连接后再复制。")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 128 * 1024 else { throw StorageError.invalid("连接诊断文件超出大小限制。") }
        let report = try JSONDecoder().decode(ConnectionDiagnostic.self, from: data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var runtime: AppRuntime

    private var versionLine: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "打开即推流 · 无需再点启动 · v\(ver)"
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("自研本地基座")
                .font(.largeTitle.bold())
            Text(versionLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(runtime.running ? "服务已自动启动 :\(runtime.port)" : "正在自动启动…", systemImage: runtime.running ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(runtime.running ? .green : .orange)
                Label(runtime.capturing ? "采屏推流中" : "采屏未就绪", systemImage: runtime.capturing ? "video.fill" : "video.slash")
                    .foregroundStyle(runtime.capturing ? .green : .orange)
                Text(runtime.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("内存 \(runtime.memoryMB) MB · 自动重启 \(runtime.restartCount) 次（超 220MB）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("设备：\(runtime.deviceName)")
                    .font(.footnote)
                Text("本机 IP：\(runtime.lanIP):\(runtime.port)")
                    .font(.footnote.monospaced())
                Text("ID：\(runtime.deviceId)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let err = runtime.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            Text("电脑打开投屏页 → 扫描 → 选本机。\n须与电脑同一网段；扫不到就手动填上面的 IP。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}

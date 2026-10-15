import SwiftUI
import DBDeepCore

struct ConnectionDiagnosticsView: View {
    let connection: DBConnection
    let attempt: ConnectionAttempt?
    @State private var copied = false
    @State private var showOriginal = true

    private var target: DBConnection { attempt?.connection ?? connection }
    private var status: String {
        switch attempt?.outcome {
        case .running: return "Connecting…"
        case .succeeded: return "Connection verified"
        case .failed: return "Connection failed"
        case .partial: return "Connected · schema unavailable"
        case nil: return "Ready to test"
        }
    }
    private var statusColor: Color {
        switch attempt?.outcome {
        case .succeeded: return Theme.green
        case .failed, .partial: return Theme.accent("peach")
        default: return Theme.purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Connection details", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .semibold))
                Spacer()
                IconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy connection report") {
                    guard let attempt else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(attempt.report, forType: .string)
                    copied = true
                }.disabled(attempt == nil)
            }
            HStack(spacing: 6) {
                if attempt?.outcome == .running { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                else { Circle().fill(statusColor).frame(width: 5, height: 5) }
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                Spacer()
                if let attempt {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        Text(String(format: "%.2fs", max(0, (attempt.finishedAt ?? context.date).timeIntervalSince(attempt.startedAt))))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let attempt, attempt.connection != connection {
                        Label("설정이 변경되었습니다. 아래는 마지막 시도에 사용한 값입니다.", systemImage: "info.circle")
                            .font(.system(size: 10)).foregroundStyle(Theme.accent("peach"))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        detail("Host / port", "\(target.host):\(target.port)")
                        detail(target.usesSID ? "SID" : "Service name", target.service)
                        detail("Username", target.username.isEmpty ? "—" : target.username)
                        detail("Driver", "Oracle JDBC Thin · TCP")
                        detail("Charset library", target.usesBundledInternationalization ? "Bundled orai18n.jar" : "Not selected")
                        if !target.additionalJARs.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Additional JARs").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                                ForEach(target.additionalJARs, id: \.self) { path in
                                    Text(path).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("JDBC URL").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                            Text(target.jdbcURL).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        }
                        Text("TCP 8s · connection establishment 10s\nRead 70s · verification query 10s")
                            .font(.system(size: 9)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        Text("Check: SELECT 1 FROM DUAL").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                    if let attempt {
                        Rectangle().fill(Theme.line).frame(height: 1)
                        Text("ATTEMPT LOG").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.secondary)
                        ForEach(attempt.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: event.level == .success ? "checkmark.circle.fill" : event.level == .error || event.level == .warning ? "exclamationmark.circle.fill" : "circle.dotted")
                                    .font(.system(size: 10)).foregroundStyle(event.level == .success ? Theme.green : event.level == .error || event.level == .warning ? Theme.accent("peach") : Theme.purple)
                                    .frame(width: 12).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(event.stage.title).font(.system(size: 10, weight: .semibold))
                                        Spacer()
                                        Text(String(format: "+%.3fs", max(0, event.date.timeIntervalSince(attempt.startedAt))))
                                            .font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.secondary)
                                    }
                                    Text(event.message).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let failure = attempt.failure {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Check next").font(.system(size: 11, weight: .semibold))
                                Text(failure.suggestion).font(.system(size: 10)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                if let url = failure.documentationURL { Link("Oracle error reference ↗", destination: url).font(.system(size: 10)).foregroundStyle(Theme.purple) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.tint("peach"), in: RoundedRectangle(cornerRadius: 8))
                            DisclosureGroup("Original error", isExpanded: $showOriginal) {
                                VStack(alignment: .leading, spacing: 7) {
                                    if let code = failure.errorCode { Text("Vendor code: \(String(code))") }
                                    if let state = failure.sqlState { Text("SQLState: \(state)") }
                                    Text(failure.message)
                                    ForEach(Array(failure.details.enumerated()), id: \.offset) { _, cause in Text(cause) }
                                }.font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.system(size: 10, weight: .medium))
                        }
                    } else {
                        Text("Test connection을 누르면 실제 연결 단계와 소요 시간이 표시됩니다. 접속·인증은 Oracle 드라이버가 함께 처리합니다.")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineSpacing(4)
                    }
                }.padding(.trailing, 5).padding(.bottom, 8)
            }
            Text("비밀번호는 진단 기록과 복사한 보고서에 포함하지 않습니다.").font(.system(size: 9)).foregroundStyle(Theme.secondary)
        }.padding(15).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: attempt?.id) { _, _ in copied = false; showOriginal = true }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 85, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10))
    }
}

struct ConnectionDetailsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let connection: DBConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(connection.name).font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
                IconButton(icon: "xmark", help: "Close") { dismiss() }
            }
            ConnectionDiagnosticsView(connection: connection, attempt: store.connectionAttempts[connection.id]).frame(height: 560)
            HStack {
                Text("Latest attempt in this app session").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                SoftButton(title: "Done", icon: "checkmark", prominent: true) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 520).background(Theme.canvas).foregroundStyle(Theme.ink)
    }
}

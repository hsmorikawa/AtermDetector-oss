import SwiftUI

/// 単一 IP デバッグ検索シート。指定 IP への照会の生応答を確認できる。
struct SingleProbeView: View {
    let viewModel: ScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var ipText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("単一 IP 検索 (デバッグ)")
                .font(.headline)

            HStack {
                TextField("IPアドレス (例: 192.168.0.1)", text: $ipText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(probe)
                Button("検索", action: probe)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ipText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isProbing)
            }

            if let error = viewModel.probeError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if viewModel.isProbing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("照会中…")
                }
            }

            if let result = viewModel.probeResult {
                resultView(result)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("閉じる") {
                    viewModel.clearProbe()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 320)
    }

    private func probe() {
        viewModel.probeSingle(ip: ipText)
    }

    private func resultView(_ result: ProbeResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let device = result.device {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Aterm を検出: \(device.name) (\(device.modeName))")
                    }
                    LabeledContent("MACアドレス") {
                        Text(device.macAddress ?? "-")
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    if let url = device.setupURL {
                        Link("クイック設定Web を開く: \(url.absoluteString)", destination: url)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(result.productNameRaw == nil ? "応答がありません" : "Aterm ではありません")
                    }
                }
                Divider()
                LabeledContent("機種名照会応答") {
                    Text(displayRaw(result.productNameRaw))
                        .textSelection(.enabled)
                }
                LabeledContent("動作モード照会応答") {
                    Text(displayRaw(result.sysModeRaw))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func displayRaw(_ raw: String?) -> String {
        guard let raw else { return "(応答なし)" }
        let normalized = AtermResponse.normalize(raw)
        return normalized.isEmpty ? "(空応答)" : normalized
    }
}

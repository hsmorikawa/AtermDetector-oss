import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScanViewModel()
    @State private var isSingleProbePresented = false

    var body: some View {
        VStack(spacing: 0) {
            deviceTable
            Divider()
            statusBar
        }
        .frame(minWidth: 600, minHeight: 340)
        .toolbar {
            ToolbarItem {
                Button {
                    isSingleProbePresented = true
                } label: {
                    Label("単一IP検索", systemImage: "magnifyingglass")
                }
                .help("指定した IP アドレスだけを調べる (デバッグ用)")
                .disabled(viewModel.isScanning)
            }
            ToolbarItem {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("再スキャン", systemImage: "arrow.clockwise")
                }
                .help("ローカルネットワークを再スキャンする")
                .disabled(viewModel.isScanning)
            }
        }
        .sheet(isPresented: $isSingleProbePresented) {
            SingleProbeView(viewModel: viewModel)
        }
        .task {
            viewModel.startScan()
        }
        .onDisappear {
            viewModel.cancelScan()
        }
    }

    private var deviceTable: some View {
        Table(viewModel.devices) {
            TableColumn("機種名", value: \.name)
            TableColumn("動作モード", value: \.modeName)
            TableColumn("MACアドレス") { device in
                Text(device.macAddress ?? "-")
                    .monospaced()
                    .textSelection(.enabled)
            }
            TableColumn("クイック設定Web") { device in
                if let url = device.setupURL {
                    Link(url.absoluteString, destination: url)
                } else {
                    Text("-")
                }
            }
        }
        .overlay {
            overlayContent
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case let .scanning(done, total):
            if viewModel.devices.isEmpty {
                ContentUnavailableView {
                    Label("スキャン中…", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("\(done) / \(total)")
                }
            }
        case let .finished(count):
            if count == 0 {
                ContentUnavailableView {
                    Label("Aterm が見つかりませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(
                        """
                        macOS 15 以降では「システム設定 > プライバシーとセキュリティ > \
                        ローカルネットワーク」で AtermDetector を許可し、アプリを再起動してください。
                        """
                    )
                }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("スキャンできません", systemImage: "network.slash")
            } description: {
                Text(message)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusText
            Spacer()
            if let range = viewModel.scanRange {
                Text(rangeDescription(of: range))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.state {
        case .idle:
            Text("待機中")
        case let .scanning(done, total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 140)
                Text("スキャン中… \(done) / \(total)")
            }
        case let .finished(count):
            Text("検索完了 (\(count) 台検出)")
        case .failed:
            Text("エラー")
        }
    }

    private func rangeDescription(of range: ScanRange) -> String {
        guard let first = range.targets.first, let last = range.targets.last else {
            return range.interfaceName
        }
        let lastOctet = last.split(separator: ".").last.map(String.init) ?? last
        var text = "\(range.interfaceName): \(first) - .\(lastOctet)"
        if range.isTruncated {
            text += " (範囲を254件に制限)"
        }
        return text
    }
}

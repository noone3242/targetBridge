import SwiftUI

struct TBPhysicalDisplayBrightnessView: View {
    @ObservedObject var service: TBPhysicalDisplayBrightnessService
    let language: TBDisplaySenderLanguage

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))

                    Text(hardwareOnlyTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        service.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(refreshTitle)
                    .disabled(service.isRefreshing)
                }

                if service.displays.isEmpty {
                    HStack(spacing: 10) {
                        if service.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "display")
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            service.isRefreshing
                                ? detectingTitle
                                : noDisplaysTitle
                        )
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(service.displays.enumerated()), id: \.element.id) {
                            index,
                            display in
                            displayRow(display)
                            if index < service.displays.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func displayRow(
        _ display: TBPhysicalDisplayBrightnessDevice
    ) -> some View {
        HStack(spacing: 10) {
            Image(
                systemName: display.isBuiltIn
                    ? "laptopcomputer"
                    : "display"
            )
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(statusText(display.availability))
                    .font(.caption2)
                    .foregroundStyle(
                        display.availability.isSupported
                            ? Color.secondary
                            : Color.orange
                    )
            }
            .frame(width: 158, alignment: .leading)

            Image(systemName: "sun.min.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Slider(
                value: SwiftUI.Binding<Double>(
                    get: {
                        display.brightness
                    },
                    set: {
                        service.setBrightness($0, for: display.id)
                    }
                ),
                in: 0...1
            )
            .tint(.orange)
            .disabled(!display.availability.isSupported)

            Image(systemName: "sun.max.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(
                "\(Int((display.brightness * 100).rounded()))%"
            )
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    private func statusText(
        _ availability: TBPhysicalDisplayBrightnessAvailability
    ) -> String {
        switch (availability, language) {
        case (.native, .chinese):
            return "原生"
        case (.native, _):
            return "Native"
        case (.ddc, .chinese):
            return "DDC/CI"
        case (.ddc, _):
            return "DDC/CI"
        case (.unsupported, .chinese):
            return "不支持硬件亮度"
        case (.unsupported, _):
            return "Hardware brightness unavailable"
        case let (.error(message), .chinese):
            return "写入失败 · \(message)"
        case let (.error(message), _):
            return "Brightness failed · \(message)"
        }
    }

    private var title: String {
        language == .chinese ? "本机显示器" : "Local Displays"
    }

    private var hardwareOnlyTitle: String {
        language == .chinese
            ? "真实硬件亮度"
            : "Hardware brightness"
    }

    private var refreshTitle: String {
        language == .chinese ? "刷新显示器" : "Refresh displays"
    }

    private var detectingTitle: String {
        language == .chinese ? "正在检测硬件亮度…" : "Detecting hardware brightness…"
    }

    private var noDisplaysTitle: String {
        language == .chinese
            ? "未发现可用的物理显示器"
            : "No physical displays found"
    }
}

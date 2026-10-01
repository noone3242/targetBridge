import AppKit

@MainActor
final class TBMenuBrightnessSliderView: NSView {
    private let slider = NSSlider()
    private let percentageLabel = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(
        device: TBPhysicalDisplayBrightnessDevice,
        onChange: @escaping (Double) -> Void
    ) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 52))

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: device.isBuiltIn
                ? "laptopcomputer"
                : "display",
            accessibilityDescription: nil
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        let backendLabel = NSTextField(
            labelWithString: Self.backendTitle(device.availability)
        )
        backendLabel.font = .systemFont(ofSize: 10)
        backendLabel.textColor = device.availability.isSupported
            ? .secondaryLabelColor
            : .systemOrange

        let labels = NSStackView(views: [nameLabel, backendLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = device.brightness
        slider.isContinuous = true
        slider.isEnabled = device.availability.isSupported
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false

        percentageLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .regular
        )
        percentageLabel.textColor = .secondaryLabelColor
        percentageLabel.alignment = .right
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false
        updatePercentage()

        addSubview(icon)
        addSubview(labels)
        addSubview(slider)
        addSubview(percentageLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.widthAnchor.constraint(equalToConstant: 132),

            slider.leadingAnchor.constraint(equalTo: labels.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(
                equalTo: percentageLabel.leadingAnchor,
                constant: -10
            ),

            percentageLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -12
            ),
            percentageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentageLabel.widthAnchor.constraint(equalToConstant: 42)
        ])

        if !device.availability.isSupported {
            toolTip = Self.backendTitle(device.availability)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func sliderChanged() {
        updatePercentage()
        onChange(slider.doubleValue)
    }

    private func updatePercentage() {
        percentageLabel.stringValue =
            "\(Int((slider.doubleValue * 100).rounded()))%"
    }

    func setBrightnessForTesting(_ brightness: Double) {
        slider.doubleValue = brightness
        sliderChanged()
    }

    var percentageTextForTesting: String {
        percentageLabel.stringValue
    }

    var sliderEnabledForTesting: Bool {
        slider.isEnabled
    }

    private static func backendTitle(
        _ availability: TBPhysicalDisplayBrightnessAvailability
    ) -> String {
        switch availability {
        case .native:
            return "Native"
        case .ddc:
            return "DDC/CI"
        case .unsupported:
            return "Hardware brightness unavailable"
        case .error:
            return "Hardware write failed"
        }
    }
}

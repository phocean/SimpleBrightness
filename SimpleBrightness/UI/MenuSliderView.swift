import AppKit

/// Menu row: title and value on one line, a full-width slider below.
/// Used for each display's brightness and for the sync offset.
final class MenuSliderView: NSView {
    var onChange: ((Double) -> Void)?
    private let format: (Double) -> String
    private let step: Double?

    private let nameLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)

    /// - Parameters:
    ///   - step: values are rounded to this step (nil: continuous).
    ///   - centerMark: draws a tick at the middle of the track (the neutral value).
    init(title name: String,
         value: Double,
         range: ClosedRange<Double> = 0...1,
         step: Double? = nil,
         centerMark: Bool = false,
         format: @escaping (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }) {
        self.format = format
        self.step = step
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 52))

        nameLabel.stringValue = name
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if centerMark { slider.numberOfTickMarks = 3 }
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.setAccessibilityLabel(name)

        for view in [nameLabel, percentLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // 14 pt matches the text inset of standard menu items.
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        update(value: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Live update from the hardware. Ignored while the user drags, so the knob
    /// does not fight the finger.
    func update(value: Double) {
        // Skip only while the user drags *this* slider; once the button is up the
        // flag clears itself, so it cannot get stuck.
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if isTracking && buttonDown { return }
        isTracking = false
        slider.doubleValue = value
        percentLabel.stringValue = format(value)
    }

    private var isTracking = false

    @objc private func sliderMoved(_ sender: NSSlider) {
        isTracking = NSEvent.pressedMouseButtons & 1 != 0
        var value = sender.doubleValue
        if let step { value = (value / step).rounded() * step }
        percentLabel.stringValue = format(value)
        onChange?(value)
    }
}

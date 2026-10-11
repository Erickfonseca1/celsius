import SwiftUI

/// Track with a warm fill up to a tall thumb, flanked by − and + buttons.
/// Dragging updates the value live; `onCommit` fires when the drag ends.
struct TemperatureSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    var onStep: (Double) -> Void

    @State private var dragValue: Double?

    private let trackHeight: CGFloat = 44
    private let thumbSize = CGSize(width: 22, height: 32)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                CircleIconButton(systemName: "minus", label: "Lower temperature") { onStep(-step) }
                track
                CircleIconButton(systemName: "plus", label: "Raise temperature") { onStep(step) }
            }
            HStack {
                Text("\(Labels.temperature(range.lowerBound))°")
                Spacer()
                Text("\(Labels.temperature(range.upperBound))°")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 48)
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let shown = dragValue ?? value
            let usable = proxy.size.width - thumbSize.width - 8
            let fraction = (shown - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = 4 + usable * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.warmFill)
                    .frame(width: thumbX + thumbSize.width + 4)

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.85)], startPoint: .top, endPoint: .bottom))
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: thumbX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newValue = snapped(at: gesture.location.x, usable: usable)
                        if newValue != dragValue {
                            dragValue = newValue
                            onChange(newValue)
                        }
                    }
                    .onEnded { gesture in
                        let newValue = snapped(at: gesture.location.x, usable: usable)
                        dragValue = nil
                        onCommit(newValue)
                    }
            )
            .animation(dragValue == nil ? .snappy(duration: 0.25) : nil, value: shown)
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(Labels.temperature(value)) degrees")
        .accessibilityAdjustableAction { direction in
            onStep(direction == .increment ? step : -step)
        }
    }

    private func snapped(at x: CGFloat, usable: CGFloat) -> Double {
        let fraction = min(max((x - 4 - thumbSize.width / 2) / usable, 0), 1)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        let steps = ((raw - range.lowerBound) / step).rounded()
        return min(range.lowerBound + steps * step, range.upperBound)
    }
}

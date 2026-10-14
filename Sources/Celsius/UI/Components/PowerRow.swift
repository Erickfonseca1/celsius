import CelsiusCore
import SwiftUI

/// The estimated draw, in the same row style as the Control Center toggles: a bolt, the watts, what
/// the figure covers, and a level bar. A figure that isn't measured yet is dimmed.
struct PowerRow: View {
    var reading: PowerReading?
    var tint: Color
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(Labels.power(reading))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reading?.watts ?? 0))
                    .opacity(reading?.isMeasured == true ? 1 : 0.7)
                Text(Labels.powerDetail(reading, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            LevelBar(fraction: (reading?.watts ?? 0) / Theme.powerScale, tint: tint)
                .frame(width: 64, height: 6)
                .opacity(reading?.isMeasured == true ? 1 : 0.45)
        }
        .animation(.snappy(duration: 0.4), value: reading?.watts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Power")
        .accessibilityValue("\(Labels.power(reading)), \(Labels.powerDetail(reading, now: now))")
    }
}

/// A thin capsule filled to `fraction`, like the level bars in Control Center.
private struct LevelBar: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

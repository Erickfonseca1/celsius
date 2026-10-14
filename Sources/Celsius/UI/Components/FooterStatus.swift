import CelsiusCore
import SwiftUI

/// One-line connection status: a transient error if there is one, otherwise the connection state.
struct FooterStatus: View {
    var store: ACStore

    private struct Indicator {
        var icon: String
        var text: String
        var color: Color = Theme.secondaryText
    }

    var body: some View {
        let indicator = indicator
        HStack(spacing: 6) {
            Image(systemName: indicator.icon)
                .foregroundStyle(indicator.color)
            Text(indicator.text)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .animation(.easeInOut(duration: 0.2), value: indicator.text)
    }

    private var indicator: Indicator {
        if let message = store.transientMessage {
            return Indicator(icon: "exclamationmark.triangle", text: message, color: Theme.warning)
        }
        return switch store.connection {
        case .connected where store.isReconnecting:
            Indicator(icon: "arrow.triangle.2.circlepath", text: "Reconnecting…", color: Theme.warning)
        case .connected where store.isSending:
            Indicator(icon: "arrow.triangle.2.circlepath", text: "Updating…")
        case .connected:
            Indicator(icon: "checkmark.shield", text: "Connected")
        case .loading:
            Indicator(icon: "arrow.triangle.2.circlepath", text: "Connecting…")
        case .offline(let message):
            Indicator(icon: "wifi.slash", text: message, color: Theme.warning)
        case .unauthorized:
            Indicator(icon: "key", text: "Token and key were refused", color: Theme.warning)
        case .deviceError:
            Indicator(icon: "exclamationmark.triangle", text: "The unit reports an error", color: Theme.warning)
        case .needsSetup:
            Indicator(icon: "key", text: "Not set up")
        }
    }
}

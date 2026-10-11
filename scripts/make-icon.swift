// Renders the 1024×1024 app icon: a dark squircle with the wall unit and cool airflow.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 230, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 6)
                )
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.8, blue: 1).opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 330))
                .frame(width: 760, height: 360)
                .offset(y: 170)
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 60, style: .continuous)
                        .fill(LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.1))
                        .frame(width: 560, height: 46)
                        .padding(.bottom, 34)
                    Text("23")
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.5, green: 0.85, blue: 1))
                        .shadow(color: Color(red: 0.4, green: 0.8, blue: 1), radius: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 56)
                        .padding(.trailing, 80)
                }
                .frame(width: 680, height: 270)
                Canvas { context, size in
                    context.addFilter(.blur(radius: 5))
                    for i in 0..<7 {
                        let x = size.width * (0.14 + 0.72 * Double(i) / 6)
                        let spread = (x - size.width / 2) * 0.55
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 20))
                        path.addQuadCurve(to: CGPoint(x: x + spread, y: size.height - 30), control: CGPoint(x: x + spread * 0.2, y: size.height * 0.55))
                        context.stroke(path, with: .linearGradient(
                            Gradient(colors: [Color(red: 0.55, green: 0.82, blue: 1).opacity(0.9), Color(red: 0.55, green: 0.82, blue: 1).opacity(0)]),
                            startPoint: CGPoint(x: x, y: 20), endPoint: CGPoint(x: x, y: size.height - 30)
                        ), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    }
                }
                .frame(width: 680, height: 300)
            }
            .offset(y: 40)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
        // macOS icons leave a margin around the squircle.
        .scaleEffect(824 / 1024)
        .frame(width: 1024, height: 1024)
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("Couldn't render icon") }
    try! png.write(to: URL(fileURLWithPath: output))
}

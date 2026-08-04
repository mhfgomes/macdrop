import SwiftUI

enum MacDropStyle {
    static let accent = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.76, blue: 0.98),
            Color(red: 0.48, green: 0.30, blue: 0.98),
            Color(red: 0.98, green: 0.25, blue: 0.48)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let background = LinearGradient(
        colors: [Color.accentColor.opacity(0.055), .clear],
        startPoint: .topLeading,
        endPoint: .center
    )
}

private struct MacDropCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.055), radius: 14, y: 5)
    }
}

extension View {
    func macDropCard() -> some View {
        modifier(MacDropCardModifier())
    }
}

struct MacDropPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MacDropStyle.background
            content
        }
    }
}

struct MacDropSectionTitle: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
        }
    }
}

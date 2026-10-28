import AppKit
import SwiftUI

extension Color {
    static let dropAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.48, blue: 0.53, alpha: 1)
            : NSColor(red: 0.80, green: 0.17, blue: 0.29, alpha: 1)
    })
}

extension View {
    func card() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        )
    }
}

struct Banner<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(.init(text)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension Banner where Accessory == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

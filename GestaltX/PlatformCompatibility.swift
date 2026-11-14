// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// iOS 16 replacement for SwiftUI's iOS 17 ContentUnavailableView.
struct GestaltXEmptyState: View {
    let title: String
    let systemImage: String
    let description: Text?

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    static func search(text: String) -> GestaltXEmptyState {
        let description = text.isEmpty ? nil : Text(String(format: L("No matches for “%@”"), text))
        return GestaltXEmptyState(L("No Results"), systemImage: "magnifyingglass", description: description)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let description {
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    @ViewBuilder
    func gxListSectionSpacing(_ points: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            self.listSectionSpacing(points)
        } else {
            self
        }
    }

    @ViewBuilder
    func gxPresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func gxSafeAreaBottomPadding(_ amount: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            self.safeAreaPadding(.bottom, amount)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: amount)
            }
        }
    }
}

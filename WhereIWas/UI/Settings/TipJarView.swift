import StoreKit
import SwiftUI

/// The tip screen, pushed from Settings → About → "Support the developer".
///
/// Three consumables that unlock nothing. Names and prices come from the store,
/// in the buyer's language and currency: the catalog carries none of them.
struct TipJarView: View {
    @Environment(TipJar.self) private var tipJar
    @Environment(\.purchase) private var purchase

    var body: some View {
        DetailScreen(title: "tip.title") {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                Text("tip.header")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                tips
                status
                    .padding(.horizontal, 2)
            }
        }
        .task { await tipJar.load() }
    }

    @ViewBuilder
    private var tips: some View {
        if tipJar.isLoading && tipJar.products.isEmpty {
            Card {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } else if tipJar.isUnavailable {
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                    Text("tip.unavailable")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Button("tip.retry") {
                        Task { await tipJar.load() }
                    }
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.accent)
                    .buttonStyle(.plain)
                }
            }
        } else {
            RowCard {
                ForEach(tipJar.products) { product in
                    if product.id != tipJar.products.first?.id {
                        RowSeparator()
                    }
                    row(product)
                }
            }
        }
    }

    private func row(_ product: Product) -> some View {
        Button {
            Task { await tipJar.buy(product, with: purchase) }
        } label: {
            HStack(spacing: 12) {
                IconBadge(systemImage: "cup.and.saucer")
                Text(verbatim: product.displayName)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: Theme.Spacing.row)
                if tipJar.state == .purchasing(product.id) {
                    ProgressView()
                } else {
                    // The price comes from the store, in the buyer's currency.
                    Text(verbatim: product.displayPrice)
                        .font(Theme.Typography.rowValue)
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, Theme.Spacing.card)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    @ViewBuilder
    private var status: some View {
        switch tipJar.state {
        case .thanked:
            Label("tip.thanks", systemImage: "heart.fill")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Palette.accent)
        case .pending:
            note("tip.pending")
        case .failed:
            note("tip.failed")
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(Theme.Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isPurchasing: Bool {
        if case .purchasing = tipJar.state { true } else { false }
    }
}

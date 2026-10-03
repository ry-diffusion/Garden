import SwiftUI

/// Every screen a tab can push. Destinations are registered once, at the root of each NavigationStack,
/// so value-based links work from any depth (DESIGN §15). Registering them inside pushed views made
/// SwiftUI push and pop in a loop.
enum Route: Hashable {
    case review
    case category(SpendCategory)
    case uncategorized
}

extension View {
    func gardenDestinations() -> some View {
        self
            .navigationDestination(for: Movement.self) { MovementDetailView(movement: $0) }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .review: ReviewView()
                case .category(let category): CategoryDetailView(category: category, cycle: Preferences.currentCycle)
                case .uncategorized: UncategorizedView(cycle: Preferences.currentCycle)
                }
            }
    }
}

import SwiftUI

struct SettingsRootView: View {
    @State private var selectedTab: SettingsTab? = .gestures

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch selectedTab {
            case .gestures, .none:
                GesturesView()
            case .recognition:
                RecognitionView()
            case .appearance:
                AppearanceView()
            case .advanced:
                AdvancedView()
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 780, minHeight: 520)
    }
}

import SwiftUI

enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case sets
    case study
    case session
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .sets: "학습 세트"
        case .study: "학습"
        case .session: "실험 세션"
        case .settings: "설정"
        }
    }

    var systemImage: String {
        switch self {
        case .sets: "folder"
        case .study: "book"
        case .session: "timer"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .sets

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection ?? .sets {
            case .sets:
                LearningSetsView()
            case .study:
                StudyView()
            case .session:
                ContentUnavailableView("실험 세션은 준비 중입니다", systemImage: "timer", description: Text("마일스톤 5에서 구현합니다."))
            case .settings:
                SettingsView()
            }
        }
    }
}

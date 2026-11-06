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

    /// 실험 세션 중에는 세션 화면과 (잠긴) 설정만 보인다.
    private var items: [SidebarItem] {
        model.isSettingsLocked ? [.session, .settings] : SidebarItem.allCases
    }

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
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
                SessionView()
            case .settings:
                SettingsView()
            }
        }
        .onAppear { if model.isSettingsLocked { selection = .session } }
        .onChange(of: model.isSettingsLocked) { _, locked in
            if locked { selection = .session }
        }
        .onChange(of: selection) { _, item in
            if let item, !items.contains(item) { selection = .session }
        }
    }
}

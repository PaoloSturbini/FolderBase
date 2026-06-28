import SwiftUI

struct MainWindowView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            FileTableView()
        }
        .frame(minWidth: 1100, minHeight: 650)
    }
}

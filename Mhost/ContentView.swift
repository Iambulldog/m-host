import SwiftUI

struct ContentView: View {
    @State private var selectedTab = "SSH"

    var body: some View {
        TabView(selection: $selectedTab) {
            SSHView()
                .tabItem {
                    Label("SSH", systemImage: "terminal")
                }
                .tag("SSH")
            
            HostsManagerView()
                .tabItem {
                    Label("Hosts", systemImage: "server.rack")
                }
                .tag("Hosts")

            ProxyView()
                .tabItem {
                    Label("Proxy", systemImage: "arrow.triangle.swap")
                }
                .tag("Proxy")

            MkcertView()
                .tabItem {
                    Label("mkcert", systemImage: "lock.shield")
                }
                .tag("mkcert")

            SSHKeyManagerView()
                .tabItem {
                    Label("SSH Keys", systemImage: "key.fill")
                }
                .tag("SSHKeys")
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView()
}

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SSHView()
                .tabItem {
                    Label("SSH", systemImage: "terminal")
                }
            HostsManagerView()
                .tabItem {
                    Label("Hosts", systemImage: "server.rack")
                }

            ProxyView()
                .tabItem {
                    Label("Proxy", systemImage: "arrow.triangle.swap")
                }

            MkcertView()
                .tabItem {
                    Label("mkcert", systemImage: "lock.shield")
                }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

#Preview {
    ContentView()
}

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
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

            SSHView()
                .tabItem {
                    Label("SSH", systemImage: "terminal")
                }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

#Preview {
    ContentView()
}

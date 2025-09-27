//
//  MirrorApp.swift
//  Mirror
//
//  Created by Theo on 9/20/25.
//

import SwiftUI
import BackgroundTasks
import Combine

@main
struct MirrorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var discoveryHolder = DiscoveryHolder()
    
    @State private var isLoaded = false

    private func performInitialLoad() async {
        // TODO: Replace this simulated delay with real startup work (e.g., data load, auth refresh)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run {
            isLoaded = true
            discoveryHolder.startDiscovery()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isLoaded {
                    ContentView()
                } else {
                    SplashView()
                }
            }
            .task {
                if !isLoaded {
                    await performInitialLoad()
                }
            }
            .task(priority: .background) {
                // Defer BGTask setup until after first frame to ensure splash shows immediately
                await Task.yield()
                await Task.yield()
                BackgroundRefresh.shared.register()
                BackgroundRefresh.shared.scheduleIfNeeded()
                BackgroundRefresh.shared.setReloadAction {
                    await CalendarInterface.shared.reload()
                    await MainActor.run {
                        NotificationCenter.default.post(name: .BackgroundRefreshPerformReload, object: nil)
                    }
                }
            }
            .environmentObject(CalendarInterface.shared)
            .environmentObject(discoveryHolder)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        Task.detached(priority: .background) {
            await BackgroundRefresh.shared.scheduleIfNeeded()
        }
    }
}

@MainActor
final class DiscoveryHolder: ObservableObject {
    @Published var isConnected: Bool = false
    let controller: MirrorDiscoveryController
    private var cancellables = Set<AnyCancellable>()

    init() {
        controller = MirrorDiscoveryController()
        controller.onManagerReady = { [weak self] manager in
            guard let self else { return }
            // Let the global MirrorManager adopt this connectivity manager so app-wide send APIs work.
            MirrorManager.shared.adopt(manager)

            Publishers.CombineLatest(manager.$isWebSocketConnected, manager.$isRESTReachable)
                .map { $0 || $1 }
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.isConnected = value
                }
                .store(in: &self.cancellables)
        }
    }
    
    func startDiscovery() {
        controller.start()
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                // App mark or title
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                Text("Loading…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
    }
}

#Preview {
    SplashView()
}

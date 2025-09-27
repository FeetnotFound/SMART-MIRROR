import BackgroundTasks
import SwiftUI

/// Replace "com.yourcompany.mirror.refresh" with your app's bundle identifier prefix + ".refresh"
private let taskIdentifier = "com.yourcompany.mirror.refresh"

@MainActor
public final class BackgroundRefresh {
    public static let shared = BackgroundRefresh()
    
    private var reloadAction: (() async -> Void)?
    private var currentTask: BGAppRefreshTask?
    
    private init() {}
    
    /// Inject the closure that performs the actual refresh work
    public func setReloadAction(_ action: @escaping () async -> Void) {
        self.reloadAction = action
        print("[BackgroundRefresh] Reload action set.")
    }
    
    /// Register the background task with the system.
    /// Call early in app lifecycle, typically during app launch.
    public func register() {
        guard #available(iOS 13.0, *) else {
            print("[BackgroundRefresh] BackgroundTasks not available on this iOS version.")
            return
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            self?.handle(task: task as! BGAppRefreshTask)
        }
        print("[BackgroundRefresh] Registered task with identifier: \(taskIdentifier)")
    }
    
    /// Schedule a background app refresh task if none is pending
    public func scheduleIfNeeded() {
        guard #available(iOS 13.0, *) else {
            print("[BackgroundRefresh] BackgroundTasks not available on this iOS version.")
            return
        }
        
        do {
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // 30 minutes from now
            
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundRefresh] Scheduled BGAppRefreshTaskRequest with earliestBeginDate ~30 minutes from now.")
        } catch {
            print("[BackgroundRefresh] Failed to schedule BGAppRefreshTaskRequest: \(error)")
        }
    }
    
    /// Handle the incoming BGAppRefreshTask. Perform the refresh work and set expiration handler.
    private func handle(task: BGAppRefreshTask) {
        print("[BackgroundRefresh] Handling BGAppRefreshTask: \(taskIdentifier)")
        self.currentTask = task
        
        // Schedule next refresh
        scheduleIfNeeded()
        
        // Expiration handler to cancel work if time runs out
        task.expirationHandler = { [weak self] in
            print("[BackgroundRefresh] Task expired. Cancelling work.")
            self?.currentTask = nil
        }
        
        Task {
            if let reloadAction = self.reloadAction {
                print("[BackgroundRefresh] Starting reload action.")
                await reloadAction()
                print("[BackgroundRefresh] Reload action completed.")
            } else {
                print("[BackgroundRefresh] No reload action set. Skipping reload.")
            }
            task.setTaskCompleted(success: true)
            self.currentTask = nil
            print("[BackgroundRefresh] Task marked completed successfully.")
        }
    }
}

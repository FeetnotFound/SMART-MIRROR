import Foundation
import BackgroundTasks
import EventKit
import SwiftUI

final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    private init() {}

    // Must match the Info.plist BGTaskSchedulerPermittedIdentifiers entry
    let refreshTaskIdentifier = "com.yourcompany.mirror.refresh"

    func register() {
        // Ensure this identifier is also listed in Info.plist under BGTaskSchedulerPermittedIdentifiers
        print("[BackgroundRefresh] Registering task identifier: \(refreshTaskIdentifier)")
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
#if DEBUG
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10) // 10 seconds for testing
#else
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes from now
#endif
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundRefresh] Submitted BGAppRefreshTaskRequest for \(refreshTaskIdentifier), earliestBeginDate: \(String(describing: request.earliestBeginDate)))")
        } catch {
            print("[BackgroundRefresh] Failed to schedule BGAppRefreshTaskRequest: \(error)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        print("[BackgroundRefresh] handleAppRefresh invoked at \(Date())")
        // Schedule the next one so the system keeps considering us
        schedule()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let operation = CalendarRefreshOperation()

        task.expirationHandler = {
            queue.cancelAllOperations()
        }

        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
        }

        queue.addOperation(operation)
    }
}

final class CalendarRefreshOperation: Operation {
    private let eventStore = EKEventStore()

    override func main() {
        if isCancelled { return }

        // Only proceed if authorized; do not prompt in background
        guard EKEventStore.authorizationStatus(for: .event) == .authorized else { return }

        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        guard let startDate = calendar.date(byAdding: .day, value: -3, to: todayStart),
              let endDateExclusive = calendar.date(byAdding: .day, value: 4, to: todayStart) else { return }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDateExclusive, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        if isCancelled { return }

        // Example: store a lightweight summary that the app can read on next launch/foreground
        UserDefaults.standard.set(events.count, forKey: "LastBackgroundEventCount")
    }
}

#if DEBUG
extension BackgroundRefreshManager {
    /// Manually run the background operation in foreground for debugging
    func runNowForDebug() {
        print("[BackgroundRefresh][DEBUG] Manually running CalendarRefreshOperation at \(Date())")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let operation = CalendarRefreshOperation()
        operation.completionBlock = {
            print("[BackgroundRefresh][DEBUG] CalendarRefreshOperation completed. Cancelled: \(operation.isCancelled)")
        }
        queue.addOperation(operation)
    }
}
#endif

// Hook BGTaskScheduler into app lifecycle
@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        BackgroundRefreshManager.shared.register()
        BackgroundRefreshManager.shared.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshManager.shared.schedule()
    }
}

//
//  ContentView.swift
//  Mirror
//
//  Created by Theo on 9/20/25.
//

import SwiftUI
import EventKit
import BackgroundTasks

extension Notification.Name {
    static let BackgroundRefreshPerformReload = Notification.Name("BackgroundRefreshPerformReload")
}

struct ContentView: View {
    @EnvironmentObject private var discovery: DiscoveryHolder
    @State private var isConnecting: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    Image(systemName: "house")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.tint)
                    Text("Mirror Home")
                        .font(.largeTitle).bold()

                    Button {
                        if isConnecting || discovery.isConnected { return }
                        Task {
                            isConnecting = true
                            if let conn = MirrorManager.shared.connectivity {
                                conn.connectWebSocket()
                                _ = await conn.getPing()
                            }
                            // Allow a brief window for the connection state to update; if not connected, stop showing connecting
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !discovery.isConnected {
                                isConnecting = false
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isConnecting ? Color.yellow : (discovery.isConnected ? Color.green : Color.red))
                                .frame(width: 10, height: 10)
                            Text(isConnecting ? "Connecting…" : (discovery.isConnected ? "Connected" : "Disconnected"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(PressScaleStyle())
                    .disabled(isConnecting || discovery.isConnected)
                    .accessibilityLabel(isConnecting ? "Connecting to mirror" : (discovery.isConnected ? "Connected to mirror" : "Disconnected from mirror"))

                    // Music Interface Section
                    VStack(spacing: 12) {
                        HStack {
                            Spacer()
                        }
                        .padding(.horizontal)

                        MusicInterface()
                            .font(.title2)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(UIColor.secondarySystemBackground))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.horizontal)
                    }

                    // Navigation links
                    NavigationLink {
                        UpcomingEventsView()
                    } label: {
                        Label("Open Upcoming Events", systemImage: "calendar")
                            .font(.headline)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.top, 40)
                .onChange(of: discovery.isConnected) { connected in
                    if connected {
                        isConnecting = false
                    }
                }
            }
        }
    }
}

struct UpcomingEventsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calendar = CalendarInterface()
    @State private var showEventsDump: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if calendar.events.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No upcoming events",
                                                   systemImage: "calendar",
                                                   description: Text("Grant calendar access or add events to see them here."))
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("No upcoming events")
                                    .font(.headline)
                                Text("Grant calendar access or add events to see them here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        // Build a 7-day timeline centered on today
                        let days = calendar.sevenDayWindow()
                        List {
                            ForEach(days, id: \.self) { dayStart in
                                let dayEvents = calendar.eventsIntersecting(dayStart: dayStart)
                                Section(header: Text(calendar.sectionTitle(for: dayStart, calendar: Calendar.current))) {
                                    if dayEvents.isEmpty {
                                        Text("No events")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(dayEvents, id: \.eventIdentifier) { event in
                                            HStack(alignment: .top, spacing: 10) {
                                                Capsule()
                                                    .fill(calendar.calendarColor(for: event).opacity(0.9))
                                                    .frame(width: 4)

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(calendar.eventTitle(event))
                                                        .font(.headline)
                                                    if let s = event.startDate, let e = event.endDate {
                                                        Text(calendar.dateRangeString(start: s, end: e, allDay: event.isAllDay))
                                                            .font(.subheadline)
                                                            .foregroundColor(.secondary)
                                                    } else {
                                                        Text("Dates unavailable")
                                                            .font(.subheadline)
                                                            .foregroundColor(.secondary)
                                                    }
                                                    Text(event.calendar.title.isEmpty ? "Calendar" : event.calendar.title)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(calendar.calendarColor(for: event).opacity(0.18))
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upcoming Events")
        }
        .task {
            await calendar.reload()
        }
        .task {
            let center = NotificationCenter.default
            let name = UIApplication.willTerminateNotification
            _ = center.notifications(named: name)
//            for await _ in center.notifications(named: name) {
//                calendar.printEventsDictionary()
//            }
        }
        .task {
            BackgroundRefresh.shared.setReloadAction {
                await calendar.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .BackgroundRefreshPerformReload)) { _ in
            Task { await calendar.reload() }
        }
        .refreshable {
            await calendar.reload()
        }
        .alert("Calendar Access", isPresented: $calendar.showAccessError) {
            if calendar.showSettingsButton, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(calendar.accessErrorMessage)
        }
        .onChange(of: scenePhase) { phase in
            if #available(iOS 17.0, *) {
                if phase == .active {
                    Task { await calendar.reload() }
                }
//                else if phase == .background {
//                    calendar.printEventsDictionary()
//                }
            } else {
                if phase == .active {
                    Task { await calendar.reload() }
                }
//                else if phase == .background {
//                    calendar.printEventsDictionary()
//                }
            }
        }
    }
}

// A subtle press animation for tappable indicators
private struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(DiscoveryHolder())
    }
}

struct UpcomingEventsView_Previews: PreviewProvider {
    static var previews: some View {
        UpcomingEventsView()
    }
}

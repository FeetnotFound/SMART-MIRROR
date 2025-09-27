import Foundation
import Combine
import Network
import EventKit

// Serializes WebSocket sends to prevent overlap/interference
private actor WSSendCoordinator {
    private var last: Task<Void, Never>? = nil
    func enqueue(_ operation: @escaping () async -> Void) async {
        let previous = last
        let task = Task {
            await previous?.value
            await operation()
        }
        last = task
        await task.value
    }
}

// MARK: - Models

public struct NowPlayingInfo: Codable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var position: TimeInterval
    public var isPlaying: Bool
}

public struct ControlEvent: Codable, Equatable {
    public var kind: String // "play","pause","next","previous","volume","trackChanged"
    public var value: Double? // for volume 0.0-1.0
    public var title: String?
    public var artist: String?
    public var album: String?
    public var timestamp: Date
}

// CalendarInterface currently casts [EKEvent] to [CalendarEvent].
// Provide a typealias so that compiles and we can accept EKEvent inputs.
public typealias CalendarEvent = EKEvent

// MARK: - Connectivity Manager

public final class MirrorConnectivityManager: NSObject, ObservableObject {
    // Published connectivity state
    @Published public private(set) var isWebSocketConnected: Bool = false
    @Published public private(set) var isRESTReachable: Bool = false

    // Endpoints
    public let restBaseURL: URL
    public let webSocketURL: URL

    // Internals
    private var webSocketTask: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var receiveTask: Task<Void, Never>?
    private let wsSendCoordinator = WSSendCoordinator()
    private var isSocketOpen: Bool = false
    private var pendingMessages: [URLSessionWebSocketTask.Message] = []

    // Constants matching the Python server
    private let restPort: Int = 8000

    public init(host: String, wsPort: Int, wsPath: String) {
        // REST base uses HTTP on port 8000
        var rest = URLComponents()
        rest.scheme = "http"
        rest.host = host
        rest.port = restPort
        self.restBaseURL = rest.url! // safe because host provided

        // WebSocket URL from Bonjour details
        var ws = URLComponents()
        ws.scheme = "ws"
        ws.host = host
        ws.port = wsPort
        ws.path = wsPath.hasPrefix("/") ? wsPath : "/" + wsPath
        self.webSocketURL = ws.url!

        super.init()
    }

    deinit {
        disconnectWebSocket()
    }

    // MARK: - WebSocket

    public func connectWebSocket() {
        guard webSocketTask == nil else { return }
        let task = session.webSocketTask(with: webSocketURL)
        self.webSocketTask = task
        task.resume()
        isSocketOpen = false
        startReceiveLoop()
        // Send an initial hello to help server logs
        sendText("iOS client connected")
    }

    public func disconnectWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        isSocketOpen = false
        pendingMessages.removeAll()
        Task { @MainActor in self.isWebSocketConnected = false }
    }

    private func startReceiveLoop() {
        receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let ws = self.webSocketTask else { break }
                do {
                    let msg = try await ws.receive()
                    switch msg {
                    case .string(let text):
                        print("[WebSocket] Received text: \(text)")
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let type = json["type"] as? String, type == "control",
                           let action = json["action"] as? String {
                            await MainActor.run {
                                switch action {
                                case "playPause":
                                    SystemMediaController.togglePlayPause()
                                case "skip":
                                    SystemMediaController.nextTrack()
                                case "back":
                                    SystemMediaController.previousTrack()
                                case "volumeUp":
                                    SystemMediaController.volumeUp(step: 0.10)
                                case "volumeDown":
                                    SystemMediaController.volumeDown(step: 0.10)
                                default:
                                    print("[Control] Unknown action: \(action)")
                                }
                            }
                        } else {
                            // Not a control packet we recognize; keep logging
                        }
                    case .data(let data):
                        print("[WebSocket] Received \(data.count) bytes")
                    @unknown default:
                        print("[WebSocket] Received unknown message")
                    }
                } catch {
                    await MainActor.run {
                        self.isWebSocketConnected = false
                    }
                    print("[WebSocket] Receive loop error: \(error)")
                    break
                }
            }
        }
    }

    public func sendText(_ text: String) {
        Task {
            await wsSendCoordinator.enqueue { [weak self] in
                await self?.sendTextAwaitingCompletion(text)
            }
        }
    }

    // Build a JSON envelope with "type" first and send it via WebSocket, serializing sends
    public func sendJSONMessage<T: Encodable>(type: String, payload: T) async {
        // Encode payload separately so we can place "type" first in the envelope
        let encoder = JSONEncoder()
        // Keep payload key order stable for readability on the server
        encoder.outputFormatting.insert(.sortedKeys)
        guard let payloadData = try? encoder.encode(payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            print("[WebSocket] Failed to encode payload for type=\(type)")
            return
        }
        let text = "{\"type\":\"\(type)\",\"payload\":\(payloadString)}"
        await wsSendCoordinator.enqueue { [weak self] in
            await self?.sendTextAwaitingCompletion(text)
        }
    }

    private func sendTextAwaitingCompletion(_ text: String) async {
        // Ensure we have (or are establishing) a task
        if webSocketTask == nil {
            connectWebSocket()
        }

        // Ensure a newline delimiter to help line-oriented servers/logs
        let textToSend = text.hasSuffix("\n") ? text : text + "\n"

        // If not open yet, queue and return
        if !isSocketOpen {
            pendingMessages.append(.string(textToSend))
            print("[WebSocket] Queued message until socket opens")
            return
        }

        guard let ws = webSocketTask else {
            print("[WebSocket] Not connected; cannot send text")
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ws.send(.string(textToSend)) { [weak self] error in
                if let error = error {
                    Task { @MainActor in self?.isWebSocketConnected = false }
                    print("[WebSocket] Send error: \(error)")
                }
                cont.resume()
            }
        }
    }

    private func drainPendingMessages() {
        guard isSocketOpen, let ws = webSocketTask else { return }
        while !pendingMessages.isEmpty {
            let msg = pendingMessages.removeFirst()
            ws.send(msg) { [weak self] error in
                if let error = error {
                    Task { @MainActor in self?.isWebSocketConnected = false }
                    print("[WebSocket] Send error (drain): \(error)")
                }
            }
        }
    }

    // MARK: - REST

    @discardableResult
    public func getPing() async -> Bool {
        let url = restBaseURL.appendingPathComponent("ping")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                await MainActor.run { self.isRESTReachable = true }
                return true
            }
        } catch {
            print("[REST] Ping failed: \(error)")
        }
        await MainActor.run { self.isRESTReachable = false }
        return false
    }

    public func sendNowPlaying(_ info: NowPlayingInfo) async {
        let url = restBaseURL.appendingPathComponent("nowPlaying")
        await postJSON(url: url, body: info)
    }

    public func sendCalendar(rangeStart: Date, rangeEnd: Date, events: [CalendarEvent]) async {
        // Minimal, stable payload for the Python bridge
        struct OutEvent: Codable { let calendar: String; let event: String; let time: String; let location: String }
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeStyle = .short

        let outEvents: [OutEvent] = events.compactMap { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return nil }
            let name = (ev.title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = ev.isAllDay ? "All-day" : "\(fmt.string(from: s))–\(fmt.string(from: e))"
            return OutEvent(
                calendar: ev.calendar.title.isEmpty ? "Calendar" : ev.calendar.title,
                event: name.isEmpty ? "Untitled" : name,
                time: time,
                location: (ev.location ?? "")
            )
        }
        struct Payload: Codable { let rangeStart: Date; let rangeEnd: Date; let events: [OutEvent] }
        let payload = Payload(rangeStart: rangeStart, rangeEnd: rangeEnd, events: outEvents)
        let url = restBaseURL.appendingPathComponent("calendarUpdate")
        await postJSON(url: url, body: payload)
    }

    private func postJSON<T: Encodable>(url: URL, body: T) async {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting.insert(.sortedKeys)
            req.httpBody = try encoder.encode(body)
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                print("[REST] POST \(url.lastPathComponent) -> status \(http.statusCode)")
                await MainActor.run { self.isRESTReachable = (200...299).contains(http.statusCode) }
            }
        } catch {
            print("[REST] POST error to \(url): \(error)")
            await MainActor.run { self.isRESTReachable = false }
        }
    }
}

// Coalesces rapid now-playing updates and ensures REST and WS sends use the same snapshot
private actor NowPlayingSendQueue {
    private var pending: NowPlayingInfo?
    private var sending = false

    func submit(_ info: NowPlayingInfo, sender: @escaping (NowPlayingInfo) async -> Void) async {
        pending = info
        if sending { return }
        sending = true
        while let current = pending {
            pending = nil
            await sender(current)
        }
        sending = false
    }
}

// MARK: - Manager facade used by the app

@MainActor
public final class MirrorManager {
    public static let shared = MirrorManager()

    private let nowPlayingQueue = NowPlayingSendQueue()
    private var lastRESTNowPlaying: NowPlayingInfo?
    private var lastRESTSendDate: Date?

    private(set) var connectivity: MirrorConnectivityManager?
    @Published public private(set) var lastNowPlaying: NowPlayingInfo?

    private init() {}
    // Wrapper to emit a Codable WS message for now playing
    private struct NowPlayingMessage: Codable {
        let type: String = "nowPlaying"
        let payload: NowPlayingInfo
    }

    private func ensureConnectivityIfPossible() async -> MirrorConnectivityManager? {
        guard let conn = connectivity else {
            print("[MirrorManager] No connectivity manager; cannot ensure connection.")
            return nil
        }
        if !conn.isWebSocketConnected {
            conn.connectWebSocket()
            // brief delay to allow socket to come up
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !conn.isRESTReachable {
            _ = await conn.getPing()
        }
        return conn
    }

    private func shouldSendREST(for info: NowPlayingInfo) -> Bool {
        if lastRESTNowPlaying == nil { return true }
        let last = lastRESTNowPlaying!
        if info.title != last.title || info.artist != last.artist || info.album != last.album { return true }
        if info.isPlaying != last.isPlaying { return true }
        if let lastDate = lastRESTSendDate, Date().timeIntervalSince(lastDate) >= 10 { return true }
        return false
    }

    private func _sendNowPlayingInternal(_ info: NowPlayingInfo) async {
        guard let conn = await ensureConnectivityIfPossible() else { return }
        // Throttle REST: send on track change, play/pause change, or every 10s
        if shouldSendREST(for: info) {
            await conn.sendNowPlaying(info)
            lastRESTNowPlaying = info
            lastRESTSendDate = Date()
        }
        // Always send WebSocket at 1 Hz with the same snapshot
        await conn.sendJSONMessage(type: "nowPlaying", payload: info)
    }

    public func adopt(_ manager: MirrorConnectivityManager) {
        self.connectivity = manager
        // Attempt a WS connect and a ping as soon as we adopt
        manager.connectWebSocket()
        Task { await manager.getPing() }
    }

    public func sendTestPacket() async {
        guard let conn = await ensureConnectivityIfPossible() else {
            print("[MirrorManager] No connectivity manager available to send test packet.")
            return
        }
        conn.sendText("Test  Packet")
        _ = await conn.getPing()
    }

    public func updateNowPlaying(_ info: NowPlayingInfo) {
        self.lastNowPlaying = info
    }

    public func sendNowPlaying(_ info: NowPlayingInfo) async {
        await nowPlayingQueue.submit(info) { [weak self] latest in
            guard let self else { return }
            await self._sendNowPlayingInternal(latest)
        }
    }

    public func sendCalendar(rangeStart: Date, rangeEnd: Date, events: [CalendarEvent]) async {
        guard let conn = await ensureConnectivityIfPossible() else { return }
        await conn.sendCalendar(rangeStart: rangeStart, rangeEnd: rangeEnd, events: events)
    }

    public func sendControlEvent(_ event: ControlEvent) async {
        guard let conn = connectivity else { return }
        await conn.sendJSONMessage(type: "controlEvent", payload: event)
    }

    private func infoToDictionary(_ info: NowPlayingInfo) -> [String: Any] {
        [
            "title": info.title,
            "artist": info.artist,
            "album": info.album,
            "duration": info.duration,
            "position": info.position,
            "isPlaying": info.isPlaying
        ]
    }
}

extension MirrorConnectivityManager: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        isSocketOpen = true
        Task { @MainActor in self.isWebSocketConnected = true }
        print("[WebSocket] didOpen (protocol: \(proto ?? "nil"))")
        drainPendingMessages()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isSocketOpen = false
        Task { @MainActor in self.isWebSocketConnected = false }
        print("[WebSocket] didClose: \(closeCode.rawValue)")
    }
}

// MARK: - Bonjour Discovery

@MainActor
public final class MirrorDiscoveryController: NSObject, ObservableObject {
    public var onManagerReady: ((MirrorConnectivityManager) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolvingService: NetService?

    private let serviceType = "_mirror._tcp."
    private let domain = "local."

    private var resolveAttempts: [ObjectIdentifier: Int] = [:]
    private let maxResolveAttempts: Int = 3

    override public init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: serviceType, inDomain: domain)
        print("[Bonjour] Searching for services of type \(serviceType) in \(domain)")
    }
}

extension MirrorDiscoveryController: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[Bonjour] Found service: \(service.name)")
        services.append(service)
        // Prefer the SmartMirror service if present; otherwise resolve the first
        if service.name.contains("SmartMirror") || !moreComing {
            resolve(service, attempt: 1, maxAttempts: maxResolveAttempts)
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        if resolvingService == service { resolvingService = nil }
        resolveAttempts[ObjectIdentifier(service)] = nil
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("[Bonjour] Stopped search")
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("[Bonjour] Did not search: \(errorDict)")
    }

    private func resolve(_ service: NetService, attempt: Int = 1, maxAttempts: Int = 3) {
        resolvingService?.stop()
        resolvingService = service
        resolveAttempts[ObjectIdentifier(service)] = attempt
        service.includesPeerToPeer = true
        service.delegate = self
        let timeout: TimeInterval = (attempt == 1) ? 10.0 : 15.0
        service.resolve(withTimeout: timeout)
        print("[Bonjour] Resolving service: \(service.name) (attempt \(attempt)/\(maxAttempts), timeout: \(timeout)s)")
    }
}

extension MirrorDiscoveryController: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        resolveAttempts[ObjectIdentifier(sender)] = nil
        defer { sender.stop() }
        guard let hostName = sender.hostName else {
            print("[Bonjour] No hostName for service \(sender)")
            return
        }
        var host = hostName
        if host.hasSuffix(".") { host.removeLast() }
        let port = sender.port
        // Parse TXT record for path (defaults to /ws)
        var path = "/ws"
        if let data = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: data)
            if let p = dict["path"], let s = String(data: p, encoding: .utf8), !s.isEmpty {
                path = s.hasPrefix("/") ? s : "/" + s
            }
        }
        print("[Bonjour] Resolved host=\(host) port=\(port) path=\(path)")

        let manager = MirrorConnectivityManager(host: host, wsPort: port, wsPath: path)
        onManagerReady?(manager)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[Bonjour] Failed to resolve: \(errorDict)")
        let id = ObjectIdentifier(sender)
        let attempt = resolveAttempts[id] ?? 1
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        if code == -72007 && attempt < maxResolveAttempts { // Timeout; retry a couple of times
            let next = attempt + 1
            resolveAttempts[id] = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.resolve(sender, attempt: next, maxAttempts: self.maxResolveAttempts)
            }
            return
        }
        // Give up; clear tracking
        resolveAttempts[id] = nil
        if resolvingService == sender { resolvingService = nil }
    }
}


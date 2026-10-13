import AMDBCore
import Foundation
import Observation

/// put.io sign-in for devices without a browser (Apple TV): show a code, wait until it's entered at put.io/link.
@Observable @MainActor
public final class DeviceSignIn {
    public enum Phase: Equatable, Sendable {
        case idle, requesting
        case waiting(PutioDeviceCode)
        case signedIn
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let appID: String
    private let transport: any HTTPTransport
    private let pollInterval: Duration
    private let onToken: @MainActor (String) -> Void
    private var task: Task<Void, Never>?

    public init(appID: String, transport: any HTTPTransport = URLSessionTransport(), pollInterval: Duration = .seconds(3),
                onToken: @escaping @MainActor (String) -> Void) {
        self.appID = appID
        self.transport = transport
        self.pollInterval = pollInterval
        self.onToken = onToken
    }

    /// Gets a code and polls until the user links it; codes expire, so a fresh one is fetched every 10 minutes.
    public func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            phase = .requesting
            let code: PutioDeviceCode
            do {
                code = try await PutioClient.requestDeviceCode(appID: appID, transport: transport)
            } catch {
                phase = .failed("Couldn't reach put.io. Check the connection and try again.")
                return
            }
            phase = .waiting(code)
            let deadline = ContinuousClock.now + .seconds(600)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                if let token = try? await PutioClient.deviceToken(code: code.code, transport: transport) {
                    phase = .signedIn
                    onToken(token)
                    return
                }
            }
        }
    }
}

/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */


import Foundation

/// Polling bridge for legacy graph views. Every mutable field is protected by
/// the lock; tasks publish only if their request generation is still current.
@objc(XRGURL)
public final class XRGURL: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?
    private var data: Data?
    private var loading = false
    private var ready = false
    private var failed = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let timeoutInterval: TimeInterval
    private let transport: @Sendable (URLRequest) async throws -> Data

    public override convenience init() {
        self.init(timeoutInterval: 60)
    }

    @objc(initWithTimeoutInterval:)
    public init(timeoutInterval: TimeInterval) {
        self.timeoutInterval = timeoutInterval.isFinite && timeoutInterval > 0 ? timeoutInterval : 60
        transport = { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = request.timeoutInterval + 1
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
        super.init()
    }

    /// Injected transport keeps tests independent of live services.
    public init(timeoutInterval: TimeInterval = 60,
                transport: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.timeoutInterval = timeoutInterval.isFinite && timeoutInterval > 0 ? timeoutInterval : 60
        self.transport = transport
        super.init()
    }

    deinit { task?.cancel() }

    @objc(initWithURLString:)
    public convenience init(urlString: String?) {
        self.init()
        setURLString(urlString)
    }

    @objc public var isLoading: Bool { lock.withLock { loading } }
    @objc public func isDataReady() -> Bool { lock.withLock { ready } }
    @objc public func didErrorOccur() -> Bool { lock.withLock { failed } }
    @objc public func getData() -> Data? { lock.withLock { data } }
    @objc public func urlString() -> String? { lock.withLock { address } }

    @objc(setURLString:)
    public func setURLString(_ value: String?) {
        lock.withLock {
            guard address != value else { return }
            reset()
            address = value
        }
    }

    @objc public func haveGoodURL() -> Bool {
        lock.withLock { requestURL != nil }
    }

    private var requestURL: URL? {
        guard let address, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    @objc public func loadURLInBackground() {
        lock.withLock {
            reset()
            guard let url = requestURL else {
                failed = true
                return
            }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
            let id = generation
            let transport = transport
            loading = true
            task = Task { [weak self] in
                do {
                    let result = try await transport(request)
                    self?.finish(id: id, data: result, failed: false)
                } catch {
                    self?.finish(id: id, data: nil, failed: true)
                }
            }
        }
    }

    private func finish(id: UUID, data: Data?, failed: Bool) {
        lock.withLock {
            guard generation == id else { return }
            self.data = data
            self.failed = failed
            ready = !failed
            loading = false
            task = nil
        }
    }

    @objc public func cancelLoading() {
        lock.withLock { reset() }
    }

    /// Caller holds the lock. Invalidating the generation also rejects late
    /// completions from transports that do not immediately honor cancellation.
    private func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        data = nil
        ready = false
        failed = false
        loading = false
    }
}

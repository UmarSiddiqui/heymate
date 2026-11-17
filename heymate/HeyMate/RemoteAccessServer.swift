//
//  RemoteAccessServer.swift
//  HeyMate
//
//  The narrow HTTP listener behind Phone access. One request per connection,
//  bounded sizes and time, peers outside private address space are dropped
//  before a byte is read. Every request goes to RemoteAccessController,
//  which applies RemoteGate. This is not the agent runtime's server and
//  shares nothing with it.
//
//  Runs on the main queue: requests are tiny, and the Inbox they act on is
//  main-actor state.
//

import Foundation
import Network

@MainActor
final class RemoteAccessServer {
    struct Peer: Sendable {
        let key: String
        let isAllowed: Bool
    }

    typealias Handler = @MainActor (RemoteHTTPRequest, Peer) async -> RemoteHTTPResponse

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: Handler
    private(set) var isListening = false
    var onStateChange: ((String?) -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Listens on every non-loopback, non-cellular interface; peers that are
    /// not private or link-local are cut off in `accept`. No Bonjour
    /// advertisement, no UPnP, no relay.
    func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .loopback]
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) ?? connection.cancel() }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.onStateChange?(nil)
                case .failed(let error):
                    self.isListening = false
                    self.onStateChange?(Self.describe(error))
                    self.stop()
                case .cancelled:
                    self.isListening = false
                default:
                    break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    /// Stops listening and ends every open connection at once.
    func stop() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        isListening = false
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Another app is using port \(RemoteAccessPolicy.port)."
        }
        return "Couldn't start listening on this network."
    }

    private static func peer(of connection: NWConnection) -> Peer {
        guard case .hostPort(let host, _) = connection.endpoint else { return Peer(key: "unknown", isAllowed: false) }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return Peer(key: bytes.map(String.init).joined(separator: "."), isAllowed: RemoteAddressPolicy.isAllowedPeer(bytes))
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            return Peer(key: bytes.map { String(format: "%02x", $0) }.joined(), isAllowed: RemoteAddressPolicy.isAllowedPeer(bytes))
        default:
            return Peer(key: "unknown", isAllowed: false)
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Self.peer(of: connection)
        guard isListening, peer.isAllowed, connections.count < RemoteAccessPolicy.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + RemoteAccessPolicy.connectionTimeout) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data(), peer: peer)
    }

    private func receive(on connection: NWConnection, buffer: Data, peer: Peer) {
        let limit = RemoteAccessPolicy.maxHeaderBytes + RemoteAccessPolicy.maxBodyBytes + 4
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var data = buffer
                if let content { data.append(content) }
                if error != nil || data.count > limit {
                    self.respond(.error(data.count > limit ? 413 : 400), on: connection)
                    return
                }
                switch RemoteHTTPParser.parse(data) {
                case .incomplete:
                    if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: data, peer: peer) }
                case .rejected(let status):
                    self.respond(.error(status), on: connection)
                case .complete(let request):
                    Task { @MainActor in
                        let response = await self.handler(request, peer)
                        self.respond(response, on: connection)
                    }
                }
            }
        }
    }

    private func respond(_ response: RemoteHTTPResponse, on connection: NWConnection) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

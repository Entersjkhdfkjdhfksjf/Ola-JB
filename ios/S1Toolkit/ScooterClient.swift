import Foundation
import GRPC
import NIOCore
import NIOPosix

/// Independent, clean-room client for the MoveOS head-unit root diagnostics
/// daemon (TCP port 50005). Same wire protocol as the Python and Kotlin
/// clients in this repo -- a single weakly-typed method that takes a
/// `command` string field and returns a `status` int plus a `message`
/// string, hand-rolled at the protobuf-wire level since no .proto file
/// is needed for a message this simple.
///
/// Plain, unencrypted gRPC (`.insecure`) over whatever Wi-Fi network you
/// and the scooter currently share. No pairing, no auth token, no ADB.
final class ScooterClient {

    private let host: String
    private let port: Int
    private var group: EventLoopGroup?
    private var channel: GRPCChannel?

    init(host: String, port: Int = 50005) {
        self.host = ScooterClient.normalize(host)
        self.port = port
    }

    private static func normalize(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("[") { h.removeFirst() }
        if h.hasSuffix("]") { h.removeLast() }
        return h
    }

    func connect(timeoutSeconds: Int64 = 8) async throws {
        close()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let ch = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group)
        self.channel = ch
        // Prove the daemon actually answers, not just that the socket opened.
        _ = try await exec("id -u", timeoutSeconds: timeoutSeconds)
    }

    func close() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }

    /// Raw command -- the daemon splits on whitespace, so anything with
    /// quoting/spaces/redirection should go through `shell(_:)` instead.
    @discardableResult
    func exec(_ command: String, timeoutSeconds: Int64 = 30) async throws -> (status: Int, message: String) {
        guard let channel else { throw ClientError.notConnected }
        let options = CallOptions(timeLimit: .timeout(.seconds(timeoutSeconds)))
        let call = channel.makeUnaryCall(
            path: "/wifican.WifiCanRpc/ExecuteADBCommand",
            request: RawPayload(data: Self.encodeCommand(command)),
            callOptions: options,
            responseType: RawPayload.self)
        let response = try await call.response.get()
        return Self.decodeReply(response.data)
    }

    /// Base64-wraps the command so it survives the daemon's naive
    /// whitespace split intact, then decodes and runs it in a real shell.
    @discardableResult
    func shell(_ command: String, timeoutSeconds: Int64 = 30) async throws -> (status: Int, message: String) {
        let b64 = Data(command.utf8).base64EncodedString()
        return try await exec("sh -c echo${IFS}\(b64)|base64${IFS}-d|sh", timeoutSeconds: timeoutSeconds)
    }

    @discardableResult
    func openIntent(_ action: String, timeoutSeconds: Int64 = 30) async throws -> (status: Int, message: String) {
        try await exec("am start -a \(action)", timeoutSeconds: timeoutSeconds)
    }

    @discardableResult
    func openComponent(_ component: String, timeoutSeconds: Int64 = 30) async throws -> (status: Int, message: String) {
        try await exec("am start -n \(component)", timeoutSeconds: timeoutSeconds)
    }

    @discardableResult
    func sendKeyEvent(_ code: Int, timeoutSeconds: Int64 = 15) async throws -> (status: Int, message: String) {
        try await exec("input keyevent \(code)", timeoutSeconds: timeoutSeconds)
    }

    func screenshot() async throws -> Data {
        let tmp = "/data/local/tmp/_s1toolkit_shot.png"
        let (status, out) = try await exec("screencap -p \(tmp)", timeoutSeconds: 60)
        guard isOk(status) else { throw ClientError.commandFailed(out) }
        let (pullStatus, encoded) = try await shell("base64 \(tmp)", timeoutSeconds: 90)
        guard isOk(pullStatus) else { throw ClientError.commandFailed(encoded) }
        _ = try? await exec("rm -f \(tmp)", timeoutSeconds: 15)
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ClientError.commandFailed("could not decode screenshot")
        }
        return data
    }

    private func isOk(_ status: Int) -> Bool { status == 0 || status == 1 }

    enum ClientError: LocalizedError {
        case notConnected
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected"
            case .commandFailed(let msg): return msg
            }
        }
    }

    // MARK: - hand-rolled protobuf wire format

    /// A pass-through payload: the daemon's schema is one string field in,
    /// one int + one string field out, so there's nothing to gain from
    /// generated .proto code here.
    struct RawPayload: GRPCPayload {
        let data: Data
        init(data: Data) { self.data = data }
        init(serializedByteBuffer: inout ByteBuffer) throws {
            self.data = serializedByteBuffer.readData(length: serializedByteBuffer.readableBytes) ?? Data()
        }
        func serialize(into buffer: inout ByteBuffer) throws {
            buffer.writeBytes(data)
        }
    }

    private static func encodeCommand(_ text: String) -> Data {
        var out = Data()
        out.append(varint(UInt64((1 << 3) | 2))) // field 1, wire type 2 (string)
        let raw = Data(text.utf8)
        out.append(varint(UInt64(raw.count)))
        out.append(raw)
        return out
    }

    private static func decodeReply(_ buf: Data) -> (status: Int, message: String) {
        var status = 0
        var message = ""
        let bytes = [UInt8](buf)
        var i = 0
        while i < bytes.count {
            guard let (key, next1) = readVarint(bytes, i) else { break }
            i = next1
            let fieldNo = key >> 3
            let wireType = key & 0b111
            switch wireType {
            case 0:
                guard let (v, next2) = readVarint(bytes, i) else { return (status, message) }
                i = next2
                if fieldNo == 1 { status = Int(v) }
            case 2:
                guard let (len, next2) = readVarint(bytes, i) else { return (status, message) }
                i = next2
                let end = min(i + Int(len), bytes.count)
                let slice = bytes[i..<end]
                i = end
                if fieldNo == 2 { message = String(decoding: slice, as: UTF8.self) }
            default:
                return (status, message) // unknown wire type -- stop safely
            }
        }
        return (status, message)
    }

    private static func varint(_ n: UInt64) -> Data {
        var value = n
        var out = Data()
        while true {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            out.append(b)
            if value == 0 { return out }
        }
    }

    private static func readVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var i = start
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return (value, i) }
            shift += 7
        }
        return nil // truncated
    }
}

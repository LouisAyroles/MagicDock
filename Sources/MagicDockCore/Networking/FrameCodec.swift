import Foundation

public enum FrameCodec {
    public static let maximumPayloadSize = 256 * 1_024

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadSize else {
            throw FrameCodecError.payloadTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func extractFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= MemoryLayout<UInt32>.size else { return nil }

        let length = buffer.prefix(4).reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length <= maximumPayloadSize else {
            throw FrameCodecError.payloadTooLarge(Int(length))
        }

        let frameLength = 4 + Int(length)
        guard buffer.count >= frameLength else { return nil }

        let headerEnd = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd = buffer.index(headerEnd, offsetBy: Int(length))
        let payload = Data(buffer[headerEnd..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return payload
    }
}

public enum FrameCodecError: LocalizedError, Equatable, Sendable {
    case payloadTooLarge(Int)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case let .payloadTooLarge(size):
            "The peer frame is too large (\(size) bytes)."
        case .connectionClosed:
            "The peer closed the connection before sending a complete message."
        }
    }
}

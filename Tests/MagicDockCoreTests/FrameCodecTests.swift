import Foundation
import Testing

@testable import MagicDockCore

@Suite("Peer frame codec")
struct FrameCodecTests {
    @Test("Extracts a frame received in chunks")
    func extractsPartialFrame() throws {
        let payload = Data("hello".utf8)
        let frame = try FrameCodec.encode(payload)
        var buffer = Data(frame.prefix(6))

        #expect(try FrameCodec.extractFrame(from: &buffer) == nil)

        buffer.append(frame.dropFirst(6))
        #expect(try FrameCodec.extractFrame(from: &buffer) == payload)
        #expect(buffer.isEmpty)
    }

    @Test("Leaves a subsequent frame in the buffer")
    func handlesBackToBackFrames() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var buffer = try FrameCodec.encode(first) + FrameCodec.encode(second)

        #expect(try FrameCodec.extractFrame(from: &buffer) == first)
        #expect(try FrameCodec.extractFrame(from: &buffer) == second)
        #expect(buffer.isEmpty)
    }

    @Test("Rejects oversized payloads")
    func rejectsOversizedPayload() {
        let payload = Data(repeating: 0, count: FrameCodec.maximumPayloadSize + 1)
        #expect(throws: FrameCodecError.payloadTooLarge(payload.count)) {
            try FrameCodec.encode(payload)
        }
    }
}

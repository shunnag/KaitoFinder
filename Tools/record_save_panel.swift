import AppKit
import AVFoundation
import ScreenCaptureKit

// Invoked by verify_save_panel_animation.py. Captures only the isolated test app's window.
private final class RecordingOutput: NSObject, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    let directory: URL
    // Accessed only on the stream's serial output queue.
    var frames: [[String: Any]] = []

    init(directory: URL) { self.directory = directory }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        frames.append([
            "time": sample.presentationTimeStamp.seconds,
            "contentRect": String(describing: info[.contentRect]),
            "contentScale": String(describing: info[.contentScale]),
            "scaleFactor": String(describing: info[.scaleFactor])
        ])
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        try? Data().write(to: directory.appendingPathComponent("ready"))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        try? Data().write(to: directory.appendingPathComponent("recording-finished"))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("recording-error"))
    }
}

@main @MainActor private struct SavePanelRecorder {
    static func main() async {
        do { try await record() }
        catch {
            FileHandle.standardError.write(Data("Save panel recording failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func record() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "SavePanelRecording", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screen Recording permission is required for the process running this tool. This tool does not request or change permissions."
            ])
        }
        if CommandLine.arguments.dropFirst() == ["--check-permission"] { return }
        guard CommandLine.arguments.count == 4,
              let windowID = UInt32(CommandLine.arguments[1]) else {
            throw NSError(domain: "SavePanelRecording", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Usage: recorder windowID outputDirectory testBundleIdentifier"
            ])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let bundleIdentifier = CommandLine.arguments[3]
        guard bundleIdentifier.hasPrefix("com.shunnag.KaitoFinder.SavePanelVerification.") else {
            throw NSError(domain: "ExpectedIsolatedTestApp", code: 3)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              window.owningApplication?.bundleIdentifier == bundleIdentifier else {
            throw NSError(domain: "ExpectedIsolatedTestWindow", code: 4)
        }
        let configuration = SCStreamConfiguration()
        guard let display = content.displays.max(by: {
            $0.frame.intersection(window.frame).width * $0.frame.intersection(window.frame).height
                < $1.frame.intersection(window.frame).width * $1.frame.intersection(window.frame).height
        }) else { throw NSError(domain: "ExpectedTestDisplay", code: 6) }
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleIdentifier }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor ?? 1
        configuration.width = Int(display.frame.width * scale)
        configuration.height = Int(display.frame.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let info: [String: Any] = [
            "display": ["x": display.frame.minX, "y": display.frame.minY, "width": display.frame.width, "height": display.frame.height],
            "pixels": ["width": configuration.width, "height": configuration.height],
            "windows": windows.map { ["id": $0.windowID, "x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] }
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("capture-info.json"))
        let stream = SCStream(filter: SCContentFilter(display: display, including: windows), configuration: configuration, delegate: nil)
        let output = RecordingOutput(directory: directory)
        let queue = DispatchQueue(label: "KaitoFinder.SavePanelRecording")
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = directory.appendingPathComponent("capture.mov")
        recording.outputFileType = .mov
        recording.videoCodecType = .hevc
        let recordingOutput = SCRecordingOutput(configuration: recording, delegate: output)
        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(4))
        try await stream.stopCapture()
        let finished = directory.appendingPathComponent("recording-finished").path
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: finished) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: finished),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording-error").path) else {
            throw NSError(domain: "RecordingDidNotFinish", code: 5)
        }
        let frames = queue.sync { output.frames }
        try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("frames.json"), options: .atomic)
        print("Recorded \(frames.count) display updates: \(recording.outputURL.path)")
    }
}

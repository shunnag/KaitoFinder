import Carbon
import XCTest

// Run with python3 Tools/tests/test_drive_finder_interactions.py.
// These tests never activate an app, select an input source, or post input events.
final class FinderInteractionKeyboardTests: XCTestCase {
    // The legacy Gestalt constants are not exposed to Swift on arm64.
    private let ansiKeyboardType: UInt32 = 40 // gestaltThirdPartyANSIKbd
    private let jisKeyboardType: UInt32 = 42 // gestaltThirdPartyJISKbd

    private func input(_ json: String) throws -> DriveFinderInteractions.Input {
        try JSONDecoder().decode(DriveFinderInteractions.Input.self, from: Data(json.utf8))
    }

    private func layout(_ identifier: String, keyboardType: UInt32) throws -> FinderInteractionKeyboardLayout {
        let properties = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(properties, true).takeRetainedValue() as! [TISInputSource]
        return try FinderInteractionKeyboardLayout(inputSource: XCTUnwrap(sources.first), keyboardType: keyboardType)
    }

    private func assertRoundTrip(_ character: String, key: CGKeyCode, layout: FinderInteractionKeyboardLayout,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try XCTUnwrap(CFDataGetBytePtr(layout.data), file: file, line: line)
        let pointer = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 255)
        let status = withExtendedLifetime(layout.data) {
            UCKeyTranslate(pointer, key, UInt16(kUCKeyActionDown), 0, layout.keyboardType,
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                           characters.count, &length, &characters)
        }
        XCTAssertEqual(status, noErr, file: file, line: line)
        XCTAssertEqual(String(utf16CodeUnits: characters, count: length), character, file: file, line: line)
        XCTAssertEqual(deadKeyState, 0, file: file, line: line)
    }

    func testCurrentLayoutCharacterEventsRoundTrip() throws {
        let layout = try FinderInteractionKeyboardLayout.current()
        XCTAssertEqual(layout.keyboardType, UInt32(LMGetKbdType()))
        for character in ["[", "]"] {
            let key = try layout.keyCode(for: character)
            XCTAssertLessThanOrEqual(key, 127)
            for type in ["keyDown", "keyUp"] {
                let event = try input("""
                {"type":"\(type)","character":"\(character)","modifiers":1048576}
                """)
                XCTAssertEqual(try event.resolvedKeyCode(), key)
                XCTAssertEqual(event.modifiers, CGEventFlags.maskCommand.rawValue)
            }
            try assertRoundTrip(character, key: key, layout: layout)
            print("Current layout \(layout.identifier), keyboard type \(layout.keyboardType): \(character) -> \(key) -> \(character)")
        }
    }

    func testABCUsesANSIAndJISKeyboardTypes() throws {
        for (keyboardType, expected): (UInt32, [CGKeyCode]) in [
            (ansiKeyboardType, [33, 30]),
            (jisKeyboardType, [30, 42])
        ] {
            let layout = try layout("com.apple.keylayout.ABC", keyboardType: keyboardType)
            for (character, expectedKey) in zip(["[", "]"], expected) {
                let key = try layout.keyCode(for: character)
                XCTAssertEqual(key, expectedKey)
                try assertRoundTrip(character, key: key, layout: layout)
            }
        }
    }

    func testLayoutWithoutUnmodifiedBracketsFailsClearly() throws {
        let layout = try layout("com.apple.keylayout.German", keyboardType: ansiKeyboardType)
        for character in ["[", "]"] {
            XCTAssertThrowsError(try layout.keyCode(for: character)) { error in
                XCTAssertTrue(error.localizedDescription.contains(layout.identifier))
                XCTAssertTrue(error.localizedDescription.contains("cannot type \(character) without modifiers"))
            }
        }
    }

    func testFixedKeysAndMouseEventsStillDecode() throws {
        for key in [36, 53, 125, 126] {
            for type in ["keyDown", "keyUp"] {
                XCTAssertEqual(try input("{\"type\":\"\(type)\",\"key\":\(key)}").resolvedKeyCode(), CGKeyCode(key))
            }
        }
        XCTAssertNil(try input(#"{"type":"down","x":1,"y":2}"#).resolvedKeyCode())
    }

    func testRejectsDisallowedAndAmbiguousKeys() throws {
        for json in [
            #"{"type":"keyDown","key":30}"#, #"{"type":"keyUp","key":33}"#,
            #"{"type":"keyDown","key":42}"#, #"{"type":"keyDown","key":0}"#,
            #"{"type":"keyDown","character":"a"}"#, #"{"type":"keyDown","character":"[]"}"#,
            #"{"type":"keyDown","character":""}"#, #"{"type":"keyDown","key":36,"character":"["}"#,
            #"{"type":"down","character":"["}"#, #"{"type":"drag","key":36}"#
        ] {
            XCTAssertThrowsError(try input(json).resolvedKeyCode(), json)
        }
    }
}

import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DecodePowerPolicyPreferenceTests: XCTestCase {
    func testStoredPowerPoliciesReachReaders() throws {
        for policy in ArchivePreferences.PowerPolicy.allCases {
            let suite = try ArchivePreferencesTestDefaults()
            suite.defaults.set(policy.rawValue, forKey: "ArchiveCompressionPowerPolicy")
            let expected: DecodePowerPolicy = switch policy {
            case .reduceInLowPowerMode: .reduceInLowPowerMode
            case .reduceInLowPowerModeOrThermalPressure: .reduceInLowPowerModeOrThermalPressure
            case .alwaysUseAllCores: .alwaysUseAllCores
            }
            XCTAssertEqual(ArchivePreferencesStore.storedPowerPolicy(defaults: suite.defaults), policy)
            for options in [ReaderOptions.kaitoFinder(defaults: suite.defaults),
                            ReaderOptions.kaitoFinderVerification(defaults: suite.defaults)] {
                XCTAssertEqual(options.decodePowerPolicy, expected, "\(policy)")
                XCTAssertNil(options.decodeThreads)
            }
        }
    }

    func testMissingAndInvalidPowerPoliciesUseDefault() throws {
        for rawValue: String? in [nil, "broken"] {
            let suite = try ArchivePreferencesTestDefaults()
            if let rawValue { suite.defaults.set(rawValue, forKey: "ArchiveCompressionPowerPolicy") }
            XCTAssertEqual(ArchivePreferencesStore.storedPowerPolicy(defaults: suite.defaults), .reduceInLowPowerMode)
            XCTAssertEqual(ReaderOptions.kaitoFinder(defaults: suite.defaults).decodePowerPolicy, .reduceInLowPowerMode)
            XCTAssertEqual(ReaderOptions.kaitoFinderVerification(defaults: suite.defaults).decodePowerPolicy, .reduceInLowPowerMode)
        }
    }

    @MainActor func testPreferencesUseStoredPowerPolicy() throws {
        for rawValue in ArchivePreferences.PowerPolicy.allCases.map(\.rawValue) + ["broken"] {
            let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
            suite.defaults.set(rawValue, forKey: "ArchiveCompressionPowerPolicy")
            XCTAssertEqual(store.preferences.powerPolicy, ArchivePreferencesStore.storedPowerPolicy(defaults: suite.defaults))
        }
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        XCTAssertEqual(store.preferences.powerPolicy, ArchivePreferencesStore.storedPowerPolicy(defaults: suite.defaults))
    }
}

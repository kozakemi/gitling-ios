import XCTest
import FileProvider
@testable import Gitling

final class DocumentsSharingTests: XCTestCase {
    func testApplicationAdvertisesDocumentsToFilesAndDocumentPickers() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
    }

    func testProviderRegistrationAvailability() async throws {
        let problem: String? = await withCheckedContinuation { continuation in
            FileProviderRegistration.register { continuation.resume(returning: $0) }
        }
        XCTAssertNil(problem)
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: domains) }
            }
        }
        XCTAssertTrue(domains.contains { $0.identifier == FileProviderRegistration.domain.identifier })
#if targetEnvironment(simulator)
        try ProviderWorkspace.withCurrentRoots { root, metadata in
            XCTAssertEqual(root.resolvingSymlinksInPath(), RepoStorage.repositoriesRoot().resolvingSymlinksInPath())
            XCTAssertEqual(metadata.resolvingSymlinksInPath(), RepoStorage.storageBase().resolvingSymlinksInPath())
        }
#endif
    }

#if targetEnvironment(simulator)
    private func simulatedEntitlements() throws -> [String: Any] {
        // Simulator entitlements are injected into Mach-O by Xcode. Manually
        // signing an app with a plist does not create this runtime identity.
        let file = try Data(contentsOf: XCTUnwrap(Bundle.main.executableURL))
        func uint32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= file.count else { throw CocoaError(.fileReadCorruptFile) }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(file[offset + $1]) << (8 * $1) }
        }
        func name(_ offset: Int) throws -> String {
            guard offset >= 0, offset + 16 <= file.count else { throw CocoaError(.fileReadCorruptFile) }
            return String(decoding: file[offset..<(offset + 16)].prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(try uint32(0), 0xfeedfacf) // active-architecture 64-bit test host
        let commandCount = Int(try uint32(16))
        var command = 32
        var data: Data?
        for _ in 0..<commandCount {
            let kind = try uint32(command), size = Int(try uint32(command + 4))
            guard size >= 8, command + size <= file.count else { throw CocoaError(.fileReadCorruptFile) }
            if kind == 0x19 { // LC_SEGMENT_64
                let count = Int(try uint32(command + 64))
                guard size >= 72, count <= (size - 72) / 80 else { throw CocoaError(.fileReadCorruptFile) }
                for index in 0..<count {
                    let section = command + 72 + index * 80
                    if try name(section) == "__entitlements", try name(section + 16) == "__TEXT" {
                        let offset = Int(try uint32(section + 48))
                        let bytes = UInt64(try uint32(section + 40)) | UInt64(try uint32(section + 44)) << 32
                        guard offset <= file.count, bytes <= UInt64(file.count - offset) else { throw CocoaError(.fileReadCorruptFile) }
                        data = file.subdata(in: offset..<(offset + Int(bytes)))
                    }
                }
            }
            command += size
        }
        let plist = try XCTUnwrap(data, "Xcode must inject simulator entitlements; manual codesign is insufficient.")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
    }

    func testSimulatorRuntimeHasApplicationIdentityAndSharedGroup() throws {
        let entitlements = try simulatedEntitlements()
        let identifier = try XCTUnwrap(entitlements["application-identifier"] as? String)
        let bundle = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(identifier == bundle || identifier.hasSuffix("." + bundle), identifier)
        XCTAssertTrue((entitlements["com.apple.security.application-groups"] as? [String])?.contains(RepoStorage.appGroupIdentifier) == true)
    }
#endif
}

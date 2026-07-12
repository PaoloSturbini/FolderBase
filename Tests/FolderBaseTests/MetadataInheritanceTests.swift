import XCTest
@testable import FolderBase

final class MetadataInheritanceTests: XCTestCase {
    @MainActor
    func testParentFieldsComeFirstAndWinNameConflicts() {
        let parentStatus = MetadataField(id: "parent-status", name: "Stato", kind: .text, options: [])
        let parentDate = MetadataField(id: "parent-date", name: "Data", kind: .date, options: [])
        let childStatus = MetadataField(id: "child-status", name: "stàto", kind: .number, options: [])
        let childOwner = MetadataField(id: "child-owner", name: "Responsabile", kind: .text, options: [])

        let inherited = MetadataStore.mergeInheritedFields([
            [parentStatus, parentDate],
            [childStatus, childOwner]
        ])

        XCTAssertEqual(inherited.map(\.id), ["parent-status", "parent-date", "child-owner"])
    }
}

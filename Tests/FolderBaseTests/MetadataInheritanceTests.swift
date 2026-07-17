import XCTest
@testable import FolderBase

final class MetadataInheritanceTests: XCTestCase {
    @MainActor
    func testIncompatibleOrganizedChildBecomesInheritanceBoundary() {
        let parentStatus = MetadataField(id: "parent-status", name: "Stato", kind: .text, options: [])
        let parentDate = MetadataField(id: "parent-date", name: "Data", kind: .date, options: [])
        let childStatus = MetadataField(id: "child-status", name: "stàto", kind: .number, options: [])
        let childOwner = MetadataField(id: "child-owner", name: "Responsabile", kind: .text, options: [])

        let inherited = MetadataStore.mergeInheritedFields([
            [parentStatus, parentDate],
            [childStatus, childOwner]
        ])

        XCTAssertEqual(inherited.map(\.id), ["child-status", "child-owner"])
    }

    @MainActor
    func testCompatibleChildKeepsParentFieldAndAddsLocalFields() {
        let parentStatus = MetadataField(id: "parent-status", name: "Stato", kind: .text, options: [])
        let childStatus = MetadataField(id: "child-status", name: "stàto", kind: .text, options: [])
        let childOwner = MetadataField(id: "child-owner", name: "Responsabile", kind: .text, options: [])

        let inherited = MetadataStore.mergeInheritedFields([[parentStatus], [childStatus, childOwner]])

        XCTAssertEqual(inherited.map(\.id), ["parent-status", "child-owner"])
    }

    @MainActor
    func testCrossRootMoveRemapsTemplateValuesToDestinationFieldIDs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBaseCrossRoot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support", isDirectory: true)
        let rootA = base.appendingPathComponent("A", isDirectory: true)
        let rootB = base.appendingPathComponent("B", isDirectory: true)
        let source = rootA.appendingPathComponent("Moved", isDirectory: true)
        let destination = rootB.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fileURL = source.appendingPathComponent("document.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8)))

        let store = MetadataStore(supportURLOverride: support)
        let template = MetadataTemplate(
            id: "global", name: "Global",
            fields: [FieldTemplate(id: "template-status", name: "Stato", kind: .text, options: [])]
        )
        store.applyTemplate(template, to: rootA)
        store.applyTemplate(template, to: rootB)
        XCTAssertTrue(store.isTemplateApplied(template, to: source, configurationRootURL: rootA))
        XCTAssertTrue(store.isTemplateApplied(template, to: destination, configurationRootURL: rootB))
        let sourceField = try XCTUnwrap(store.fields(for: source, configurationRootURL: rootA).first)
        let destinationField = try XCTUnwrap(store.fields(for: destination, configurationRootURL: rootB).first)
        XCTAssertNotEqual(sourceField.id, destinationField.id)

        let item = try XCTUnwrap(FileBrowserService().contentsOfDirectory(at: source).first)
        _ = try store.registerFile(at: fileURL)
        store.update(item: item, field: sourceField, value: "da conservare")
        store.flushPendingWrites()

        try store.remapMetadataForMove(
            subtreeAt: source,
            from: [sourceField],
            to: [destinationField]
        )

        XCTAssertEqual(store.value(for: item, field: destinationField), "da conservare")
        XCTAssertEqual(store.value(for: item, field: sourceField), "")
    }
}

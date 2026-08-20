import XCTest
@testable import ICloudTestFramework

final class ConflictScenarioTests: XCTestCase {

    func testConcurrentEditsResolveToLastSyncedDevice() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("iphone")
            sync("mac")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "B")
        XCTAssertConflictCount(result, document: "note", expected: 1)
    }

    func testReversedSyncOrderFlipsTheWinner() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("mac")
            sync("iphone")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A")
    }

    func testNoConflictWhenOnlyOneDeviceEditsTheDocument() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            sync("iphone")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A")
        XCTAssertNoConflicts(result, document: "note")
    }

    func testSameDeviceEditingTwiceIsNotAConflict() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            sync("iphone")
            device("iphone").edit("note", value: "A2")
            sync("iphone")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A2")
        XCTAssertNoConflicts(result, document: "note")
    }

    func testDeviceSyncingAfterSeeingTheOtherWriteIsNotAConflict() async {
        // iphone syncs first (no conflict — nothing on the server yet).
        // mac then edits a *different* document, so its sync of "note"
        // never happens; only "todo" gets pushed, independently.
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            sync("iphone")
            device("mac").edit("todo", value: "buy milk")
            sync("mac")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertNoConflicts(result)
        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A")
        XCTAssertConflictResolved(result, document: "todo", resolvesTo: "buy milk")
    }

    func testMultipleDocumentsTrackConflictsIndependently() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("iphone").edit("todo", value: "walk dog")
            device("mac").edit("note", value: "B")
            sync("iphone")
            sync("mac")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictCount(result, document: "note", expected: 1)
        XCTAssertConflictCount(result, document: "todo", expected: 0)
        XCTAssertConflictResolved(result, document: "todo", resolvesTo: "walk dog")
    }

    func testThreeWayConflictKeepsTheFinalSyncersValue() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            device("ipad").edit("note", value: "C")
            sync("iphone")
            sync("mac")
            sync("ipad")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "C")
        XCTAssertConflictCount(result, document: "note", expected: 2)
    }

    func testSyncOrderIsRecordedInScenarioOrder() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("mac")
            sync("iphone")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertEqual(result.syncOrder, ["mac", "iphone"])
    }

    func testConflictContendersIncludeBothDevicesValues() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("iphone")
            sync("mac")
        }

        let result = await ConflictScenarioRunner().run(scenario)
        let conflict = result.conflicts(for: "note").first

        XCTAssertEqual(conflict?.contenders["iphone"], "A")
        XCTAssertEqual(conflict?.contenders["mac"], "B")
        XCTAssertEqual(conflict?.winningDevice, "mac")
    }

    func testUnsyncedEditsNeverReachTheFinalState() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "never synced")
        }

        let result = await ConflictScenarioRunner().run(scenario)

        XCTAssertNil(result.resolvedValue(for: "note"))
        XCTAssertNoConflicts(result)
    }

    func testFirstWriterWinsKeepsTheEarlierSyncersValue() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("iphone")
            sync("mac")
        }

        let result = await ConflictScenarioRunner(strategy: .firstWriterWins).run(scenario)

        // iphone synced first, so its value stands even though mac
        // synced later — the opposite of lastWriterWins on the same
        // scenario.
        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A", strategy: .firstWriterWins)
        XCTAssertConflictCount(result, document: "note", expected: 1)
    }

    func testFirstWriterWinsStillRecordsTheDroppedEditAsAConflict() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            sync("iphone")
            sync("mac")
        }

        let result = await ConflictScenarioRunner(strategy: .firstWriterWins).run(scenario)
        let conflict = result.conflicts(for: "note").first

        XCTAssertEqual(conflict?.contenders["iphone"], "A")
        XCTAssertEqual(conflict?.contenders["mac"], "B")
        XCTAssertEqual(conflict?.winningDevice, "iphone")
    }

    func testFirstWriterWinsThreeWayConflictKeepsTheFirstSyncersValue() async {
        let scenario = ConflictScenario {
            device("iphone").edit("note", value: "A")
            device("mac").edit("note", value: "B")
            device("ipad").edit("note", value: "C")
            sync("iphone")
            sync("mac")
            sync("ipad")
        }

        let result = await ConflictScenarioRunner(strategy: .firstWriterWins).run(scenario)

        XCTAssertConflictResolved(result, document: "note", resolvesTo: "A", strategy: .firstWriterWins)
        XCTAssertConflictCount(result, document: "note", expected: 2)
    }
}

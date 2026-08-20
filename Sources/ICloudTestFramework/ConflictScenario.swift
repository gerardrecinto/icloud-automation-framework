import Foundation

// Deterministic multi-device conflict-resolution scenarios. This models the
// distributed-state shape iCloud-style sync actually has to get right
// (two devices editing the same document independently, then syncing) as a
// readable DSL, without a real server or wall-clock timing — ordering comes
// from the order scenario steps are written, the same "no sleep(), no
// timing races" discipline CloudFaultScenario already uses.
//
// This is intentionally separate from CloudAPIClient: that actor mocks one
// client's view of a single-document API surface and has no shared,
// multi-writer document store behind it. A real conflict needs two
// independent local edits landing on one shared store, which is what
// ConflictScenarioRunner provides.

public struct ConflictStep: Sendable {
    enum Kind: Sendable {
        case edit(document: String, value: String)
        case sync
    }

    let device: String
    let kind: Kind
}

// Returned by `device("name")` so `.edit(...)` reads as one fluent
// statement — `device("iphone").edit("note", value: "A")` — inside a
// `ConflictScenario` builder closure.
public struct DeviceAction: Sendable {
    let device: String

    public func edit(_ document: String, value: String) -> ConflictStep {
        ConflictStep(device: device, kind: .edit(document: document, value: value))
    }
}

public func device(_ name: String) -> DeviceAction {
    DeviceAction(device: name)
}

public func sync(_ device: String) -> ConflictStep {
    ConflictStep(device: device, kind: .sync)
}

@resultBuilder
public enum ConflictScenarioBuilder {
    public static func buildBlock(_ steps: ConflictStep...) -> [ConflictStep] {
        steps
    }
}

public struct ConflictScenario: Sendable {
    let steps: [ConflictStep]

    public init(@ConflictScenarioBuilder _ build: () -> [ConflictStep]) {
        self.steps = build()
    }
}

public enum ConflictResolutionStrategy: String, Sendable {
    // The sync() call that lands later in the scenario's step order wins.
    // "Later" is scenario order, not wall-clock time — the whole point of
    // this DSL is a result that doesn't depend on real timing.
    case lastWriterWins
    // The device that synced the document first keeps the server value.
    // A later sync() of the same document by a different device is still
    // recorded as a conflict (someone's edit got dropped), but that
    // device's value never reaches finalState.
    case firstWriterWins
}

public struct DocumentConflict: Sendable, Equatable {
    public let document: String
    // Every device whose value was in contention at the moment this
    // conflict was detected, keyed by device name.
    public let contenders: [String: String]
    public let winningDevice: String
    public let resolvedValue: String
}

public struct ConflictScenarioResult: Sendable {
    // Final resolved value per document after every step in the scenario ran.
    public let finalState: [String: String]
    public let conflicts: [DocumentConflict]
    // Devices in the order their sync() steps executed.
    public let syncOrder: [String]

    public func resolvedValue(for document: String) -> String? {
        finalState[document]
    }

    public func conflicts(for document: String) -> [DocumentConflict] {
        conflicts.filter { $0.document == document }
    }
}

// Actor, matching CloudAPIClient's concurrency shape, even though a single
// `run(_:)` call has no concurrent callers today — a scenario is a
// self-contained script, not shared mutable state another task could race
// against, so this is future-proofing rather than a fix for an existing
// race.
public actor ConflictScenarioRunner {
    private let strategy: ConflictResolutionStrategy

    public init(strategy: ConflictResolutionStrategy = .lastWriterWins) {
        self.strategy = strategy
    }

    public func run(_ scenario: ConflictScenario) -> ConflictScenarioResult {
        // Each device's edits since its last sync() — never touched by
        // other devices, matching a local-first client that only pushes
        // its own changes.
        var pendingEdits: [String: [String: String]] = [:]
        // The shared store every sync() writes into and reads from.
        var serverState: [String: (value: String, writer: String)] = [:]
        var conflicts: [DocumentConflict] = []
        var syncOrder: [String] = []

        for step in scenario.steps {
            switch step.kind {
            case .edit(let document, let value):
                pendingEdits[step.device, default: [:]][document] = value

            case .sync:
                syncOrder.append(step.device)
                let edits = pendingEdits[step.device] ?? [:]
                for (document, value) in edits {
                    if let existing = serverState[document], existing.writer != step.device {
                        // Another device's write already landed on this
                        // document and this device edited it without first
                        // syncing to see that write — a real conflict.
                        switch strategy {
                        case .lastWriterWins:
                            conflicts.append(DocumentConflict(
                                document: document,
                                contenders: [existing.writer: existing.value, step.device: value],
                                winningDevice: step.device,
                                resolvedValue: value
                            ))
                            serverState[document] = (value, step.device)
                        case .firstWriterWins:
                            conflicts.append(DocumentConflict(
                                document: document,
                                contenders: [existing.writer: existing.value, step.device: value],
                                winningDevice: existing.writer,
                                resolvedValue: existing.value
                            ))
                            // existing writer's value stands — this sync's
                            // edit is dropped, not written to serverState.
                        }
                    } else {
                        serverState[document] = (value, step.device)
                    }
                }
                pendingEdits[step.device] = [:]
            }
        }

        return ConflictScenarioResult(
            finalState: serverState.mapValues(\.value),
            conflicts: conflicts,
            syncOrder: syncOrder
        )
    }
}

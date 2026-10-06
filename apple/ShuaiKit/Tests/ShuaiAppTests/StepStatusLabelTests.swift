import Testing
@testable import ShuaiApp

@Suite("StepStatus accessibility labels")
struct StepStatusLabelTests {
    private let all: [StepStatus] = [
        .pending, .running, .done, .skipped, .failed("boom"), .wouldRun, .needsDecision,
    ]

    @Test func stepStatusLabelsAreWordedAndDistinct() {
        #expect(StepStatus.done.accessibilityLabel == "Done")
        #expect(StepStatus.failed("x").accessibilityLabel == "Failed")
        #expect(StepStatus.needsDecision.accessibilityLabel == "Needs your decision")
        #expect(StepStatus.running.accessibilityLabel == "Running")
        #expect(StepStatus.pending.accessibilityLabel == "Pending")
        let labels = all.map(\.accessibilityLabel)
        #expect(Set(labels).count == labels.count)
    }

    @Test func noStepStatusLabelIsEmpty() {
        for status in all { #expect(!status.accessibilityLabel.isEmpty) }
    }

    @Test func failureMessageIsNotPartOfTheLabel() {
        #expect(StepStatus.failed("secret detail").accessibilityLabel == "Failed")
    }
}

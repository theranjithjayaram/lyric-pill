// Minimal test harness: Command Line Tools ship neither XCTest nor Swift
// Testing (both need full Xcode), so the suite is a plain executable —
// `swift run lyrics-tests` — with zero dependencies.
final class TestReporter {
    private(set) var passed = 0
    private(set) var failed = 0

    func expect(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    }

    func summary() -> String {
        "\(passed) passed, \(failed) failed"
    }
}

import LyricsCore

func semanticVersionTests(_ t: TestReporter) {
    t.expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3),
             "semver: parses 1.2.3")
    t.expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3),
             "semver: v prefix accepted")
    t.expect(SemanticVersion("1.2") == SemanticVersion(major: 1, minor: 2, patch: 0),
             "semver: two parts default patch to 0")
    t.expect(SemanticVersion("1.2.3-beta.1") == SemanticVersion(major: 1, minor: 2, patch: 3),
             "semver: pre-release ignored")
    t.expect(SemanticVersion("1.2.3+build7") == SemanticVersion(major: 1, minor: 2, patch: 3),
             "semver: build metadata ignored")
    t.expect(SemanticVersion("1.2.3\n") == SemanticVersion(major: 1, minor: 2, patch: 3),
             "semver: surrounding whitespace tolerated")
    for bad in ["", "1", "v", "abc", "1.2.3.4", "1.x.3", "1..3", "1.2.", "1.2.3beta", "a.b"] {
        t.expect(SemanticVersion(bad) == nil, "semver: rejects \(bad.debugDescription)")
    }

    t.expect(SemanticVersion("1.10.0")! > SemanticVersion("1.9.9")!,
             "semver: 1.10.0 > 1.9.9 (numeric, not lexical)")
    t.expect(SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!, "semver: major dominates")
    t.expect(SemanticVersion("1.2.4")! > SemanticVersion("1.2.3")!, "semver: patch compares")
    t.expect(SemanticVersion("1.2.3")! == SemanticVersion("v1.2.3-rc1")!,
             "semver: equal cores compare equal")
    t.expect(!(SemanticVersion("1.2.3")! < SemanticVersion("1.2.3")!), "semver: not less than self")

    t.expect(SemanticVersion("1.2.3")!.description == "1.2.3", "semver: description")
    t.expect(SemanticVersion("1.2")!.description == "1.2.0", "semver: description pads patch")
}

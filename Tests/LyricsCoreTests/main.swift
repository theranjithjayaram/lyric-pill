import Foundation

let reporter = TestReporter()
lrcParserTests(reporter)
timingEngineTests(reporter)
lrclibClientTests(reporter)
scriptDetectorTests(reporter)

print(reporter.summary())
exit(reporter.failed == 0 ? 0 : 1)

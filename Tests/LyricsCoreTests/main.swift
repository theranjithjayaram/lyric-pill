import Foundation

let reporter = TestReporter()
lrcParserTests(reporter)
timingEngineTests(reporter)
lrclibClientTests(reporter)
scriptDetectorTests(reporter)
translationCatalogTests(reporter)
languageGateTests(reporter)
appleLanguageRecognizerTests(reporter)
semanticVersionTests(reporter)
displayLinesTests(reporter)

print(reporter.summary())
exit(reporter.failed == 0 ? 0 : 1)

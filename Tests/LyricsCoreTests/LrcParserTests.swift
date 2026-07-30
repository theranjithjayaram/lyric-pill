import LyricsCore

func lrcParserTests(_ t: TestReporter) {
    t.expect(
        LrcParser.parse("[00:12.00] hello\n[00:10.50] world\n") == [
            LrcLine(ms: 10500, text: "world"),
            LrcLine(ms: 12000, text: "hello"),
        ],
        "parser: basic lines sorted with ms")

    t.expect(
        LrcParser.parse("[01:02.345] x") == [LrcLine(ms: 62345, text: "x")],
        "parser: three-digit fraction")

    t.expect(
        LrcParser.parse("[00:01.5] x") == [LrcLine(ms: 1500, text: "x")],
        "parser: one-digit fraction is tenths")

    t.expect(
        LrcParser.parse("[00:01.00][00:03.00] repeat") == [
            LrcLine(ms: 1000, text: "repeat"),
            LrcLine(ms: 3000, text: "repeat"),
        ],
        "parser: multiple timestamps on one line")

    t.expect(
        LrcParser.parse("[ar:Artist]\n[length:03:00]\n[00:05.00] real\n")
            == [LrcLine(ms: 5000, text: "real")],
        "parser: metadata tags ignored")

    t.expect(
        LrcParser.parse("\n   \nnot a line\n[bad] no time\n[00:02.00] keep\n")
            == [LrcLine(ms: 2000, text: "keep")],
        "parser: blank and malformed lines skipped")

    t.expect(
        LrcParser.parse("[00:04.00] ") == [LrcLine(ms: 4000, text: "")],
        "parser: empty text line preserved")

    t.expect(LrcParser.parse("") == [], "parser: empty input")
}

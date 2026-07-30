import LyricsCore

private final class FakeClock {
    var t = 0.0
}

private func makeEngine() -> (FakeClock, TimingEngine) {
    let clock = FakeClock()
    let engine = TimingEngine(clock: { clock.t })
    engine.setLines([
        LrcLine(ms: 0, text: "a"),
        LrcLine(ms: 1000, text: "b"),
        LrcLine(ms: 3000, text: "c"),
    ])
    return (clock, engine)
}

func timingEngineTests(_ t: TestReporter) {
    do {
        let (_, engine) = makeEngine()
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        t.expect(engine.currentIndex() == 0, "engine: at zero hits first line")
    }

    do {
        let (_, engine) = makeEngine()
        engine.setLines([LrcLine(ms: 500, text: "late")])
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        t.expect(engine.currentIndex() == -1, "engine: before first line yields -1")
        t.expect(engine.currentText() == "", "engine: before first line yields empty text")
    }

    do {
        let (clock, engine) = makeEngine()
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        clock.t = 1.5  // +1.5s -> 1500ms
        t.expect(engine.positionMs() == 1500, "engine: interpolates while playing")
        t.expect(engine.currentIndex() == 1, "engine: interpolated index")
        t.expect(engine.currentText() == "b", "engine: interpolated text")
    }

    do {
        let (clock, engine) = makeEngine()
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        clock.t = 2.0
        engine.setPlaying(false)  // freeze at 2000ms
        clock.t = 100.0
        t.expect(engine.positionMs() == 2000, "engine: frozen while paused")
        t.expect(engine.currentIndex() == 1, "engine: frozen index")
    }

    do {
        let (clock, engine) = makeEngine()
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        clock.t = 1.0
        engine.seek(toMs: 3000)
        t.expect(engine.positionMs() == 3000, "engine: seek rebases")
        t.expect(engine.currentText() == "c", "engine: seek text")
    }

    do {
        let clock = FakeClock()
        let engine = TimingEngine(clock: { clock.t })
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        t.expect(engine.currentIndex() == -1, "engine: no lines is safe (index)")
        t.expect(engine.currentText() == "", "engine: no lines is safe (text)")
        t.expect(engine.nextBoundaryMs() == nil, "engine: no lines has no boundary")
    }

    do {
        let (clock, engine) = makeEngine()
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        t.expect(engine.nextBoundaryMs() == 1000, "engine: next boundary from first line")
        clock.t = 1.5
        t.expect(engine.nextBoundaryMs() == 3000, "engine: next boundary mid-track")
        clock.t = 3.5
        t.expect(engine.nextBoundaryMs() == nil, "engine: no boundary on last line")
    }

    do {
        let (_, engine) = makeEngine()
        engine.setLines([LrcLine(ms: 500, text: "late")])
        engine.seek(toMs: 0)
        t.expect(engine.nextBoundaryMs() == 500, "engine: boundary before first line")
    }
}

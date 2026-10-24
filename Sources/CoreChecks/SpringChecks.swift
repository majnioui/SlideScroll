import SlideScrollCore

private func settleTime(_ stiffness: Double, dt: Double) -> Double {
    var s = Spring(0)
    s.stiffness = stiffness
    s.target = 500
    var t = 0.0
    while !s.isSettled {
        s.step(dt)
        expect(s.value <= 501, "overshot to \(s.value)")
        t += dt
        if t > 2 { expect(false, "never settled"); break }
    }
    return t
}

func layoutSpringIsGentle() {
    let t = settleTime(layoutStiffness, dt: 1.0 / 60)
    expect((0.25..<0.6).contains(t), "settled in \(t)s")
}

func followSpringIsTightAndSurvivesLateFrames() {
    expect(settleTime(followStiffness, dt: 1.0 / 120) < 0.25)
    // A 33 ms hitch must not blow up a stiff spring.
    expect(settleTime(followStiffness, dt: 1.0 / 30) < 0.3)
}

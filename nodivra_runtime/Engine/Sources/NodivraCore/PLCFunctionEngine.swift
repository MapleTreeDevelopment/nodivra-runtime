import Foundation

/// Per-instance state. Shared by local simulation and the Linux engine.
struct PLCFunctionState: Sendable {
    var previous: [Bool?] = []
    var lastTime = 0.0
    var value = 0.0
    var q = false
    var deadline: Double?
    var started: Double?
    var target = false
    var samples: [Double] = []
    var bits: [Bool] = []
    var count = 0
    var nextSample: Double?
    var random: UInt64 = 0
    mutating func evaluate(_ b: Block, digital: [Bool?], analog: [Double?], now: Double, date: Date, calendar: Calendar, seed: Bool) -> (Bool?, Double?, Double?) {
        guard let f = b.function else { return (nil, nil, nil) }
        let dt = seed ? 0 : max(0, now - lastTime)
        let previousInputs = previous
        defer { previous = digital; lastTime = now }
        func d(_ pin: Int) -> Bool? { digital.indices.contains(pin) ? digital[pin] : nil }
        func a(_ pin: Int) -> Double? { analog.indices.contains(pin) ? analog[pin] : nil }
        func was(_ pin: Int) -> Bool? { previousInputs.indices.contains(pin) ? previousInputs[pin] : nil }
        func rising(_ pin: Int) -> Bool { !seed && was(pin) == false && d(pin) == true }
        func falling(_ pin: Int) -> Bool { !seed && was(pin) == true && d(pin) == false }
        func n(_ key: String) -> Double { b.options[key]?.number ?? f.parameters.first { $0.key == key }?.initial.number ?? 0 }
        func t(_ key: String) -> String { b.options[key]?.string ?? f.parameters.first { $0.key == key }?.initial.string ?? "" }
        func hysteresis(_ x: Double, _ on: Double, _ off: Double, _ previous: Bool) -> Bool {
            if on >= off { return previous ? x > off : x >= on }
            return previous ? x < off : x <= on
        }
        let resetPin: Int? = [.counter, .impulseRelay, .ramp].contains(f) ? 2 : f == .shiftRegister ? 3 : [.onOffDelay,.retentiveOnDelay,.wipingRelay,.delayedPulse,.clockPulse,.randomDelay,.staircase,.comfort,.stopwatch,.hours,.pi,.minMax,.average].contains(f) ? 1 : nil
        if let resetPin, d(resetPin) == nil { return (nil, nil, nil) }
        let setOverridesReset = f == .impulseRelay && t("priority") == "Setzen" && d(1) == true
        if let resetPin, d(resetPin) == true && !setOverridesReset {
            q = false; value = f == .counter ? n("startValue") : f == .ramp ? n("initial") : 0
            deadline = nil; started = nil; nextSample = nil; samples = []; bits = []; count = 0
            return (f.analogOutput ? nil : false, f.analogOutput || f.hasValueOutput ? value : nil, nil)
        }
        if seed { value = f == .counter ? n("startValue") : f == .ramp ? n("initial") : 0 }
        var digitalResult: Bool?, analogResult: Double?
        switch f {
        case .firstCycle:
            digitalResult = !seed && count == 0
            if !seed { count = 1 }
        case .nand, .nor, .andEdge, .nandEdge:
            guard digital.allSatisfy({ $0 != nil }) else { return (nil, nil, nil) }
            let all = digital.allSatisfy { $0 == true }
            let oldAll = !previousInputs.isEmpty && previousInputs.allSatisfy { $0 == true }
            let known = previousInputs.allSatisfy { $0 != nil } && !previousInputs.isEmpty
            switch f {
            case .nand: digitalResult = !all
            case .nor: digitalResult = !digital.contains(true)
            case .andEdge: digitalResult = !seed && known && all && !oldAll
            default: digitalResult = !seed && known && !all && oldAll
            }
        case .edge: digitalResult = t("edge") == "Fallend" ? falling(0) : t("edge") == "Beide" ? rising(0) || falling(0) : rising(0)
        case .onOffDelay, .debounce, .randomDelay:
            guard let input = d(0) else { deadline = nil; return (nil, nil, nil) }
            if seed { q = false; target = input; if input { deadline = now + (f == .debounce ? n("duration") : n("onTime")) } }
            if !seed && (input != target || was(0) == nil) {
                target = input
                var delay = f == .debounce ? n("duration") : n(input ? "onTime" : "offTime")
                if f == .randomDelay {
                    if random == 0 { random = b.id.uuidString.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 } }
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    delay *= Double(random >> 11) / 9007199254740992
                }
                deadline = now + delay
            }
            if input == q { deadline = nil }
            if let end = deadline, now >= end { q = target; deadline = nil }
            digitalResult = q
        case .retentiveOnDelay:
            guard d(0) != nil else { return (nil, nil, nil) }
            if rising(0) && deadline == nil && !q { deadline = now + n("duration") }
            if let end = deadline, now >= end { q = true; deadline = nil }
            digitalResult = q
        case .wipingRelay:
            guard let input = d(0) else { deadline = nil; return (nil, nil, nil) }
            if rising(0) { deadline = now + n("duration") }
            if !input || deadline.map({ now >= $0 }) == true { deadline = nil }
            digitalResult = deadline != nil
        case .delayedPulse:
            guard d(0) != nil else { started = nil; deadline = nil; return (nil, nil, nil) }
            if rising(0) { started = now + n("delay") }
            if let start = started {
                let period = n("duration") + n("pause"), elapsed = now - start
                let end = start + Double(Int(n("count")) - 1) * period + n("duration")
                if now >= end { started = nil; deadline = nil; digitalResult = false }
                else if elapsed < 0 { digitalResult = false; deadline = start }
                else { let phase = elapsed.truncatingRemainder(dividingBy: period); digitalResult = phase < n("duration"); deadline = now + (phase < n("duration") ? n("duration") - phase : period - phase) }
            } else { digitalResult = false }
        case .clockPulse:
            guard let input = d(0), let invert = d(2) else { started = nil; deadline = nil; return (nil, nil, nil) }
            if input {
                if started == nil { started = now }
                let period = n("onTime") + n("offTime"), phase = (now - started!).truncatingRemainder(dividingBy: period)
                let high = phase < n("onTime")
                digitalResult = high != invert; deadline = now + (high ? n("onTime") - phase : period - phase)
            } else { started = nil; deadline = nil; digitalResult = false }
        case .staircase, .comfort:
            guard let input = d(0) else { deadline = nil; started = nil; q = false; return (nil, nil, nil) }
            if rising(0) {
                if f == .comfort && q { q = false; deadline = nil; started = nil; target = false }
                else { q = true; deadline = nil; started = now; target = false }
            }
            if f == .comfort, input, let press = started, now - press >= n("longPress") { target = true; deadline = nil }
            if falling(0) { if q && !target { deadline = now + n("duration") }; started = nil }
            if let end = deadline, now >= end { deadline = nil; q = false }
            digitalResult = q
            if let end = deadline, n("warning") > 0, (end - n("warning")..<end - n("warning") + n("warningLength")).contains(now) { digitalResult = false }
        case .yearClock:
            let m = calendar.component(.month, from: date), day = calendar.component(.day, from: date)
            let stamp = String(format: "%02d-%02d", m, day), start = t("start"), end = t("end")
            digitalResult = start <= end ? stamp >= start && stamp <= end : stamp >= start || stamp <= end
        case .astroClock:
            digitalResult = SolarClock.isDay(date: date, calendar: calendar, latitude: n("latitude"), longitude: n("longitude"), sunriseOffset: n("sunriseOffset"), sunsetOffset: n("sunsetOffset"))
        case .stopwatch, .hours:
            guard d(0) != nil else { return (nil, nil, nil) }
            if was(0) == true { value += dt / (f == .hours ? 3600 : 1) }
            analogResult = value
            if f == .hours { digitalResult = value >= n("interval") }
        case .counter:
            guard let direction = d(1), d(0) != nil else { return (nil, nil, nil) }
            if rising(0) { value = max(-999999999, min(999999999, value + (direction ? -1 : 1))) }
            q = hysteresis(value, n("on"), n("off"), q); digitalResult = q; analogResult = value
        case .frequency:
            guard d(0) != nil else { count = 0; started = nil; return (nil, nil, nil) }
            if started == nil { started = now }
            if rising(0) { count += 1 }
            if let start = started, now - start >= n("window") { value = Double(count) / (now - start); count = 0; started = now }
            q = hysteresis(value, n("on"), n("off"), q); digitalResult = q; analogResult = value
        case .threshold, .differenceThreshold, .comparator:
            guard let x = a(0), f != .comparator || a(1) != nil else { return (nil, nil, nil) }
            let measure = f == .comparator ? x - a(1)! : x
            if f == .differenceThreshold {
                let on = n("on"), off = on + n("delta")
                q = n("delta") > 0 ? measure >= on && measure < off : q ? measure > off : measure > on
            } else { q = hysteresis(measure, n("on"), n("off"), q) }
            digitalResult = q
        case .monitor:
            guard let x = a(0), let enable = d(1) else { return (nil, nil, nil) }
            if enable && (seed || was(1) != true) { value = x }
            digitalResult = enable && abs(x - value) > n("delta")
        case .amplifier: analogResult = a(0).map { $0 * n("gain") + n("offset") }
        case .toFloat: analogResult = a(0).map { $0.rounded(.towardZero) * n("resolution") }
        case .impulseRelay:
            guard let set = d(1), d(0) != nil else { return (nil, nil, nil) }
            if set { q = true } else if rising(0) { q.toggle() }; digitalResult = q
        case .shiftRegister:
            guard let input = d(0), let direction = d(2), d(1) != nil else { return (nil, nil, nil) }
            let length = Int(n("length")), tap = Int(n("tap")) - 1
            if bits.count != length { bits = .init(repeating: false, count: length) }
            if rising(1) { if direction { bits.removeFirst(); bits.append(input) } else { bits.removeLast(); bits.insert(input, at: 0) } }
            digitalResult = bits[tap]
        case .multiplexer:
            guard let en = d(0), let s1 = d(1), let s2 = d(2) else { return (nil, nil, nil) }
            analogResult = en ? n("value\(1 + (s1 ? 1 : 0) + (s2 ? 2 : 0))") : 0
        case .ramp:
            guard let en = d(0), let select = d(1) else { return (nil, nil, nil) }
            let destination = en ? n(select ? "level2" : "level1") : n("initial")
            value += max(-n("rate") * dt, min(n("rate") * dt, destination - value)); analogResult = value
        case .pi:
            guard let pv = a(0) else { return (nil, nil, nil) }
            let error = n("setpoint") - pv, p = n("kp") * error
            let proposed = value + p * dt / n("ti"), raw = p + proposed
            if raw <= n("maximum") && raw >= n("minimum") || raw > n("maximum") && p < 0 || raw < n("minimum") && p > 0 { value = proposed }
            analogResult = max(n("minimum"), min(n("maximum"), p + value))
        case .pwm:
            guard let x = a(0), let en = d(1) else { started = nil; return (nil, nil, nil) }
            if !en { started = nil; digitalResult = false }
            else { if started == nil { started = now }; let duty = max(0, min(1, (x - n("minimum")) / (n("maximum") - n("minimum")))); digitalResult = (now - started!).truncatingRemainder(dividingBy: n("period")) < n("period") * duty }
        case .math:
            if let x = a(0), let y = a(1) { switch t("operation") { case "+": analogResult = x + y; case "−": analogResult = x - y; case "×": analogResult = x * y; default: analogResult = y == 0 ? nil : x / y } }
        case .mathError: digitalResult = a(0) == nil
        case .filter:
            if let x = a(0) {
                samples.append(x)
                if samples.count > Int(n("samples")) { samples.removeFirst(samples.count - Int(n("samples"))) }
                analogResult = samples.reduce(0, +) / Double(samples.count)
            } else { samples = [] }
        case .minMax:
            if let x = a(0) { if samples.isEmpty { value = x; samples = [x] }; value = t("mode") == "Minimum" ? min(value, x) : max(value, x); analogResult = value }
        case .average:
            guard let x = a(0) else { samples = []; nextSample = nil; return (nil, nil, nil) }
            if nextSample == nil { nextSample = now + n("interval") }
            if let next = nextSample, now >= next {
                // Never invent missed samples after a suspended or delayed cycle.
                samples.append(x); nextSample = now + n("interval")
                if samples.count >= Int(n("samples")) { value = samples.reduce(0, +) / Double(samples.count); samples = []; count += 1 }
            }
            analogResult = count > 0 ? value : nil
        case .toInteger:
            if let x = a(0) {
                let v = x / n("resolution"), maximum = t("width") == "16 Bit" ? 32767.0 : 2147483647.0
                let rounded = t("rounding") == "Runden" ? v.rounded() : t("rounding") == "Aufrunden" ? ceil(v) : t("rounding") == "Abrunden" ? floor(v) : v.rounded(.towardZero)
                analogResult = max(-maximum - 1, min(maximum, rounded))
            }
        case .limit: analogResult = a(0).map { max(n("minimum"), min(n("maximum"), $0)) }
        }
        return (digitalResult, analogResult.flatMap { $0.isFinite ? $0 : nil }, deadline.map { max(0, $0 - now) })
    }
}

/// Approximate solar day using the NOAA fractional-year equations and 90.833° zenith.
/// A local calendar day chooses the date; UTC minutes keep DST out of the astronomy.
enum SolarClock {
    static func isDay(date: Date, calendar: Calendar, latitude: Double, longitude: Double, sunriseOffset: Double, sunsetOffset: Double) -> Bool {
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let yearDays = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
        let g = 2 * Double.pi / Double(yearDays) * (day - 1)
        let eq = 229.18 * (0.000075 + 0.001868*cos(g) - 0.032077*sin(g) - 0.014615*cos(2*g) - 0.040849*sin(2*g))
        let dec = 0.006918 - 0.399912*cos(g) + 0.070257*sin(g) - 0.006758*cos(2*g) + 0.000907*sin(2*g) - 0.002697*cos(3*g) + 0.00148*sin(3*g)
        let lat = latitude * .pi / 180
        let cosine = (cos(90.833 * .pi / 180) - sin(lat)*sin(dec)) / (cos(lat)*cos(dec))
        if cosine > 1 { return false }; if cosine < -1 { return true }
        let angle = acos(max(-1, min(1, cosine))) * 180 / .pi
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let midnight = utc.date(from: parts) else { return false }
        let minutes = date.timeIntervalSince(midnight) / 60
        let noon = 720 - 4 * longitude - eq
        return minutes >= noon - 4 * angle + sunriseOffset && minutes < noon + 4 * angle + sunsetOffset
    }
}

import Foundation

public enum ConfigurationPath: Hashable, Sendable {
    case key(String), index(Int)
}
public extension ConfigValue {
    func at(_ path: [ConfigurationPath]) -> ConfigValue? {
        guard let first = path.first else { return self }
        let child: ConfigValue?
        switch first { case .key(let key): child = object?[key]; case .index(let i): child = array.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        return child?.at(Array(path.dropFirst()))
    }
    /// An invalid path is a no-op, so a stale selection cannot replace a sibling.
    func replacing(_ path: [ConfigurationPath], with value: ConfigValue) -> ConfigValue {
        guard let first = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let key):
            guard var fields = object, let child = fields[key] else { return self }
            fields[key] = child.replacing(rest, with: value); return .object(fields)
        case .index(let i):
            guard var items = array, items.indices.contains(i) else { return self }
            items[i] = items[i].replacing(rest, with: value); return .array(items)
        }
    }
    func removing(_ key: String) -> ConfigValue {
        guard var fields = object else { return self }; fields.removeValue(forKey: key); return .object(fields)
    }
}

public enum HAConfiguration {
    public struct Branch: Identifiable, Sendable {
        public var id: String { label + String(describing: path) }
        public var label: String
        public var path: [ConfigurationPath]
        public var role: BlockKind
        public var parallel = false
    }
    public static let references = ["entity_id", "device_id", "area_id", "floor_id", "label_id"]
    public static let actionKeys = ["action","service","service_template","scene","device_id","condition","delay","wait_template","wait_for_trigger","choose","if","repeat","parallel","sequence","variables","event","stop","set_conversation_response"]
    public static let labels: [String:String] = [
        "brightness_step_pct":"Helligkeit ändern (%)", "brightness_step":"Helligkeit ändern", "rgb_color":"Farbe", "rgbw_color":"Farbe mit Weiß", "rgbww_color":"Farbe mit Kalt-/Warmweiß", "hs_color":"Farbton und Sättigung", "xy_color":"XY-Farbe", "color_name":"Farbname", "effect":"Lichteffekt", "flash":"Aufblinken", "profile":"Lichtprofil", "white":"Weißmodus", "initial_state":"Anfangszustand", "match":"Übereinstimmung", "not_from":"Nicht aus diesen Zuständen", "not_to":"Nicht in diese Zustände", "source":"Quelle", "subtype":"Variante", "encoding":"Zeichencodierung", "context":"Kontext", "transition":"Übergangsdauer (Sekunden)", "brightness":"Helligkeit", "brightness_pct":"Helligkeit (%)", "color_temp_kelvin":"Farbtemperatur (K)",
        "trigger":"Auslösertyp", "platform":"Auslösertyp", "condition":"Bedingungstyp", "action":"Aktion", "service":"Aktion",
        "entity_id":"Entitäten", "device_id":"Geräte", "area_id":"Bereiche", "floor_id":"Etagen", "label_id":"Labels", "target":"Ziele", "data":"Parameter", "data_template":"Parameter als Template",
        "at":"Uhrzeit", "above":"Größer als", "below":"Kleiner als", "to":"Neuer Zustand", "from":"Vorheriger Zustand", "state":"Zustand", "attribute":"Attribut",
        "for":"Für diese Dauer", "hours":"Stunden", "minutes":"Minuten", "seconds":"Sekunden", "milliseconds":"Millisekunden", "days":"Tage",
        "value_template":"Template", "event":"Ereignis", "event_type":"Ereignistyp", "event_data":"Ereignisdaten", "duration":"Dauer", "delay":"Warten", "timeout":"Zeitlimit", "continue_on_timeout":"Bei Zeitlimit fortsetzen",
        "name":"Name", "message":"Nachricht", "title":"Titel", "count":"Anzahl", "repeat":"Wiederholen", "for_each":"Für jeden Eintrag", "while":"Solange", "until":"Bis",
        "type":"Typ", "offset":"Zeitversatz", "alias":"Bezeichnung", "enabled":"Aktiviert", "continue_on_error":"Bei Fehler fortsetzen", "response_variable":"Antwortvariable",
        "id":"ID", "description":"Beschreibung", "variables":"Variablen", "trigger_variables":"Auslöser-Variablen", "mode":"Ausführungsmodus", "max":"Maximale Ausführungen", "max_exceeded":"Bei Überschreitung", "trace":"Ablaufaufzeichnung", "stored_traces":"Gespeicherte Abläufe",
        "choose":"Auswahl", "conditions":"Bedingungen", "if":"Wenn", "then":"Dann", "else":"Sonst", "default":"Sonst", "sequence":"Schritte", "parallel":"Parallele Zweige", "wait_for_trigger":"Auf Auslöser warten", "wait_template":"Auf Template warten", "stop":"Ablauf beenden",
        "weekday":"Wochentage", "before":"Vor", "after":"Nach", "before_offset":"Versatz vor", "after_offset":"Versatz nach", "zone":"Zone", "topic":"MQTT-Thema", "payload":"Nutzlast", "qos":"QoS", "retain":"Beibehalten", "command":"Sprachbefehle", "webhook_id":"Webhook-ID", "allowed_methods":"Erlaubte Methoden", "local_only":"Nur lokal", "tag_id":"Tag-ID", "notification_id":"Benachrichtigungs-ID", "update_type":"Änderungsarten", "domain":"Integration", "error":"Als Fehler beenden", "scene":"Szene", "set_conversation_response":"Sprachantwort", "input":"Blueprint-Eingaben", "use_blueprint":"Blueprint", "path":"Blueprint-Pfad"
    ]
    public static func label(_ key: String) -> String { labels[key] ?? key }
    public static func type(_ config: ConfigValue, role: BlockKind) -> String {
        let o = config.object ?? [:]
        if config.string != nil || config.bool != nil { return "template" }
        if config.array != nil { return "and" }
        if role == .haTrigger { return o["trigger"]?.string ?? o["platform"]?.string ?? "trigger" }
        if role == .haCondition { return o["condition"]?.string ?? ["and","or","not"].first(where: { o[$0] != nil }) ?? "condition" }
        return o["action"]?.string ?? o["service"]?.string ?? o["service_template"]?.string ?? actionKeys.first(where: { o[$0] != nil }) ?? "action"
    }
    public static func title(_ config: ConfigValue, role: BlockKind) -> String {
        if let alias = config.object?["alias"]?.string, !alias.isEmpty { return alias }
        if config.object?["use_blueprint"] != nil { return "Blueprint" }
        let t = type(config, role: role)
        if role == .haTrigger {
            return ["nodivra_manual":"Manuell / extern gestartet","state":"Zustandsänderung","numeric_state":"Schwellwert","time":"Uhrzeit","time_pattern":"Zeitintervall","sun":"Sonnenauf- / untergang","event":"Ereignis","mqtt":"MQTT-Nachricht","device":"Geräteauslöser","zone":"Zonenwechsel","geo_location":"Geolokalisierung","homeassistant":"Home Assistant","webhook":"Webhook","tag":"NFC-Tag","template":"Template-Auslöser","calendar":"Kalender","conversation":"Sprachbefehl","persistent_notification":"Benachrichtigung"][t] ?? t
        }
        if role == .haCondition || t == "condition" {
            let c = config.object?["condition"]?.string ?? t
            return ["state":"Zustand prüfen","numeric_state":"Zahlenbereich","time":"Zeitfenster","sun":"Sonnenstand prüfen","zone":"Zone prüfen","device":"Gerätebedingung","trigger":"Auslöser-ID prüfen","template":"Template-Bedingung","and":"Alle Bedingungen · UND","or":"Eine Bedingung · ODER","not":"Bedingungen negieren"][c] ?? c
        }
        if t.contains(".") {
            let operation = t.split(separator: ".").last.map(String.init) ?? t
            return ["turn_on":"Einschalten","turn_off":"Ausschalten","toggle":"Umschalten","press":"Taster betätigen","start":"Starten","pause":"Pausieren","cancel":"Abbrechen","finish":"Beenden","set_value":"Wert setzen","select_option":"Auswahl setzen"][operation] ?? t
        }
        return ["device_id":"Geräteaktion","choose":"Auswahl · erster passender Zweig","if":"Wenn / Dann / Sonst","repeat":"Wiederholung","parallel":"Parallel ausführen","sequence":"Aktionsgruppe","delay":"Warten","wait_template":"Auf Bedingung warten","wait_for_trigger":"Auf Auslöser warten","variables":"Variablen setzen","event":"Ereignis auslösen","stop":"Ablauf beenden","set_conversation_response":"Sprachantwort","scene":"Szene aktivieren"][t] ?? t
    }
    public static func icon(_ config: ConfigValue, role: BlockKind) -> String {
        switch type(config, role: role) {
        case "if", "choose", "or": "arrow.triangle.branch"
        case "repeat": "repeat"
        case "parallel": "arrow.triangle.fork"
        case "sequence": "square.stack"
        case "delay", "time", "time_pattern", "wait_template", "wait_for_trigger": "timer"
        case "state", "numeric_state": "sensor"
        case "template": "curlybraces"
        case "stop": "stop.circle"
        default: role.icon
        }
    }
    public static func compact(_ value: ConfigValue) -> String {
        switch value {
        case .string(let v): v
        case .number(let v): v.formatted(.number.grouping(.never))
        case .bool(let v): v ? "Ja" : "Nein"
        case .null: "Beliebig"
        case .array(let v): v.map(compact).joined(separator: ", ")
        case .object: value.json.replacingOccurrences(of: "\n", with: " ")
        }
    }
    public static func duration(_ value: ConfigValue) -> String {
        guard let o = value.object else { return compact(value) }
        return [("days","T"),("hours","Std."),("minutes","Min."),("seconds","Sek."),("milliseconds","ms")].compactMap { key, unit in
            guard let v = o[key], v.number != 0 else { return nil }; return "\(compact(v)) \(unit)"
        }.joined(separator: " ")
    }
    public static func summary(_ config: ConfigValue, role: BlockKind, resolve: (String,String)->String = { _, id in id }) -> [String] {
        guard let o = config.object else { return [compact(config)] }
        if let blueprint = o["use_blueprint"]?.object {
            return [blueprint["path"]?.string ?? "Blueprint", "\(blueprint["input"]?.object?.count ?? 0) Eingaben · Verknüpfung erhalten"]
        }
        var lines: [String] = []
        func names(_ key: String, _ value: ConfigValue) -> String { (value.array ?? [value]).map { resolve(key, compact($0)) }.joined(separator: ", ") }
        for key in references { if let v = o[key] { lines.append(names(key, v)) } }
        if let target = o["target"]?.object { for key in references { if let v = target[key] { lines.append("\(label(key)): \(names(key,v))") } } }
        let t = type(config, role: role)
        if t == "nodivra_manual" { return ["Kein automatischer Auslöser", "Start über Home Assistant oder einen anderen Ablauf"] }
        if t == "state" {
            func state(_ v: ConfigValue) -> String { if v.string == "on" { return "Ein" }; if v.string == "off" { return "Aus" }; return compact(v) }
            if let from = o["from"], let to = o["to"] { lines.append("\(state(from)) → \(state(to))") }
            else if let to = o["to"] { lines.append("Wird \(state(to))") }
            else if let s = o["state"] { lines.append("Ist \(state(s))") }
            else { lines.append("Bei Zustandsänderung") }
        }
        if let v = o["for"] { lines.append("Für \(duration(v))") }
        for key in ["above","below","at","after","before","weekday","after_offset","before_offset","offset","event","event_type","topic","payload","value_template","wait_template","zone","id","attribute","domain","type","subtype"] {
            if let v = o[key] { let choices = HAFormSchema.choices(field: key, type: t, role: role)
                let labelValue = (v.array ?? [v]).map { item in choices.first { $0.value == item }?.label ?? compact(item) }.joined(separator: ", ")
                lines.append("\(label(key)): \(labelValue)") }
        }
        if let v = o["delay"] { lines.append(duration(v)) }
        if let v = o["timeout"] { lines.append("Zeitlimit: \(duration(v))") }
        if let r = o["repeat"]?.object {
            if let count = r["count"] { lines.append("\(compact(count)) Wiederholungen") }
            if let values = r["for_each"] { lines.append("Für jeden: \(compact(values))") }
        }
        if let data = o["data"]?.object { for key in data.keys.sorted() { lines.append("\(label(key)): \(compact(data[key]!))") } }
        let groups = branches(config, role: role)
        if !groups.isEmpty { lines.append(groups.map(\.label).joined(separator: " · ")) }
        if o["enabled"] == .bool(false) { lines.insert("Deaktiviert", at: 0) }
        if lines.isEmpty { lines.append(t) }
        return lines
    }
    public static func branches(_ config: ConfigValue, role: BlockKind) -> [Branch] {
        if config.array != nil && role == .haCondition { return [.init(label: "Alle Bedingungen · UND", path: [], role: .haCondition)] }
        guard let o = config.object else { return [] }
        var branches: [Branch] = []
        func append(_ key: String, _ label: String, _ role: BlockKind, prefix: [ConfigurationPath] = [], object: [String:ConfigValue]? = nil, parallel: Bool = false) {
            if (object ?? o)[key] != nil { branches.append(.init(label: label, path: prefix + [.key(key)], role: role, parallel: parallel)) }
        }
        if role == .haCondition || o["condition"] != nil {
            append("conditions", title(config, role: .haCondition), .haCondition)
            for key in ["and","or","not"] { append(key, ["and":"Alle · UND","or":"Mindestens eine · ODER","not":"Nicht erfüllt"][key]!, .haCondition) }
        }
        append("triggers", "Alternative Auslöser", .haTrigger, parallel: true)
        append("if", "Wenn", .haCondition); append("then", "Dann", .haAction); append("else", "Sonst", .haAction)
        if let choices = o["choose"]?.array {
            for (i, choice) in choices.enumerated() {
                let prefix: [ConfigurationPath] = [.key("choose"),.index(i)]
                append("conditions", "Fall \(i+1) · wenn", .haCondition, prefix: prefix, object: choice.object ?? [:])
                append("sequence", "Fall \(i+1) · dann", .haAction, prefix: prefix, object: choice.object ?? [:])
            }
        }
        append("default", "Sonst", .haAction)
        if let r = o["repeat"]?.object {
            append("while", "Solange · vor jedem Durchlauf", .haCondition, prefix: [.key("repeat")], object: r)
            append("sequence", "Wiederholte Schritte", .haAction, prefix: [.key("repeat")], object: r)
            append("until", "Bis · nach jedem Durchlauf", .haCondition, prefix: [.key("repeat")], object: r)
        }
        append("parallel", "Parallele Zweige", .haAction, parallel: true)
        append("sequence", "Nacheinander", .haAction)
        append("wait_for_trigger", "Wartet auf einen dieser Auslöser", .haTrigger, parallel: true)
        return branches
    }
    public static func entries(_ root: ConfigValue, at path: [ConfigurationPath]) -> [(path: [ConfigurationPath], value: ConfigValue)] {
        guard let value = root.at(path) else { return [] }
        if let array = value.array { return array.enumerated().map { (path + [.index($0.offset)], $0.element) } }
        return [(path,value)]
    }
}

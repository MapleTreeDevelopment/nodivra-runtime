import Foundation

public struct BlockDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let kind: BlockKind
    public let summary: String
    public let defaults: ConfigValue
    public let requiredPaths: [String]
    public func makeBlock() -> Block {
        .init(kind: kind, title: title, options: kind.isFlow ? ["configuration": defaults] : defaults.object ?? [:], catalogID: id)
    }
}
public enum BlockCatalog {
    public static let categories = ["Eingänge", "Logik", "Zeit & Speicher", "Ausgänge", "HA · Auslöser", "HA · Bedingungen", "HA · Aktionen"]
    private static func flow(_ id: String, _ title: String, _ kind: BlockKind, _ json: String, _ required: [String] = [], _ summary: String = "") -> BlockDescriptor {
        .init(id: id, title: title, category: kind == .haTrigger ? "HA · Auslöser" : kind == .haCondition ? "HA · Bedingungen" : "HA · Aktionen", kind: kind, summary: summary, defaults: try! .parse(json), requiredPaths: required)
    }
    public static let descriptors: [BlockDescriptor] = {
        var result = BlockKind.allCases.filter { !$0.isFlow }.map { kind in
            let category = kind.isPLCInput || kind.isContact || kind.isEntityInput || kind == .constant || kind == .timeWindow ? "Eingänge" : kind.isMarker || kind.isMemory ? "Zeit & Speicher" : kind.isPLCOutput || kind == .output ? "Ausgänge" : "Logik"
            return BlockDescriptor(id: "logic.\(kind.rawValue)", title: kind.label, category: category, kind: kind, summary: "", defaults: .object([:]), requiredPaths: [])
        }
        result += [
            flow("runtime.log", "Protokolleintrag", .haAction, #"{"action":"nodivra.log","data":{"message":"Automation ausgeführt"}}"#, ["data.message"], "Schreibt einen Eintrag in das Runtime-Protokoll. Schaltet keine Geräte."),
            BlockDescriptor(id: "logic.darkness", title: "Es ist dunkel", category: "Eingänge", kind: .haCondition, summary: "Ein zwischen Sonnenuntergang und Sonnenaufgang. Lässt sich mit allen Logikbausteinen kombinieren.", defaults: .object(["condition": .string("sun"), "after": .string("sunset"), "before": .string("sunrise")]), requiredPaths: []),
            BlockDescriptor(id: "logic.motion", title: "Bewegung erkannt", category: "Eingänge", kind: .state, summary: "Ein, solange der Bewegungsmelder Bewegung meldet.", defaults: .object([:]), requiredPaths: []),
            BlockDescriptor(id: "logic.autoOff", title: "Automatisch ausschalten", category: "Zeit & Speicher", kind: .pulse, summary: "Sofort einschalten und nach der Laufzeit automatisch ausschalten. Ein neuer Impuls kann die Zeit neu starten.", defaults: .object(["duration": .number(300)]), requiredPaths: []),
            flow("trigger.state", "Zustandsänderung", .haTrigger, #"{"trigger":"state","entity_id":"binary_sensor.bewegung","to":"on"}"#, ["entity_id"]),
            flow("trigger.numeric", "Schwellwert überschritten", .haTrigger, #"{"trigger":"numeric_state","entity_id":"sensor.temperatur","above":25}"#, ["entity_id"]),
            flow("trigger.time", "Uhrzeit", .haTrigger, #"{"trigger":"time","at":"18:00:00"}"#, ["at"]),
            flow("trigger.pattern", "Zeitintervall", .haTrigger, #"{"trigger":"time_pattern","minutes":"/5"}"#),
            flow("trigger.sun", "Sonnenauf- / untergang", .haTrigger, #"{"trigger":"sun","event":"sunset","offset":"00:00:00"}"#, ["event"]),
            flow("trigger.event", "Ereignis", .haTrigger, #"{"trigger":"event","event_type":"nodivra_event","event_data":{}}"#, ["event_type"]),
            flow("trigger.mqtt", "MQTT-Nachricht", .haTrigger, #"{"trigger":"mqtt","topic":"home/button","payload":"on"}"#, ["topic"]),
            flow("trigger.device", "Geräteauslöser", .haTrigger, #"{"trigger":"device","device_id":"","domain":"","type":""}"#, ["device_id","domain","type"]),
            flow("trigger.zone", "Zone betreten / verlassen", .haTrigger, #"{"trigger":"zone","entity_id":"person.person","zone":"zone.home","event":"enter"}"#, ["entity_id","zone","event"]),
            flow("trigger.geolocation", "Geolokalisierung", .haTrigger, #"{"trigger":"geo_location","source":"","zone":"zone.home","event":"enter"}"#, ["source","zone"]),
            flow("trigger.homeassistant", "HA-Start / Herunterfahren", .haTrigger, #"{"trigger":"homeassistant","event":"start"}"#, ["event"]),
            flow("trigger.webhook", "Webhook", .haTrigger, #"{"trigger":"webhook","webhook_id":"","allowed_methods":["POST"],"local_only":true}"#, ["webhook_id"]),
            flow("trigger.tag", "NFC-Tag", .haTrigger, #"{"trigger":"tag","tag_id":""}"#, ["tag_id"]),
            flow("trigger.template", "Template wird wahr", .haTrigger, #"{"trigger":"template","value_template":"{{ is_state('binary_sensor.bewegung', 'on') }}"}"#, ["value_template"]),
            flow("trigger.calendar", "Kalenderereignis", .haTrigger, #"{"trigger":"calendar","entity_id":"calendar.kalender","event":"start","offset":"00:00:00"}"#, ["entity_id","event"]),
            flow("trigger.sentence", "Sprachbefehl", .haTrigger, #"{"trigger":"conversation","command":["Licht einschalten"]}"#, ["command"]),
            flow("trigger.notification", "Dauerhafte Benachrichtigung", .haTrigger, #"{"trigger":"persistent_notification","update_type":["added"]}"#),
            flow("trigger.timer", "Timer abgelaufen", .haTrigger, #"{"trigger":"event","event_type":"timer.finished","event_data":{"entity_id":"timer.nachlauf"}}"#, ["event_data.entity_id"]),
            flow("trigger.button", "HA-Taster gedrückt", .haTrigger, #"{"trigger":"state","entity_id":"input_button.taster","to":null}"#, ["entity_id"]),
            flow("trigger.custom", "Weiterer HA-Auslöser", .haTrigger, #"{"trigger":"","target":{"entity_id":""},"options":{}}"#, ["trigger"], "Integrationsabhängige Auslöser mit ihrem HA-Konfigurationsschema."),
            flow("condition.state", "Zustand", .haCondition, #"{"condition":"state","entity_id":"binary_sensor.bewegung","state":"on"}"#, ["entity_id","state"]),
            flow("condition.numeric", "Numerischer Bereich", .haCondition, #"{"condition":"numeric_state","entity_id":"sensor.temperatur","above":18,"below":25}"#, ["entity_id"]),
            flow("condition.template", "Template", .haCondition, #"{"condition":"template","value_template":"{{ true }}"}"#, ["value_template"]),
            flow("condition.time", "Zeitfenster / Wochentage", .haCondition, #"{"condition":"time","after":"08:00:00","before":"22:00:00","weekday":["mon","tue","wed","thu","fri"]}"#),
            flow("condition.sun", "Sonnenstand", .haCondition, #"{"condition":"sun","after":"sunset","after_offset":"00:00:00"}"#),
            flow("condition.zone", "In einer Zone", .haCondition, #"{"condition":"zone","entity_id":"person.person","zone":"zone.home"}"#, ["entity_id","zone"]),
            flow("condition.device", "Gerätebedingung", .haCondition, #"{"condition":"device","device_id":"","domain":"","type":""}"#, ["device_id","domain","type"]),
            flow("condition.trigger", "Ausgelöst durch", .haCondition, #"{"condition":"trigger","id":"ausloeser_1"}"#, ["id"]),
            flow("condition.and", "Alle Bedingungen (UND)", .haCondition, #"{"condition":"and","conditions":[{"condition":"template","value_template":"{{ true }}"}]}"#, ["conditions"]),
            flow("condition.or", "Eine Bedingung (ODER)", .haCondition, #"{"condition":"or","conditions":[{"condition":"template","value_template":"{{ true }}"}]}"#, ["conditions"]),
            flow("condition.not", "Bedingungen negieren", .haCondition, #"{"condition":"not","conditions":[{"condition":"template","value_template":"{{ false }}"}]}"#, ["conditions"]),
            flow("condition.custom", "Weitere HA-Bedingung", .haCondition, #"{"condition":"","target":{"entity_id":""},"options":{}}"#, ["condition"]),
            flow("action.service", "Aktion / Dienst aufrufen", .haAction, #"{"action":"light.turn_on","target":{"entity_id":"light.flur"},"data":{}}"#, ["action"], "Beliebige Aktion aller installierten Integrationen; Daten und Ziel frei konfigurierbar."),
            flow("action.device", "Geräteaktion", .haAction, #"{"device_id":"","domain":"","type":""}"#, ["device_id","domain","type"]),
            flow("action.scene", "Szene aktivieren", .haAction, #"{"action":"scene.turn_on","target":{"entity_id":"scene.abend"}}"#, ["target.entity_id"]),
            flow("action.script", "Skript ausführen", .haAction, #"{"action":"script.turn_on","target":{"entity_id":"script.abend"}}"#, ["target.entity_id"]),
            flow("action.delay", "Warten (Dauer)", .haAction, #"{"delay":{"seconds":5}}"#),
            flow("action.waitTemplate", "Auf Bedingung warten", .haAction, #"{"wait_template":"{{ is_state('binary_sensor.bewegung', 'off') }}","timeout":{"minutes":5},"continue_on_timeout":false}"#, ["wait_template"]),
            flow("action.waitTrigger", "Auf Auslöser warten", .haAction, #"{"wait_for_trigger":[{"trigger":"state","entity_id":"binary_sensor.bewegung","to":"off"}],"timeout":{"minutes":5},"continue_on_timeout":false}"#, ["wait_for_trigger"]),
            flow("action.choose", "Auswahl (Choose)", .haAction, #"{"choose":[{"conditions":[{"condition":"template","value_template":"{{ true }}"}],"sequence":[{"delay":{"seconds":1}}]}],"default":[]}"#, ["choose"]),
            flow("action.if", "Wenn / Dann / Sonst", .haAction, #"{"if":[{"condition":"template","value_template":"{{ true }}"}],"then":[{"delay":{"seconds":1}}],"else":[]}"#, ["if","then"]),
            flow("action.repeat", "Wiederholen (Anzahl)", .haAction, #"{"repeat":{"count":3,"sequence":[{"delay":{"seconds":1}}]}}"#, ["repeat.sequence"]),
            flow("action.forEach", "Für jeden Eintrag", .haAction, #"{"repeat":{"for_each":["light.flur"],"sequence":[{"action":"light.turn_on","target":{"entity_id":"{{ repeat.item }}"}}]}}"#, ["repeat.sequence"]),
            flow("action.while", "Solange wiederholen", .haAction, #"{"repeat":{"while":[{"condition":"template","value_template":"{{ repeat.index <= 3 }}"}],"sequence":[{"delay":{"seconds":1}}]}}"#, ["repeat.sequence"]),
            flow("action.until", "Wiederholen bis", .haAction, #"{"repeat":{"until":[{"condition":"template","value_template":"{{ repeat.index >= 3 }}"}],"sequence":[{"delay":{"seconds":1}}]}}"#, ["repeat.sequence"]),
            flow("action.parallel", "Parallel ausführen", .haAction, #"{"parallel":[{"sequence":[{"delay":{"seconds":1}}]},{"sequence":[{"delay":{"seconds":2}}]}]}"#, ["parallel"]),
            flow("action.sequence", "Aktionsgruppe", .haAction, #"{"sequence":[{"delay":{"seconds":1}}]}"#, ["sequence"]),
            flow("action.variables", "Variablen setzen", .haAction, #"{"variables":{"helligkeit":80}}"#),
            flow("action.event", "Ereignis auslösen", .haAction, #"{"event":"nodivra_event","event_data":{}}"#, ["event"]),
            flow("action.stop", "Ablauf beenden", .haAction, #"{"stop":"Ablauf beendet","error":false}"#),
            flow("action.response", "Sprachantwort", .haAction, #"{"set_conversation_response":"Erledigt."}"#),
            flow("action.timerStart", "Timer starten", .haAction, #"{"action":"timer.start","target":{"entity_id":"timer.nachlauf"},"data":{"duration":"00:00:05"}}"#, ["target.entity_id"]),
            flow("action.timerPause", "Timer pausieren", .haAction, #"{"action":"timer.pause","target":{"entity_id":"timer.nachlauf"}}"#, ["target.entity_id"]),
            flow("action.timerCancel", "Timer abbrechen", .haAction, #"{"action":"timer.cancel","target":{"entity_id":"timer.nachlauf"}}"#, ["target.entity_id"]),
            flow("action.timerFinish", "Timer abschließen", .haAction, #"{"action":"timer.finish","target":{"entity_id":"timer.nachlauf"}}"#, ["target.entity_id"]),
            flow("action.timerChange", "Timer-Dauer ändern", .haAction, #"{"action":"timer.change","target":{"entity_id":"timer.nachlauf"},"data":{"duration":5}}"#, ["target.entity_id"]),
            flow("action.counterUp", "Zähler erhöhen", .haAction, #"{"action":"counter.increment","target":{"entity_id":"counter.zaehler"}}"#, ["target.entity_id"]),
            flow("action.counterDown", "Zähler verringern", .haAction, #"{"action":"counter.decrement","target":{"entity_id":"counter.zaehler"}}"#, ["target.entity_id"]),
            flow("action.counterReset", "Zähler zurücksetzen", .haAction, #"{"action":"counter.reset","target":{"entity_id":"counter.zaehler"}}"#, ["target.entity_id"]),
            flow("action.number", "Zahlenhelfer setzen", .haAction, #"{"action":"input_number.set_value","target":{"entity_id":"input_number.sollwert"},"data":{"value":20}}"#, ["target.entity_id"]),
            flow("action.text", "Texthelfer setzen", .haAction, #"{"action":"input_text.set_value","target":{"entity_id":"input_text.status"},"data":{"value":"Bereit"}}"#, ["target.entity_id"]),
            flow("action.select", "Auswahlhelfer setzen", .haAction, #"{"action":"input_select.select_option","target":{"entity_id":"input_select.modus"},"data":{"option":"Automatik"}}"#, ["target.entity_id"]),
            flow("action.datetime", "Datum / Uhrzeit setzen", .haAction, #"{"action":"input_datetime.set_datetime","target":{"entity_id":"input_datetime.zeit"},"data":{"time":"18:00:00"}}"#, ["target.entity_id"]),
            flow("action.button", "Taster betätigen", .haAction, #"{"action":"input_button.press","target":{"entity_id":"input_button.taster"}}"#, ["target.entity_id"]),
            flow("action.notify", "Benachrichtigung", .haAction, #"{"action":"persistent_notification.create","data":{"title":"Nodivra","message":"Automation ausgeführt"}}"#),
            flow("action.mqtt", "MQTT veröffentlichen", .haAction, #"{"action":"mqtt.publish","data":{"topic":"home/nodivra","payload":"on","retain":false}}"#),
            flow("action.custom", "Weitere HA-Aktion", .haAction, #"{"action":"","target":{},"data":{}}"#, ["action"])
        ]
        return result
    }()
    public static func descriptor(for block: Block) -> BlockDescriptor? { descriptors.first { $0.id == block.catalogID } }
}

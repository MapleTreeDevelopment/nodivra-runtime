import Foundation

public struct HAFieldChoice: Identifiable, Sendable {
    public let label: String
    public let value: ConfigValue
    public var id: String { value.json }
    public init(_ label: String, _ value: ConfigValue) { self.label = label; self.value = value }
}
/// Known HA values are selected by meaning; wire keys and values remain an implementation detail.
public enum HAFormSchema {
    public static func choices(field: String, type: String, role: BlockKind?) -> [HAFieldChoice] {
        func strings(_ pairs: [(String,String)]) -> [HAFieldChoice] { pairs.map { .init($0.1, .string($0.0)) } }
        let sun = [("sunrise","Sonnenaufgang"),("sunset","Sonnenuntergang")]
        switch field {
        case "event":
            if type == "sun" { return strings(sun) }
            if ["zone","geo_location"].contains(type) { return strings([("enter","Betreten"),("leave","Verlassen")]) }
            if type == "homeassistant" { return strings([("start","Gestartet"),("shutdown","Wird heruntergefahren")]) }
            if type == "calendar" { return strings([("start","Beginn"),("end","Ende")]) }
        case "before", "after": if type == "sun" { return strings(sun) }
        case "weekday": return strings([("mon","Montag"),("tue","Dienstag"),("wed","Mittwoch"),("thu","Donnerstag"),("fri","Freitag"),("sat","Samstag"),("sun","Sonntag")])
        case "allowed_methods": return strings([("POST","POST"),("PUT","PUT"),("GET","GET"),("HEAD","HEAD")])
        case "update_type": return strings([("added","Erstellt"),("removed","Entfernt"),("updated","Geändert"),("current","Bereits vorhanden")])
        case "mode": return strings([("single","Einzeln · weitere Starts ignorieren"),("restart","Neu starten"),("queued","Nacheinander einreihen"),("parallel","Parallel starten")])
        case "max_exceeded": return strings([("warning","Warnung protokollieren"),("error","Fehler protokollieren"),("info","Information protokollieren"),("debug","Diagnose protokollieren"),("silent","Nicht protokollieren")])
        case "qos": return [.init("0 · Höchstens einmal", .number(0)),.init("1 · Mindestens einmal", .number(1)),.init("2 · Genau einmal", .number(2))]
        case "match": return strings([("all","Alle Entitäten"),("any","Eine beliebige Entität")])
        default: break
        }
        return []
    }
    public static func fields(_ value: ConfigValue, role: BlockKind?, container: String = "") -> [String:ConfigValue] {
        var fields: [String:ConfigValue] = [:]
        if container == "automation" { return ["alias":.string(""),"description":.string(""),"mode":.string("single"),"max":.number(10),"max_exceeded":.string("warning"),"variables":.object([:]),"trigger_variables":.object([:]),"trace":.object(["stored_traces":.number(5)]),"initial_state":.bool(true)] }
        if container == "repeat" { return ["count":.number(3),"for_each":.array([]),"while":.array([]),"until":.array([]),"sequence":.array([])] }
        guard let role else { return fields }
        let type = HAConfiguration.type(value, role: role)
        for descriptor in BlockCatalog.descriptors where descriptor.kind == role && HAConfiguration.type(descriptor.defaults, role: role) == type {
            fields.merge(descriptor.defaults.object ?? [:]) { old,_ in old }
        }
        fields["alias"] = .string(""); fields["enabled"] = .bool(true)
        if role == .haTrigger { fields["id"] = .string(""); fields["variables"] = .object([:]) }
        if role == .haTrigger || role == .haCondition {
            switch type {
            case "state":
                fields.merge(["entity_id":.array([]),"attribute":.string(""),"for":.object(["seconds":.number(0)])]) { old,_ in old }
                if role == .haTrigger { fields.merge(["from":.string("off"),"to":.string("on"),"not_from":.array([]),"not_to":.array([])]) { old,_ in old } }
                else { fields["match"] = .string("all") }
            case "numeric_state": fields.merge(["above":.number(0),"below":.number(100),"attribute":.string(""),"value_template":.string("")]) { old,_ in old }; if role == .haTrigger { fields["for"] = .object(["seconds":.number(0)]) }
            case "sun":
                if role == .haCondition { fields.merge(["before":.string("sunrise"),"after":.string("sunset"),"before_offset":.string("00:00:00"),"after_offset":.string("00:00:00")]) { old,_ in old } }
                else { fields["offset"] = .string("00:00:00") }
            case "time": if role == .haCondition { fields.merge(["before":.string("22:00:00"),"after":.string("08:00:00"),"weekday":.array(["mon","tue","wed","thu","fri","sat","sun"].map(ConfigValue.string))]) { old,_ in old } }
            case "time_pattern": fields.merge(["hours":.string("*"),"minutes":.string("*"),"seconds":.string("*")]) { old,_ in old }
            case "mqtt": fields.merge(["qos":.number(0),"encoding":.string("utf-8"),"value_template":.string("")]) { old,_ in old }
            case "template": if role == .haTrigger { fields["for"] = .object(["seconds":.number(0)]) }
            case "webhook": fields.merge(["allowed_methods":.array([.string("POST"),.string("PUT")]),"local_only":.bool(true)]) { old,_ in old }
            case "persistent_notification": fields["notification_id"] = .string("")
            case "event": fields["event_data"] = .object([:]); fields["context"] = .object([:])
            default: break
            }
        }
        if role == .haAction {
            fields["continue_on_error"] = .bool(false)
            if value.object?["action"] != nil || value.object?["service"] != nil { fields["target"] = .object([:]); fields["data"] = .object([:]); fields["response_variable"] = .string("") }
            if value.object?["wait_for_trigger"] != nil || value.object?["wait_template"] != nil { fields["timeout"] = .object(["seconds":.number(30)]); fields["continue_on_timeout"] = .bool(true) }
            if value.object?["if"] != nil { fields["else"] = .array([]) }
            if value.object?["choose"] != nil { fields["default"] = .array([]) }
        }
        return fields
    }
    /// HA service sections group fields for presentation; section names are not payload keys.
    public static func serviceFields(_ metadata: ConfigValue) -> [String:ConfigValue] {
        var result: [String:ConfigValue] = [:]
        for (name,info) in metadata.object?["fields"]?.object ?? [:] {
            if info.object?["fields"]?.object != nil { result.merge(serviceFields(info)) { first,_ in first } }
            else { result[name] = info }
        }
        return result
    }
    public static func defaultValue(metadata: ConfigValue) -> ConfigValue {
        if let value = metadata.object?["default"] { return value }
        let selector = metadata.object?["selector"]?.object ?? [:]
        if let options = selector["select"]?.object?["options"]?.array, let first = options.first {
            return selector["select"]?.object?["multiple"]?.bool == true ? .array([]) : first.object?["value"] ?? first
        }
        if let constant = selector["constant"]?.object?["value"] { return constant }
        if selector["color_temp"] != nil { return selector["color_temp"]?.object?["min"] ?? .number(2700) }
        if selector["number"] != nil { return selector["number"]?.object?["min"] ?? .number(0) }
        if selector["boolean"] != nil || metadata.object?["type"]?.string == "boolean" { return .bool(false) }
        if selector["duration"] != nil || metadata.object?["type"]?.string == "positive_time_period_dict" { return .object(["seconds":.number(0)]) }
        if selector["color_rgb"] != nil { return .array([.number(255),.number(255),.number(255)]) }
        if selector["time"] != nil { return .string("12:00:00") }
        if selector["object"] != nil { return .object([:]) }
        if ["integer","float"].contains(metadata.object?["type"]?.string ?? "") { return .number(0) }
        for key in ["entity","device","area","floor","label"] where selector[key]?.object?["multiple"]?.bool == true { return .array([]) }
        return .string("")
    }
    public static func seconds(_ value: ConfigValue) -> Double? {
        if let number = value.number { return number.isFinite ? number : nil }
        if let string = value.string {
            if let number = Double(string), number.isFinite { return number }
            let negative = string.hasPrefix("-"); let cleaned = negative ? String(string.dropFirst()) : string
            let parts = cleaned.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }), parts[1] < 60, parts[2] < 60 else { return nil }
            return (negative ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
        if let object = value.object, !object.isEmpty, Set(object.keys).isSubset(of: ["days","hours","minutes","seconds","milliseconds"]) {
            let units: [String:Double] = ["days":86400,"hours":3600,"minutes":60,"seconds":1,"milliseconds":0.001]
            var seconds = 0.0
            for (key,value) in object { guard let n = value.number, n.isFinite else { return nil }; seconds += n * units[key]! }
            return seconds
        }
        return nil
    }
    public static func clockString(seconds: Double) -> String {
        let n = abs(seconds).rounded(), hours = Int(n / 3600), minutes = Int(n.truncatingRemainder(dividingBy: 3600) / 60), rest = n.truncatingRemainder(dividingBy: 60)
        return (seconds < 0 ? "-" : "") + String(format: "%02d:%02d:%02.0f", hours, minutes, rest)
    }
}

import Foundation
import JavaScriptCore

/// Runs spelunkr.tv's own schedule code (extracted into Engine/spelunkr-engine.js.txt)
/// in JavaScriptCore, so the app lands on the same tape at the same second as the website.
actor ScheduleEngine {
    enum EngineError: LocalizedError {
        case missingScript
        case script(String)
        var errorDescription: String? {
            switch self {
            case .missingScript: return "The schedule engine is missing from the app."
            case .script(let m): return "Schedule engine error: \(m)"
            }
        }
    }

    private let context: JSContext

    init() throws {
        guard let url = Bundle.main.url(forResource: "spelunkr-engine.js", withExtension: "txt"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else {
            throw EngineError.missingScript
        }
        // A custom handler replaces the default one, which is what stores the error in
        // `context.exception`; keep doing that, or script errors would go unnoticed.
        ctx.exceptionHandler = { context, exception in
            context?.exception = exception
            print("[engine] \(exception?.toString() ?? "unknown JS error")")
        }
        ctx.evaluateScript("var console = { log: function(){}, warn: function(){}, error: function(){} };")
        ctx.evaluateScript(source)
        if let exc = ctx.exception {
            throw EngineError.script(exc.toString() ?? "failed to load")
        }
        context = ctx
    }

    private func call(_ name: String, _ args: [Any]) throws -> JSValue? {
        context.exception = nil
        let result = context.objectForKeyedSubscript(name)?.call(withArguments: args)
        if let exc = context.exception {
            context.exception = nil
            throw EngineError.script(exc.toString() ?? name)
        }
        return result
    }

    func presenceConfig() -> PresenceConfig? {
        guard let value = (try? call("spkPresenceConfig", [])) ?? nil,
              value.isString, let json = value.toString() else { return nil }
        return try? JSONDecoder().decode(PresenceConfig.self, from: Data(json.utf8))
    }

    func hasVersion(channel: String, v: Int) -> Bool {
        guard let value = (try? call("spkHasVersion", [channel, v])) ?? nil else { return false }
        return value.toBool()
    }

    func addVersion(channel: String, manifest: String, platform: String?, pointer: VersionPointer) throws {
        let meta = try JSONEncoder().encode(pointer)
        let metaJSON = String(decoding: meta, as: UTF8.self)
        _ = try call("spkAddVersion", [channel, manifest, platform ?? NSNull(), metaJSON])
    }

    func onAir(channel: String, atMs: Double) -> OnAir? {
        guard let value = (try? call("spkNow", [channel, atMs])) ?? nil,
              value.isString, let json = value.toString() else { return nil }
        return try? JSONDecoder().decode(OnAir.self, from: Data(json.utf8))
    }

    func overlay(channel: String, atMs: Double) -> OverlayCue? {
        guard let value = (try? call("spkOverlay", [channel, atMs])) ?? nil,
              value.isString, let json = value.toString() else { return nil }
        return try? JSONDecoder().decode(OverlayCue.self, from: Data(json.utf8))
    }

    func upcoming(channel: String, atMs: Double, count: Int) -> [GuideEntry] {
        guard let value = (try? call("spkUpcoming", [channel, atMs, count])) ?? nil,
              value.isString, let json = value.toString() else { return [] }
        return (try? JSONDecoder().decode([GuideEntry].self, from: Data(json.utf8))) ?? []
    }

    func range(channel: String, fromMs: Double, toMs: Double) -> [GuideProgram] {
        guard let value = (try? call("spkRange", [channel, fromMs, toMs])) ?? nil,
              value.isString, let json = value.toString() else { return [] }
        return (try? JSONDecoder().decode([GuideProgram].self, from: Data(json.utf8))) ?? []
    }

    func blocks(channel: String, fromMs: Double, toMs: Double) -> [GuideBlock] {
        guard let value = (try? call("spkBlocks", [channel, fromMs, toMs])) ?? nil,
              value.isString, let json = value.toString() else { return [] }
        return (try? JSONDecoder().decode([GuideBlock].self, from: Data(json.utf8))) ?? []
    }
}

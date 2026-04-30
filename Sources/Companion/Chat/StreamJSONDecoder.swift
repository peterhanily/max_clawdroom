import Foundation

/// Stateful decoder: stream-json JSONL lines → ClaudeCodeClient.Event values.
///
/// Tracks per-message content-block index → tool_use id mapping so that
/// `content_block_delta` and `content_block_stop` events can be routed back
/// to the correct tool call. Indices reset on every `message_start`.
///
/// One decoder instance per long-lived subprocess. Thread-unsafe; call from
/// a single consumer task.
final class StreamJSONDecoder {
    enum Output {
        /// One event to yield to the current turn's continuation.
        case event(ClaudeCodeClient.Event)
        /// The subprocess just initialized. Captured session_id + model.
        case sessionStarted(id: String, model: String?)
        /// The current turn is complete. Caller should finish the continuation.
        case turnComplete
        /// Line was valid but irrelevant (status, rate limits, etc.).
        case ignored
        /// Line failed to parse. Non-fatal; caller may log.
        case decodeError(String)
    }

    /// Per-message state: index of a content block → tool_use id + name.
    private struct ToolBlock {
        let id: String
        let name: String
    }
    private var toolBlocksByIndex: [Int: ToolBlock] = [:]

    private var lastTextDeltaAt: Date?

    func decode(line: String) -> [Output] {
        guard
            let data = line.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = obj["type"] as? String
        else {
            return [.decodeError("invalid JSON: \(line.prefix(120))")]
        }

        switch type {
        case "system":
            return handleSystem(obj)

        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else {
                return [.ignored]
            }
            return handleStreamEvent(event)

        case "assistant":
            // Redundant with stream_events — we already emitted deltas.
            return [.ignored]

        case "user":
            // Tool results come back as `type: "user"` messages whose
            // content array contains one or more `tool_result` blocks.
            // Each references the tool_use_id of an earlier tool_use.
            return handleUserMessage(obj)

        case "result":
            return [.turnComplete]

        case "rate_limit_event":
            return [.ignored]

        default:
            return [.ignored]
        }
    }

    // MARK: - user (tool results)

    /// Shape of a claude-code tool-result user message:
    ///
    ///     {
    ///       "type": "user",
    ///       "message": {
    ///         "role": "user",
    ///         "content": [
    ///           { "type": "tool_result",
    ///             "tool_use_id": "toolu_...",
    ///             "content": "stdout string" | [ {type:"text", text:"..."} ],
    ///             "is_error": false }
    ///         ]
    ///       }
    ///     }
    private func handleUserMessage(_ obj: [String: Any]) -> [Output] {
        guard
            let message = obj["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return [.ignored] }

        var outputs: [Output] = []
        for block in content {
            guard (block["type"] as? String) == "tool_result",
                  let id = block["tool_use_id"] as? String
            else { continue }

            let text = flattenToolResultContent(block["content"])
            let isError = (block["is_error"] as? Bool) ?? false
            outputs.append(.event(.toolCallResult(id: id, content: text, isError: isError)))
        }
        return outputs.isEmpty ? [.ignored] : outputs
    }

    /// `content` may be a plain string or an array of text blocks. Collapse
    /// either shape to a single display string.
    private func flattenToolResultContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { b -> String? in
                let t = (b["type"] as? String) ?? ""
                if t == "text" { return b["text"] as? String }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - system

    private func handleSystem(_ obj: [String: Any]) -> [Output] {
        let subtype = obj["subtype"] as? String
        if subtype == "init" {
            let sid = (obj["session_id"] as? String) ?? ""
            let model = obj["model"] as? String
            toolBlocksByIndex.removeAll()
            lastTextDeltaAt = nil
            return [.sessionStarted(id: sid, model: model)]
        }
        return [.ignored]
    }

    // MARK: - stream_event

    private func handleStreamEvent(_ event: [String: Any]) -> [Output] {
        guard let kind = event["type"] as? String else { return [.ignored] }

        switch kind {
        case "message_start":
            // New assistant message within the turn — reset content-block state.
            toolBlocksByIndex.removeAll()
            return [.ignored]

        case "content_block_start":
            return handleContentBlockStart(event)

        case "content_block_delta":
            return handleContentBlockDelta(event)

        case "content_block_stop":
            return handleContentBlockStop(event)

        case "message_delta", "message_stop":
            // End of one assistant message. A follow-up message may arrive
            // (e.g. after a tool_result). Turn boundary is the `result` event.
            return [.ignored]

        default:
            return [.ignored]
        }
    }

    private func handleContentBlockStart(_ event: [String: Any]) -> [Output] {
        guard
            let index = event["index"] as? Int,
            let block = event["content_block"] as? [String: Any],
            let blockType = block["type"] as? String
        else { return [.ignored] }

        if blockType == "tool_use",
           let id = block["id"] as? String,
           let name = block["name"] as? String
        {
            toolBlocksByIndex[index] = ToolBlock(id: id, name: name)
            return [.event(.toolCallBegin(id: id, name: name))]
        }
        // text blocks produce no start event; deltas will follow.
        return [.ignored]
    }

    private func handleContentBlockDelta(_ event: [String: Any]) -> [Output] {
        guard
            let index = event["index"] as? Int,
            let delta = event["delta"] as? [String: Any],
            let deltaType = delta["type"] as? String
        else { return [.ignored] }

        switch deltaType {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else {
                return [.ignored]
            }
            var outputs: [Output] = [.event(.text(text))]
            let now = Date()
            if let last = lastTextDeltaAt {
                let gapMs = now.timeIntervalSince(last) * 1000
                let lat = normalizeLatency(ms: gapMs)
                outputs.append(.event(.tokenLatency(lat)))
            }
            lastTextDeltaAt = now
            return outputs

        case "input_json_delta":
            guard
                let block = toolBlocksByIndex[index],
                let partial = delta["partial_json"] as? String,
                !partial.isEmpty
            else { return [.ignored] }
            return [.event(.toolCallArgs(id: block.id, argumentsDelta: partial))]

        case "thinking_delta":
            // Phase 3 — new cognition.thinking signal. Ignored for v1.
            return [.ignored]

        default:
            return [.ignored]
        }
    }

    private func handleContentBlockStop(_ event: [String: Any]) -> [Output] {
        guard let index = event["index"] as? Int else { return [.ignored] }
        guard let block = toolBlocksByIndex.removeValue(forKey: index) else {
            // text block stopping — nothing to emit.
            return [.ignored]
        }
        return [.event(.toolCallEnd(id: block.id))]
    }

    // MARK: - Helpers

    /// Log-scale normalize inter-token latency (20ms..500ms → 0..1). Matches
    /// the scale the old ClawdexClient used so existing bindings feel the same.
    private func normalizeLatency(ms: Double) -> Double {
        let lo: Double = 20
        let hi: Double = 500
        let clamped = max(lo, min(hi, ms))
        let ratio = log(clamped / lo) / log(hi / lo)
        return max(0, min(1, ratio))
    }
}

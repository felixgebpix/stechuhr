// stechuhr-hook: called by Claude Code hooks. Reads the hook JSON from stdin, keeps only
// time-tracking fields (no prompts, no messages), and sends them to the Stechuhr app on
// 127.0.0.1. If the app is not running, appends the event to a local inbox file that the
// app imports on its next start. Never fails loudly and never takes longer than ~1s.
import Foundation

let port = 47600
let keep = ["session_id", "hook_event_name", "cwd", "notification_type", "source", "reason", "agent_id", "session_title"]

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let raw = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      raw["session_id"] is String, raw["hook_event_name"] is String else { exit(0) }

var event: [String: Any] = [
    "uuid": UUID().uuidString,
    "ts": Date().timeIntervalSince1970,
]
for k in keep { if let v = raw[k] as? String { event[k] = v } }
if event["cwd"] == nil { event["cwd"] = FileManager.default.currentDirectoryPath }
guard let body = try? JSONSerialization.data(withJSONObject: event) else { exit(0) }

var delivered = false
var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/claude-code/events")!)
req.httpMethod = "POST"
req.httpBody = body
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.timeoutInterval = 0.8
let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = 0.8
config.timeoutIntervalForResource = 0.8
config.connectionProxyDictionary = [:]
let done = DispatchSemaphore(value: 0)
URLSession(configuration: config).dataTask(with: req) { _, resp, _ in
    delivered = ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    done.signal()
}.resume()
_ = done.wait(timeout: .now() + 1.0)

if !delivered {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Stechuhr", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("claude-events.jsonl").path
    // One write() with O_APPEND keeps concurrent hook calls from interleaving lines.
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    if fd >= 0 {
        var line = body
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}
exit(0)

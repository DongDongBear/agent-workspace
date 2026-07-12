import AppKit
import Darwin
import Foundation
import WebKit

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct SessionRow {
    let id: String
    let pane: String
    let generation: String
    let provider: String
    let cwd: String
    let path: String
    let title: String
    let activity: String
    let state: String

    var json: [String: Any] {
        [
            "id": id,
            "pane": pane,
            "generation": generation,
            "provider": provider,
            "cwd": cwd,
            "path": path,
            "title": title,
            "activity": activity,
            "state": state,
        ]
    }
}

private struct SessionTarget {
    let pane: String
    let generation: String
    let claudePID: Int32?
    let cwd: String
}

private struct HistoryEntry {
    let id: String
    let role: String
    var text: String
    let timestamp: String

    var json: [String: Any] {
        ["id": id, "role": role, "text": text, "timestamp": timestamp]
    }
}

private struct TranscriptFileState {
    let identity: String
    let size: UInt64
    let revision: String
}

private struct OpenTool {
    let index: Int
    let name: String
}

private struct TranscriptCache {
    var identity: String
    var offset: UInt64
    var revision: String
    var checkpoint: String
    var lastAccess: UInt64
    var pending = Data()
    var droppingOversizedLine = false
    var chunks: [String] = []
    var seenUUIDs = Set<String>()
    var openTools: [String: OpenTool] = [:]
    var thinkingIndex: Int?
}

private struct ClaudeSessionMetadata: Decodable {
    let pid: Int
    let sessionId: String
    let cwd: String
}

private final class TmuxBackend {
    let defaultCwd: String
    let home: String
    let tmux: String
    private var sessionTargets: [String: SessionTarget] = [:]
    private var historyCache: [String: TranscriptCache] = [:]
    private var historyClock: UInt64 = 0
    private let historyCacheLimit = 2
    private let maxTranscriptFileBytes: UInt64 = 64 * 1024 * 1024
    private let transcriptReadChunkBytes = 256 * 1024
    private let maxTranscriptRecordBytes = 2 * 1024 * 1024
    private var transcriptOverrides: [Int32: URL] = [:]
    private var uiTestRow: SessionRow?
    private var uiTestClaudePID: Int32?
    private var demoRows: [SessionRow]?
    private var demoHistory: [String: [HistoryEntry]] = [:]

    var presentedCwd: String { demoRows == nil ? defaultCwd : "~/Projects/atlas" }

    init(
        defaultCwd: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: defaultCwd, isDirectory: &isDirectory), isDirectory.boolValue {
            self.defaultCwd = URL(fileURLWithPath: defaultCwd).standardizedFileURL.path
        } else {
            self.defaultCwd = FileManager.default.homeDirectoryForCurrentUser.path
        }
        self.tmux = ["\(home)/.local/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/opt/homebrew/bin/tmux"
    }

    func run(_ executable: String, _ arguments: [String], input: Data? = nil) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = inputPipe
        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(input)
                inputPipe.fileHandleForWriting.closeFile()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

    func sessions() throws -> [SessionRow] {
        if let demoRows { return demoRows }
        if let row = uiTestRow {
            sessionTargets = [row.id: SessionTarget(pane: row.pane, generation: row.generation, claudePID: uiTestClaudePID, cwd: row.cwd)]
            return [row]
        }
        let script = try bridgeScript("sesslist")
        let result = run("/bin/bash", [script])
        guard result.status == 0 else { throw BackendError(result.output.isEmpty ? "Could not list tmux sessions." : result.output) }
        let parsed: [(row: SessionRow, target: SessionTarget)] = result.output.split(separator: "\n").compactMap { rawLine in
            let fields = rawLine.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let claudePID = Int32(fields[5]) else { return nil }
            let decorated = String(fields[3])
            let pane = String(fields[4])
            guard pane.hasPrefix("%") else { return nil }
            let plain = stripTerminalCodes(decorated).trimmingCharacters(in: .whitespaces)
            let activityAndTitle = parseDisplay(plain)
            let row = SessionRow(
                id: String(fields[0]),
                pane: pane,
                generation: String(claudePID),
                provider: "claude",
                cwd: String(fields[1]),
                path: String(fields[2]),
                title: activityAndTitle.title.isEmpty ? "Claude Code" : activityAndTitle.title,
                activity: activityAndTitle.activity,
                state: decorated.contains("38;5;64m●") ? "ready" : "working"
            )
            return (row, SessionTarget(pane: pane, generation: String(claudePID), claudePID: claudePID, cwd: row.cwd))
        }
        sessionTargets = Dictionary(uniqueKeysWithValues: parsed.map { ($0.row.id, $0.target) })
        return parsed.map { $0.row }
    }

    func prepareDemo() {
        let rows = [
            SessionRow(id: "demo-1", pane: "%101", generation: "demo-1", provider: "claude", cwd: "/Users/demo/Projects/atlas", path: "~/Projects/atlas", title: "Polish onboarding flow", activity: "07-11 09:42", state: "ready"),
            SessionRow(id: "demo-2", pane: "%102", generation: "demo-2", provider: "claude", cwd: "/Users/demo/Projects/atlas", path: "~/Projects/atlas", title: "Review API migration", activity: "07-11 09:38", state: "working"),
            SessionRow(id: "demo-3", pane: "%103", generation: "demo-3", provider: "claude", cwd: "/Users/demo/Projects/docs", path: "~/Projects/docs", title: "Write release notes", activity: "07-11 08:16", state: "ready"),
            SessionRow(id: "demo-4", pane: "%104", generation: "demo-4", provider: "claude", cwd: "/Users/demo", path: "~", title: "Claude Code", activity: "07-10 18:24", state: "ready"),
        ]
        demoRows = rows
        demoHistory["demo-1"] = [
            HistoryEntry(
                id: "demo-terminal-1",
                role: "terminal",
                text: """
                ╭─── Claude Code ─────────────────────────────────────────────╮
                │ ~/Projects/atlas                                            │
                ╰─────────────────────────────────────────────────────────────╯

                ❯ Tighten the onboarding empty state and keep the layout calm.

                ● Implemented the final pass:
                  - Aligned the icon, title, metadata, and menu to a fixed grid
                  - Replaced the heavy selection treatment with a quiet state
                  - Kept keyboard navigation and readable contrast intact

                The workspace is ready for review.

                ❯
                """,
                timestamp: ""
            ),
        ]
    }

    func prepareUITestSession(claudePID: Int32? = nil) throws {
        let session = "ccw-ui-\(getpid())"
        let historyFixture = "printf 'ccw-history-first\\n'; i=1; while [ $i -le 260 ]; do printf 'ccw-history-fill-%03d\\n' $i; i=$((i + 1)); done; printf 'ccw-history-last\\n'; exec /bin/cat"
        let started = run(tmux, ["new-session", "-d", "-s", session, "-x", "100", "-y", "20", historyFixture])
        guard started.status == 0 else { throw BackendError(started.output) }
        let paneResult = run(tmux, ["display-message", "-p", "-t", "=\(session):", "#{pane_id}"])
        let pane = paneResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard paneResult.status == 0, pane.hasPrefix("%") else {
            _ = run(tmux, ["kill-session", "-t", "=\(session)"])
            throw BackendError(paneResult.output)
        }
        uiTestRow = SessionRow(
            id: session,
            pane: pane,
            generation: "ui-\(pane)",
            provider: "claude",
            cwd: defaultCwd,
            path: "~",
            title: "UI Test",
            activity: "Now",
            state: "ready"
        )
        uiTestClaudePID = claudePID
        sessionTargets[session] = SessionTarget(pane: pane, generation: "ui-\(pane)", claudePID: claudePID, cwd: defaultCwd)
    }

    func cleanupUITestSession() {
        guard let row = uiTestRow else { return }
        _ = run(tmux, ["kill-session", "-t", "=\(row.id)"])
        uiTestRow = nil
        uiTestClaudePID = nil
        sessionTargets.removeValue(forKey: row.id)
    }

    func validateTranscriptTail() throws {
        let pid = Int32(getpid())
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-workspace-live-\(UUID().uuidString).jsonl")
        let fixture = """
        {"type":"user","uuid":"u1","message":{"content":"Pane-static prompt"}}
        {"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"Transcript-only answer"}]}}
        """
        try (fixture + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        transcriptOverrides[pid] = transcript
        try prepareUITestSession(claudePID: pid)
        defer {
            cleanupUITestSession()
            transcriptOverrides.removeValue(forKey: pid)
            historyCache.removeValue(forKey: transcript.path)
            try? FileManager.default.removeItem(at: transcript)
        }
        func append(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        func output(_ payload: [String: Any]) -> String {
            ((payload["history"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        guard let row = try sessions().first else { throw BackendError("Transcript fixture did not start.") }
        let paneBefore = run(tmux, ["capture-pane", "-ep", "-S", "-", "-t", row.pane]).output
        let initial = try history(row.id, pane: row.pane, generation: row.generation, revision: nil)
        guard output(initial).contains("❯ Pane-static prompt"),
              output(initial).contains("Transcript-only answer"),
              let initialRevision = initial["revision"] as? String else {
            throw BackendError("A growing Claude transcript was invisible while its tmux pane stayed static.")
        }
        let unchanged = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: initialRevision
        )
        guard unchanged["unchanged"] as? Bool == true, unchanged["history"] == nil else {
            throw BackendError("An unchanged transcript rebuilt its full history.")
        }

        let tool = Data("""
        {"type":"assistant","uuid":"tool-1","message":{"id":"m1","content":[{"type":"tool_use","id":"call-1","name":"Bash","input":{"command":"PRIVATE INPUT MUST STAY HIDDEN"}}]}}

        """.utf8)
        let midpoint = tool.count / 2
        try append(Data(tool[..<midpoint]))
        let partial = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: initialRevision
        )
        guard partial["unchanged"] as? Bool == true,
              partial["history"] == nil,
              let partialRevision = partial["revision"] as? String,
              partialRevision != initialRevision else {
            throw BackendError("A partial JSONL record incorrectly changed visible history.")
        }
        try append(Data(tool[midpoint...]))
        let running = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: partialRevision
        )
        guard output(running).contains("● Bash"),
              !output(running).contains("PRIVATE INPUT MUST STAY HIDDEN"),
              let runningRevision = running["revision"] as? String else {
            throw BackendError("Tool activity did not become visible after its JSONL record completed.")
        }

        let completion = """
        {"type":"assistant","uuid":"tool-1","message":{"id":"m1","content":[{"type":"text","text":"DUPLICATE UUID MUST STAY HIDDEN"}]}}
        {"type":"user","uuid":"result-1","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"RAW TOOL OUTPUT MUST STAY HIDDEN"}]}}
        {"type":"user","uuid":"meta-1","isMeta":true,"message":{"content":"META MUST STAY HIDDEN"}}
        {"type":"user","uuid":"task-1","message":{"content":"<task-notification>INTERNAL TASK MUST STAY HIDDEN</task-notification>"}}
        {"type":"user","uuid":"bash-1","message":{"content":"<bash-stdout>RAW BASH OUTPUT MUST STAY HIDDEN</bash-stdout>"}}
        """
        try append(Data((completion + "\n").utf8))
        let completed = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: runningRevision
        )
        let completedOutput = output(completed)
        guard completedOutput.contains("● Bash\n  ⎿ Done"),
              !completedOutput.contains("DUPLICATE UUID"),
              !completedOutput.contains("RAW TOOL OUTPUT"),
              !completedOutput.contains("META MUST"),
              !completedOutput.contains("INTERNAL TASK"),
              !completedOutput.contains("RAW BASH OUTPUT"),
              let completedRevision = completed["revision"] as? String else {
            throw BackendError("Tool completion filtering or UUID deduplication regressed.")
        }

        let thinking = """
        {"type":"assistant","uuid":"thinking-1","message":{"id":"m1","content":[{"type":"thinking","thinking":"PRIVATE REASONING MUST STAY HIDDEN"}]}}
        """
        try append(Data((thinking + "\n").utf8))
        let active = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: completedRevision
        )
        guard output(active).contains("✳ Thinking…"),
              !output(active).contains("PRIVATE REASONING"),
              let activeRevision = active["revision"] as? String else {
            throw BackendError("Thinking activity did not become visible without exposing private reasoning.")
        }
        let answer = """
        {"type":"assistant","uuid":"a2","message":{"id":"m1","content":[{"type":"text","text":"Second block from the same assistant message"}]}}
        """
        try append(Data((answer + "\n").utf8))
        let answered = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: activeRevision
        )
        guard output(answered).contains("Second block from the same assistant message"),
              !output(answered).contains("✳ Thinking…"),
              let answeredRevision = answered["revision"] as? String else {
            throw BackendError("Assistant blocks sharing one message ID were reordered or swallowed.")
        }

        let oldIdentity = transcriptFileState(transcript)?.identity
        let replacement = """
        {"type":"user","uuid":"replacement","message":{"content":"Replacement transcript"}}
        """
        try (replacement + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let replaced = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: answeredRevision
        )
        guard transcriptFileState(transcript)?.identity != oldIdentity,
              output(replaced) == "❯ Replacement transcript",
              let replacedRevision = replaced["revision"] as? String else {
            throw BackendError("Transcript replacement reused a stale byte offset or stale history.")
        }

        let replacementIdentity = transcriptFileState(transcript)?.identity
        let inPlace = """
        {"type":"user","uuid":"in-place","message":{"content":"In-place replacement"}}
        {"type":"assistant","uuid":"in-place-answer","message":{"id":"m2","content":[{"type":"text","text":"\(String(repeating: "x", count: 256))"}]}}
        """
        let rewrite = try FileHandle(forWritingTo: transcript)
        try rewrite.truncate(atOffset: 0)
        try rewrite.write(contentsOf: Data((inPlace + "\n").utf8))
        try rewrite.close()
        let rewritten = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: replacedRevision
        )
        guard transcriptFileState(transcript)?.identity == replacementIdentity,
              output(rewritten).contains("❯ In-place replacement"),
              !output(rewritten).contains("❯ Replacement transcript"),
              let rewrittenRevision = rewritten["revision"] as? String else {
            throw BackendError("An in-place transcript rewrite was mistaken for an append.")
        }

        try append(Data(repeating: 0x78, count: maxTranscriptRecordBytes + 1))
        let oversized = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: rewrittenRevision
        )
        guard oversized["unchanged"] as? Bool == true,
              let oversizedRevision = oversized["revision"] as? String else {
            throw BackendError("An oversized partial transcript record changed visible history.")
        }
        let recoveredLine = """
        {"type":"user","uuid":"recovered","message":{"content":"Recovered after oversized record"}}
        """
        try append(Data(("\n" + recoveredLine + "\n").utf8))
        let recovered = try history(
            row.id,
            pane: row.pane,
            generation: row.generation,
            revision: oversizedRevision
        )
        guard output(recovered).contains("❯ Recovered after oversized record") else {
            throw BackendError("Transcript tailing did not recover after an oversized record.")
        }
        let paneAfter = run(tmux, ["capture-pane", "-ep", "-S", "-", "-t", row.pane]).output
        guard paneAfter == paneBefore else {
            throw BackendError("Transcript regression fixture unexpectedly changed its tmux pane.")
        }
    }

    func validateTranscriptResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-workspace-resolver-\(UUID().uuidString)")
        let fixtureHome = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("project").path
        let pid: Int32 = 42_424
        let sessionID = "11111111-2222-3333-4444-555555555555"
        let sessions = fixtureHome.appendingPathComponent(".claude/sessions")
        let projects = fixtureHome.appendingPathComponent(".claude/projects")
        let projectName = URL(fileURLWithPath: cwd).standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
        let project = projects.appendingPathComponent(projectName)
        let transcript = project.appendingPathComponent("\(sessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "pid": Int(pid), "sessionId": sessionID, "cwd": cwd,
        ])
        try metadata.write(to: sessions.appendingPathComponent("\(pid).json"))
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"fixture\"}}\n".utf8)
            .write(to: transcript)

        let resolver = TmuxBackend(defaultCwd: cwd, home: fixtureHome.path)
        guard resolver.transcriptURL(for: pid, cwd: cwd)?.path == transcript.path,
              resolver.transcriptURL(for: pid, cwd: root.appendingPathComponent("other").path) == nil else {
            throw BackendError("Transcript resolver did not bind PID metadata to the exact tmux cwd.")
        }

        try FileManager.default.removeItem(at: transcript)
        let wrongProject = projects.appendingPathComponent("wrong-project")
        try FileManager.default.createDirectory(at: wrongProject, withIntermediateDirectories: true)
        try Data("wrong".utf8).write(to: wrongProject.appendingPathComponent("\(sessionID).jsonl"))
        guard resolver.transcriptURL(for: pid, cwd: cwd) == nil else {
            throw BackendError("Transcript resolver scanned into a different Claude project.")
        }

        let outside = root.appendingPathComponent("outside.jsonl")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: outside)
        guard resolver.transcriptURL(for: pid, cwd: cwd) == nil else {
            throw BackendError("Transcript resolver followed a symlink outside Claude projects.")
        }

        try FileManager.default.removeItem(at: transcript)
        _ = FileManager.default.createFile(atPath: transcript.path, contents: Data())
        let oversized = try FileHandle(forWritingTo: transcript)
        try oversized.truncate(atOffset: maxTranscriptFileBytes + 1)
        try oversized.close()
        guard let oversizedURL = resolver.transcriptURL(for: pid, cwd: cwd),
              resolver.transcriptFileState(oversizedURL) == nil else {
            throw BackendError("An oversized transcript bypassed the memory safety limit.")
        }
    }

    func validateLifecycleIsolation() throws {
        let session = "ccw-lifecycle-\(getpid())-\(UUID().uuidString.prefix(8))"
        let started = run(tmux, ["new-session", "-d", "-s", session, "/bin/cat"])
        guard started.status == 0 else { throw BackendError(started.output) }
        defer { _ = run(tmux, ["kill-session", "-t", "=\(session)"]) }

        cleanupUITestSession()
        let survived = run(tmux, ["has-session", "-t", "=\(session)"])
        guard survived.status == 0 else {
            throw BackendError("Application shutdown cleanup killed an ordinary tmux session.")
        }
    }

    func history(_ session: String, pane: String, generation: String, revision clientRevision: String?) throws -> [String: Any] {
        if let row = demoRows?.first(where: { $0.id == session && $0.pane == pane && $0.generation == generation }) {
            let revision = "demo:\(row.id)"
            if clientRevision == revision { return ["revision": revision, "unchanged": true] }
            return ["history": (demoHistory[row.id] ?? []).map(\.json), "revision": revision, "unchanged": false]
        }
        let target = try requireLiveCachedTarget(session, pane: pane, generation: generation)
        if let pid = target.claudePID,
           let transcript = transcriptURL(for: pid, cwd: target.cwd),
           let fileState = transcriptFileState(transcript) {
            return try transcriptHistory(transcript, fileState: fileState, revision: clientRevision)
        }
        return try fallbackHistory(target.pane, revision: clientRevision)
    }

    private func transcriptHistory(
        _ url: URL,
        fileState: TranscriptFileState,
        revision clientRevision: String?
    ) throws -> [String: Any] {
        let key = url.path
        historyClock &+= 1
        let access = historyClock
        if clientRevision == fileState.revision {
            if var cached = historyCache[key] {
                cached.lastAccess = access
                historyCache[key] = cached
            }
            return ["revision": fileState.revision, "unchanged": true]
        }
        let cache: TranscriptCache
        if var cached = historyCache[key], cached.revision == fileState.revision {
            cached.lastAccess = access
            historyCache[key] = cached
            cache = cached
        } else if var cached = historyCache[key],
                  cached.identity == fileState.identity,
                  fileState.size > cached.offset,
                  try transcriptCheckpoint(
                    url,
                    through: cached.offset,
                    identity: fileState.identity
                  ) == cached.checkpoint {
            let previousRevision = cached.revision
            let visibleChange = try readTranscript(
                url,
                from: cached.offset,
                to: fileState.size,
                identity: fileState.identity,
                into: &cached
            )
            cached.offset = fileState.size
            cached.revision = fileState.revision
            cached.checkpoint = try transcriptCheckpoint(
                url,
                through: fileState.size,
                identity: fileState.identity
            )
            cached.lastAccess = access
            historyCache[key] = cached
            trimHistoryCache(keeping: key)
            if clientRevision == previousRevision, !visibleChange {
                return ["revision": fileState.revision, "unchanged": true]
            }
            cache = cached
        } else {
            let rebuilt = try rebuildTranscriptCache(url, fileState: fileState, access: access)
            historyCache[key] = rebuilt
            trimHistoryCache(keeping: key)
            cache = rebuilt
        }
        let output = cache.chunks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let entries = output.isEmpty ? [] : [
            HistoryEntry(
                id: "transcript-\(stableDigest(Data(output.utf8)))",
                role: "terminal",
                text: output,
                timestamp: ""
            )
        ]
        return [
            "history": entries.map(\.json),
            "revision": fileState.revision,
            "unchanged": false,
        ]
    }

    private func rebuildTranscriptCache(
        _ url: URL,
        fileState: TranscriptFileState,
        access: UInt64
    ) throws -> TranscriptCache {
        var cache = TranscriptCache(
            identity: fileState.identity,
            offset: 0,
            revision: fileState.revision,
            checkpoint: "",
            lastAccess: access
        )
        _ = try readTranscript(
            url,
            from: 0,
            to: fileState.size,
            identity: fileState.identity,
            into: &cache
        )
        cache.offset = fileState.size
        cache.checkpoint = try transcriptCheckpoint(
            url,
            through: fileState.size,
            identity: fileState.identity
        )
        return cache
    }

    private func trimHistoryCache(keeping key: String) {
        while historyCache.count > historyCacheLimit,
              let victim = historyCache
                .filter({ $0.key != key })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            historyCache.removeValue(forKey: victim)
        }
    }

    private func transcriptURL(for pid: Int32, cwd: String) -> URL? {
        if let override = transcriptOverrides[pid] { return override }
        let metadataURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ClaudeSessionMetadata.self, from: data),
              metadata.pid == Int(pid),
              canonicalPath(metadata.cwd) == canonicalPath(cwd),
              !metadata.sessionId.isEmpty,
              metadata.sessionId.unicodeScalars.allSatisfy(
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains
              ) else { return nil }
        let project = URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let expected = projects
            .appendingPathComponent(project)
            .appendingPathComponent("\(metadata.sessionId).jsonl")
        return safeTranscript(expected, under: projects)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func safeTranscript(_ candidate: URL, under root: URL) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return resolved
    }

    private func transcriptFileState(_ url: URL) -> TranscriptFileState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let identity = "\(device.uint64Value):\(inode.uint64Value)"
        let nanoseconds = Int64(modified.timeIntervalSince1970 * 1_000_000_000)
        let bytes = size.uint64Value
        guard bytes <= maxTranscriptFileBytes else { return nil }
        return TranscriptFileState(
            identity: identity,
            size: bytes,
            revision: "file:\(identity):\(nanoseconds):\(bytes)"
        )
    }

    private func readTranscript(
        _ url: URL,
        from offset: UInt64,
        to size: UInt64,
        identity: String,
        into cache: inout TranscriptCache
    ) throws -> Bool {
        guard size >= offset else { throw BackendError("Claude transcript changed while it was being read.") }
        let descriptor = try openTranscript(url, identity: identity)
        defer { Darwin.close(descriptor) }
        var position = offset
        var visibleChange = false
        while position < size {
            let count = Int(min(UInt64(transcriptReadChunkBytes), size - position))
            let data = try readTranscriptBytes(descriptor, offset: position, count: count)
            visibleChange = appendTranscriptData(data, to: &cache) || visibleChange
            position += UInt64(count)
        }
        return visibleChange
    }

    private func transcriptCheckpoint(_ url: URL, through size: UInt64, identity: String) throws -> String {
        let descriptor = try openTranscript(url, identity: identity)
        defer { Darwin.close(descriptor) }
        let sampleSize = min(4_096, Int(min(size, UInt64(Int.max))))
        var sample = try readTranscriptBytes(descriptor, offset: 0, count: sampleSize)
        if size > UInt64(sampleSize) {
            sample.append(try readTranscriptBytes(
                descriptor,
                offset: size - UInt64(sampleSize),
                count: sampleSize
            ))
        }
        return "\(size):\(stableDigest(sample))"
    }

    private func openTranscript(_ url: URL, identity: String) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BackendError("Claude transcript could not be opened safely.") }
        var info = stat()
        var pathInfo = vnode_fdinfowithpath()
        let pathBytes = proc_pidfdinfo(
            getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &pathInfo,
            Int32(MemoryLayout.size(ofValue: pathInfo))
        )
        let descriptorPath = withUnsafePointer(to: &pathInfo.pvip.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        let openedPath = pathBytes > 0 ? canonicalPath(descriptorPath) : ""
        let projectsRoot = canonicalPath(
            URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").path
        )
        let testOverride = transcriptOverrides.values.contains {
            canonicalPath($0.path) == openedPath
        }
        let valid = Darwin.fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))" == identity
            && (openedPath.hasPrefix(projectsRoot + "/") || testOverride)
        guard valid else {
            Darwin.close(descriptor)
            throw BackendError("Claude transcript changed before it could be read safely.")
        }
        return descriptor
    }

    private func readTranscriptBytes(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else {
            throw BackendError("Claude transcript is too large to read safely.")
        }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes {
            Darwin.pread(descriptor, $0.baseAddress, count, off_t(offset))
        }
        guard readCount == count else {
            throw BackendError("Claude transcript changed while it was being read. Retrying on the next refresh.")
        }
        return Data(bytes)
    }

    @discardableResult
    private func appendTranscriptData(_ appended: Data, to cache: inout TranscriptCache) -> Bool {
        var incoming = appended
        if cache.droppingOversizedLine {
            guard let newline = incoming.firstIndex(of: 0x0A) else { return false }
            incoming = Data(incoming[incoming.index(after: newline)...])
            cache.droppingOversizedLine = false
        }
        var data = cache.pending
        data.append(incoming)
        guard let newline = data.lastIndex(of: 0x0A) else {
            if data.count > maxTranscriptRecordBytes {
                cache.pending.removeAll(keepingCapacity: false)
                cache.droppingOversizedLine = true
            } else {
                cache.pending = data
            }
            return false
        }
        let end = data.index(after: newline)
        let complete = data[..<end]
        cache.pending = Data(data[end...])
        if cache.pending.count > maxTranscriptRecordBytes {
            cache.pending.removeAll(keepingCapacity: false)
            cache.droppingOversizedLine = true
        }
        var changed = false
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= maxTranscriptRecordBytes else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  record["isMeta"] as? Bool != true,
                  let type = record["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = record["message"] as? [String: Any],
                  let content = message["content"] else { continue }
            if let uuid = record["uuid"] as? String, !uuid.isEmpty {
                guard cache.seenUUIDs.insert(uuid).inserted else { continue }
            }
            if type == "user" {
                if let text = content as? String, let visible = visibleUserText(text) {
                    changed = clearThinking(in: &cache) || changed
                    cache.chunks.append("❯ \(visible)")
                    changed = true
                } else if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let raw = block["text"] as? String, let visible = visibleUserText(raw) {
                                changed = clearThinking(in: &cache) || changed
                                cache.chunks.append("❯ \(visible)")
                                changed = true
                            }
                        case "tool_result":
                            guard let id = block["tool_use_id"] as? String,
                                  let tool = cache.openTools.removeValue(forKey: id),
                                  cache.chunks.indices.contains(tool.index) else { continue }
                            changed = clearThinking(in: &cache) || changed
                            let result = block["is_error"] as? Bool == true ? "Error" : "Done"
                            let rendered = "● \(tool.name)\n  ⎿ \(result)"
                            if cache.chunks[tool.index] != rendered {
                                cache.chunks[tool.index] = rendered
                                changed = true
                            }
                        default:
                            continue
                        }
                    }
                }
            } else if let text = content as? String, let visible = visibleAssistantText(text) {
                changed = clearThinking(in: &cache) || changed
                cache.chunks.append(visible)
                changed = true
            } else if let blocks = content as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        guard let raw = block["text"] as? String,
                              let visible = visibleAssistantText(raw) else { continue }
                        changed = clearThinking(in: &cache) || changed
                        cache.chunks.append(visible)
                        changed = true
                    case "thinking":
                        if cache.thinkingIndex == nil {
                            cache.thinkingIndex = cache.chunks.count
                            cache.chunks.append("✳ Thinking…")
                            changed = true
                        }
                    case "tool_use":
                        changed = clearThinking(in: &cache) || changed
                        let rawName = (block["name"] as? String) ?? "Tool"
                        let name = String(stripTerminalCodes(rawName)
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
                        let safeName = name.isEmpty ? "Tool" : name
                        let index = cache.chunks.count
                        cache.chunks.append("● \(safeName)")
                        if let id = block["id"] as? String, !id.isEmpty {
                            cache.openTools[id] = OpenTool(index: index, name: safeName)
                        }
                        changed = true
                    default:
                        continue
                    }
                }
            }
        }
        return changed
    }

    private func clearThinking(in cache: inout TranscriptCache) -> Bool {
        guard let index = cache.thinkingIndex else { return false }
        cache.thinkingIndex = nil
        guard cache.chunks.indices.contains(index), !cache.chunks[index].isEmpty else { return false }
        cache.chunks[index] = ""
        return true
    }

    private func visibleUserText(_ raw: String) -> String? {
        let text = stripTerminalCodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let command = tagValue("command-name", in: text) {
            let arguments = tagValue("command-args", in: text) ?? ""
            return arguments.isEmpty ? command : "\(command) \(arguments)"
        }
        let hidden = [
            "<local-command-caveat>", "<local-command-stdout>", "<local-command-stderr>",
            "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<bash-exit-code>",
            "<task-notification>", "<command-message>", "<system-reminder>",
        ]
        return hidden.contains(where: text.contains) ? nil : text
    }

    private func visibleAssistantText(_ raw: String) -> String? {
        let text = stripTerminalCodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func tagValue(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>")?.upperBound,
              let close = text.range(of: "</\(tag)>", range: open..<text.endIndex)?.lowerBound else { return nil }
        let value = text[open..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func fallbackHistory(_ pane: String, revision clientRevision: String?) throws -> [String: Any] {
        let result = run(tmux, ["capture-pane", "-ep", "-S", "-", "-t", pane])
        guard result.status == 0 else { throw BackendError(result.output) }
        let text = stripTerminalCodes(result.output).trimmingCharacters(in: .newlines)
        let bytes = Data(text.utf8)
        let digest = stableDigest(bytes)
        let revision = "tmux:\(bytes.count):\(digest)"
        if clientRevision == revision {
            return ["revision": revision, "unchanged": true]
        }
        let entries = text.isEmpty ? [] : [
            HistoryEntry(id: "terminal-\(digest)", role: "terminal", text: text, timestamp: "")
        ]
        return [
            "history": entries.map(\.json),
            "revision": revision,
            "unchanged": false,
        ]
    }

    private func stableDigest(_ data: Data) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func requireWritableMode() throws {
        guard demoRows == nil else { throw BackendError("Demo mode is read-only.") }
    }

    func create(cwd: String) throws -> (id: String, pane: String) {
        try requireWritableMode()
        let normalized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackendError("Folder no longer exists: \(normalized)")
        }
        let result = run("/bin/bash", [try bridgeScript("newsess"), normalized])
        let session = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !session.isEmpty, !session.contains("\n") else { throw BackendError(result.output) }
        for _ in 0..<40 {
            _ = try sessions()
            if let target = sessionTargets[session] { return (session, target.pane) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw BackendError("The new agent session did not become ready.")
    }

    func delete(_ session: String, pane: String, generation: String) throws {
        try requireWritableMode()
        _ = try requireCurrentTarget(session, pane: pane, generation: generation)
        let result = run(tmux, ["kill-session", "-t", "=\(session)"])
        guard result.status == 0 else { throw BackendError(result.output.isEmpty ? "Session already ended." : result.output) }
        sessionTargets.removeValue(forKey: session)
    }

    func send(_ session: String, pane: String, generation: String, message: String) throws {
        try requireWritableMode()
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendError("Write a message first.") }
        let data = Data(message.utf8)
        guard data.count <= 32 * 1024 else { throw BackendError("Message is larger than 32 KB.") }
        let target = try requireCurrentTarget(session, pane: pane, generation: generation)
        try pasteAndSubmit(target.pane, data: data)
    }

    func validateDemoIsolation() throws {
        prepareDemo()
        let mutations: [() throws -> Void] = [
            { _ = try self.create(cwd: self.defaultCwd) },
            { try self.delete("demo-1", pane: "%101", generation: "demo-1") },
            { try self.send("demo-1", pane: "%101", generation: "demo-1", message: "must not escape demo mode") },
        ]
        for mutation in mutations {
            do {
                try mutation()
                throw BackendError("Demo mode allowed a real session mutation.")
            } catch let error as BackendError {
                guard error.message == "Demo mode is read-only." else { throw error }
            }
        }
    }

    func validateSendTransport() throws {
        let session = "ccw-smoke-\(getpid())"
        let started = run(tmux, ["new-session", "-d", "-s", session, "-x", "100", "-y", "20", "/bin/cat"])
        guard started.status == 0 else { throw BackendError(started.output) }
        defer { _ = run(tmux, ["kill-session", "-t", "=\(session)"]) }

        let targetResult = run(tmux, ["display-message", "-p", "-t", "=\(session):", "#{pane_id}"])
        let target = targetResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetResult.status == 0, target.hasPrefix("%") else { throw BackendError(targetResult.output) }
        let split = run(tmux, ["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", target, "/bin/cat"])
        let decoy = split.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard split.status == 0, decoy.hasPrefix("%") else { throw BackendError(split.output) }
        let selected = run(tmux, ["select-pane", "-t", decoy])
        guard selected.status == 0 else { throw BackendError(selected.output) }

        let marker = "cc-workspace-send-\(UUID().uuidString)"
        try pasteAndSubmit(target, data: Data(marker.utf8))
        for _ in 0..<20 {
            let captured = run(tmux, ["capture-pane", "-p", "-t", target])
            let untouched = run(tmux, ["capture-pane", "-p", "-t", decoy])
            if captured.status == 0, captured.output.contains(marker), !untouched.output.contains(marker) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw BackendError("tmux message transport did not stay on its exact target pane.")
    }

    func validateHistoryFallback() throws {
        try prepareUITestSession()
        defer { cleanupUITestSession() }
        guard let row = try sessions().first else { throw BackendError("History fallback fixture did not start.") }
        var payload: [String: Any] = [:]
        var transcript = ""
        for _ in 0..<40 {
            payload = try history(row.id, pane: row.pane, generation: row.generation, revision: nil)
            transcript = ((payload["history"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            if transcript.contains("ccw-history-first"), transcript.contains("ccw-history-last") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard transcript.contains("ccw-history-first"), transcript.contains("ccw-history-last"),
              let revision = payload["revision"] as? String else {
            throw BackendError("Full-history fallback did not capture beyond the latest 200 lines.")
        }
        var rejectedStaleGeneration = false
        do {
            _ = try history(row.id, pane: row.pane, generation: "stale-generation", revision: nil)
        } catch {
            rejectedStaleGeneration = true
        }
        guard rejectedStaleGeneration else {
            throw BackendError("History accepted a stale session generation.")
        }
        let unchanged = try history(row.id, pane: row.pane, generation: row.generation, revision: revision)
        guard unchanged["unchanged"] as? Bool == true, unchanged["history"] == nil else {
            throw BackendError("History revision did not return an unchanged response.")
        }
    }

    private func pasteAndSubmit(_ pane: String, data: Data) throws {
        let buffer = "cc-workspace-\(UUID().uuidString)"
        let loaded = run(tmux, ["load-buffer", "-b", buffer, "-"], input: data)
        guard loaded.status == 0 else { throw BackendError(loaded.output) }
        defer { _ = run(tmux, ["delete-buffer", "-b", buffer]) }

        let submitted = run(tmux, [
            "paste-buffer", "-p", "-d", "-b", buffer, "-t", pane,
            ";", "send-keys", "-t", pane, "Enter",
        ])
        guard submitted.status == 0 else { throw BackendError(submitted.output) }
    }

    func validateBridge() throws {
        _ = try bridgeScript("sesslist")
        _ = try bridgeScript("newsess")
        guard FileManager.default.isExecutableFile(atPath: tmux) else { throw BackendError("tmux executable not found.") }
        let version = run(tmux, ["-V"])
        guard version.status == 0 else { throw BackendError(version.output.isEmpty ? "tmux could not start." : version.output) }
    }

    private func bridgeScript(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "Bridge") else {
            throw BackendError("Missing bundled bridge: \(name).sh")
        }
        return url.path
    }

    private func requireCachedTarget(_ session: String, pane: String, generation: String) throws -> SessionTarget {
        guard let target = sessionTargets[session], target.pane == pane, target.generation == generation else {
            throw BackendError("This agent session changed. Refresh before continuing.")
        }
        return target
    }

    private func requireLiveCachedTarget(_ session: String, pane: String, generation: String) throws -> SessionTarget {
        let target = try requireCachedTarget(session, pane: pane, generation: generation)
        if let pid = target.claudePID, Darwin.kill(pid, 0) != 0, errno != EPERM {
            throw BackendError("This agent is no longer running. Refresh before continuing.")
        }
        return target
    }

    private func requireCurrentTarget(_ session: String, pane: String, generation: String) throws -> SessionTarget {
        let expected = try requireCachedTarget(session, pane: pane, generation: generation)
        _ = try sessions()
        guard let current = sessionTargets[session], current.pane == expected.pane, current.generation == expected.generation else {
            throw BackendError("This agent is no longer running. Your message was not sent.")
        }
        return current
    }

    private func parseDisplay(_ value: String) -> (activity: String, title: String) {
        let pattern = "^[●○]\\s+(\\d{2}-\\d{2}\\s+\\d{2}:\\d{2})\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let activityRange = Range(match.range(at: 1), in: value),
              let titleRange = Range(match.range(at: 2), in: value) else {
            return ("Recently", value)
        }
        return (String(value[activityRange]), String(value[titleRange]).trimmingCharacters(in: .whitespaces))
    }
}

private struct BackendError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorDescription: String? { message.isEmpty ? "The operation failed." : message }
}

private func stripTerminalCodes(_ input: String) -> String {
    let scalars = Array(input.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        let value = scalars[index].value
        if value == 0x1B {
            guard index + 1 < scalars.count else { break }
            let kind = scalars[index + 1].value
            if kind == 0x5B { // CSI
                index += 2
                while index < scalars.count {
                    let current = scalars[index].value
                    index += 1
                    if current >= 0x40 && current <= 0x7E { break }
                }
                continue
            }
            if kind == 0x5D { // OSC, terminated by BEL or ST
                index += 2
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }
            index += 2
            continue
        }
        if value == 0x0D {
            index += 1
            continue
        }
        if value == 0x09 || value == 0x0A || value >= 0x20 {
            output.append(scalars[index])
        }
        index += 1
    }
    return String(output)
}

private final class WorkspaceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let backend: TmuxBackend
    private let queue = DispatchQueue(label: "agent-workspace.backend", qos: .userInitiated)
    private let taskLock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    init(backend: TmuxBackend) {
        self.backend = backend
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        track(urlSchemeTask)
        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, status: 400, mime: "application/json", data: json(["error": "Bad request"]))
            return
        }
        guard url.scheme?.lowercased() == "agentworkspace", url.host == "app" else {
            finish(urlSchemeTask, status: 403, mime: "application/json", data: json(["error": "Forbidden origin"]))
            return
        }
        let method = (urlSchemeTask.request.httpMethod ?? "GET").uppercased()
        let requestBody = urlSchemeTask.request.httpBody ?? Data()
        if url.path == "/index.html" || url.path == "/" {
            guard method == "GET" else {
                finish(urlSchemeTask, status: 405, mime: "application/json", data: json(["error": "Method not allowed"]))
                return
            }
            guard let resource = Bundle.main.url(forResource: "index", withExtension: "html"),
                  let data = try? Data(contentsOf: resource) else {
                finish(urlSchemeTask, status: 500, mime: "text/plain", data: Data("Missing index.html".utf8))
                return
            }
            finish(urlSchemeTask, status: 200, mime: "text/html", data: data)
            return
        }

        queue.async { [backend] in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = (components?.queryItems ?? []).reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value ?? ""
            }
            do {
                let payload: [String: Any]
                switch url.path {
                case "/api/sessions" where method == "GET":
                    payload = ["cwd": backend.presentedCwd, "sessions": try backend.sessions().map(\.json)]
                case "/api/history" where method == "GET":
                    payload = try backend.history(
                        query["id"] ?? "",
                        pane: query["pane"] ?? "",
                        generation: query["generation"] ?? "",
                        revision: query["revision"].flatMap { $0.isEmpty ? nil : $0 }
                    )
                case "/api/create" where method == "POST":
                    let created = try backend.create(cwd: query["cwd"] ?? backend.defaultCwd)
                    payload = ["ok": true, "id": created.id, "pane": created.pane]
                case "/api/delete" where method == "POST":
                    try backend.delete(
                        query["id"] ?? "",
                        pane: query["pane"] ?? "",
                        generation: query["generation"] ?? ""
                    )
                    payload = ["ok": true]
                case "/api/send" where method == "POST":
                    let id = query["id"] ?? ""
                    guard let message = String(data: requestBody, encoding: .utf8) else { throw BackendError("Message is not valid UTF-8.") }
                    try backend.send(
                        id,
                        pane: query["pane"] ?? "",
                        generation: query["generation"] ?? "",
                        message: message
                    )
                    payload = ["ok": true]
                default:
                    throw BackendError("Unknown endpoint or method")
                }
                self.finish(urlSchemeTask, status: 200, mime: "application/json", data: self.json(payload))
            } catch {
                self.finish(urlSchemeTask, status: 400, mime: "application/json", data: self.json(["error": error.localizedDescription]))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        taskLock.lock()
        activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
        taskLock.unlock()
    }

    private func track(_ task: WKURLSchemeTask) {
        taskLock.lock()
        activeTasks.insert(ObjectIdentifier(task as AnyObject))
        taskLock.unlock()
    }

    private func claim(_ task: WKURLSchemeTask) -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return activeTasks.remove(ObjectIdentifier(task as AnyObject)) != nil
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"error\":\"Encoding failed\"}".utf8)
    }

    private func finish(_ task: WKURLSchemeTask, status: Int, mime: String, data: Data) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "\(mime); charset=utf-8", "Cache-Control": "no-store"]
              ) else { return }
        DispatchQueue.main.async {
            guard self.claim(task) else { return }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }
}

private func makeAppIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let tile = NSRect(x: 48, y: 48, width: 928, height: 928)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 216, yRadius: 216)
    NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1).setFill()
    shape.fill()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let context = NSGraphicsContext.current!.cgContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    func drawOrb(_ center: CGPoint, radius: CGFloat, color: NSColor) {
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }
    drawOrb(CGPoint(x: 260, y: 720), radius: 610, color: NSColor(srgbRed: 167 / 255, green: 229 / 255, blue: 211 / 255, alpha: 0.72))
    drawOrb(CGPoint(x: 820, y: 730), radius: 570, color: NSColor(srgbRed: 244 / 255, green: 197 / 255, blue: 168 / 255, alpha: 0.64))
    drawOrb(CGPoint(x: 690, y: 210), radius: 620, color: NSColor(srgbRed: 200 / 255, green: 184 / 255, blue: 224 / 255, alpha: 0.62))
    NSGraphicsContext.restoreGraphicsState()

    NSColor(srgbRed: 214 / 255, green: 211 / 255, blue: 209 / 255, alpha: 1).setStroke()
    shape.lineWidth = 12
    shape.stroke()
    NSColor(srgbRed: 12 / 255, green: 10 / 255, blue: 9 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 392, y: 310, width: 80, height: 404), xRadius: 40, yRadius: 40).fill()
    NSBezierPath(roundedRect: NSRect(x: 552, y: 310, width: 80, height: 404), xRadius: 40, yRadius: 40).fill()
    image.unlockFocus()
    return image
}

private final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let backend: TmuxBackend
    private let snapshotPath: String?
    private let runUITest: Bool
    private let demoMode: Bool
    private var window: NSWindow?
    private var webView: WKWebView?
    private var schemeHandler: WorkspaceSchemeHandler?

    init(defaultCwd: String, snapshotPath: String?, runUITest: Bool, demoMode: Bool) {
        backend = TmuxBackend(defaultCwd: defaultCwd)
        self.snapshotPath = snapshotPath
        self.runUITest = runUITest
        self.demoMode = demoMode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runUITest {
            do { try backend.prepareUITestSession() }
            catch {
                fputs("FAIL: could not prepare UI transport test: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        } else if demoMode {
            backend.prepareDemo()
        }
        let backgroundRun = runUITest || snapshotPath != nil
        NSApp.setActivationPolicy(backgroundRun ? .accessory : .regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.applicationIconImage = makeAppIcon()
        NSApp.mainMenu = makeMainMenu()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = WorkspaceSchemeHandler(backend: backend)
        configuration.setURLSchemeHandler(handler, forURLScheme: "agentworkspace")
        schemeHandler = handler

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        webView.frame = content.bounds
        content.addSubview(webView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Workspace"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = content
        let dragRegion = WindowDragView(frame: NSRect(
            x: 72,
            y: max(0, content.bounds.height - 44),
            width: max(0, content.bounds.width - 132),
            height: 44
        ))
        dragRegion.identifier = NSUserInterfaceItemIdentifier("agent-workspace.window-drag")
        dragRegion.autoresizingMask = [.width, .minYMargin]
        content.addSubview(dragRegion, positioned: .above, relativeTo: webView)
        if runUITest || snapshotPath != nil {
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
        } else {
            if !window.setFrameUsingName("AgentWorkspaceMainWindow") { window.center() }
            window.setFrameAutosaveName("AgentWorkspaceMainWindow")
        }
        if backgroundRun {
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
        self.webView = webView

        webView.load(URLRequest(url: URL(string: "agentworkspace://app/index.html")!))
        if !backgroundRun { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { backend.cleanupUITestSession() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if runUITest {
            waitForUITest(webView, attempt: 0)
            return
        }
        guard snapshotPath != nil else { return }
        waitForSnapshot(webView, attempt: 0)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if scheme == "agentworkspace", url.host == "app" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    private func waitForUITest(_ webView: WKWebView, attempt: Int) {
        webView.evaluateJavaScript("document.documentElement.dataset.ready === 'true'") { [weak self, weak webView] value, _ in
            guard let self, let webView else { return }
            if value as? Bool == true {
                let script = """
                (async () => {
                  const nativeDragRegion = nativeWindowDrag === true;
                  const item = current();
                  const sidebar = document.querySelector('.sidebar');
                  const conversation = document.querySelector('[data-conversation]');
                  const historyViewport = document.querySelector('[data-history-scroll]');
                  const historyDocument = document.querySelector('[data-history]');
                  const windowToolbar = document.querySelector('.window-toolbar');
                  const sidebarBrandRow = document.querySelector('.sidebar-brand-row');
                  const conversationHeadRect = document.querySelector('.conversation-head').getBoundingClientRect();
                  const selectedRow = document.querySelector('.session-item.selected');
                  const sidebarRect = sidebar.getBoundingClientRect();
                  const conversationRect = conversation.getBoundingClientRect();
                  const historyViewportRect = historyViewport.getBoundingClientRect();
                  const historyRect = historyDocument.getBoundingClientRect();
                  const rowRects = [...document.querySelectorAll('.session-select')].map(row => row.getBoundingClientRect());
                  const selectedRect = selectedRow.getBoundingClientRect();
                  const selectedIconRect = selectedRow.querySelector('[data-provider-icon]')?.getBoundingClientRect();
                  const selectedTitleRect = selectedRow.querySelector('.session-title')?.getBoundingClientRect();
                  const selectedStatusRect = selectedRow.querySelector('.session-status')?.getBoundingClientRect();
                  const selectedMenuRect = selectedRow.querySelector('[data-session-menu-trigger]')?.getBoundingClientRect();
                  const headerIconRect = document.querySelector('.conversation-head > [data-provider-icon]')?.getBoundingClientRect();
                  const headerTitleRect = document.querySelector('.conversation-title')?.getBoundingClientRect();
                  const headerStateRect = document.querySelector('.conversation-state')?.getBoundingClientRect();
                  const newIconRect = document.querySelector('[data-new] svg')?.getBoundingClientRect();
                  const projectIconRect = document.querySelector('.group-label svg')?.getBoundingClientRect();
                  const projectTitleRect = document.querySelector('.group-label span')?.getBoundingClientRect();
                  const terminalRect = document.querySelector('[data-terminal-output]')?.getBoundingClientRect();
                  const composerDockRect = document.querySelector('.composer')?.getBoundingClientRect();
                  const centerY = rect => rect.top + rect.height / 2;
                  const workbenchLayout = Math.abs(sidebarRect.width - 312) <= 1
                    && sidebarRect.top === 0
                    && Math.abs(sidebarRect.height - innerHeight) <= 1
                    && Math.abs(sidebarRect.right - conversationRect.left) <= 2
                    && conversationRect.width > sidebarRect.width * 2
                    && Math.abs(historyViewportRect.width - conversationRect.width) <= 2
                    && Math.abs(historyRect.width - historyViewport.clientWidth) <= 2
                    && rowRects.length === state.sessions.length
                    && rowRects.every(rect => rect.height <= 30)
                    && Math.abs(windowToolbar.getBoundingClientRect().height - 44) <= 1
                    && Math.abs(sidebarBrandRow.getBoundingClientRect().height - 44) <= 1
                    && Math.abs(conversationHeadRect.top - 44) <= 1
                    && document.querySelector('.titlebar') === null
                    && document.documentElement.scrollWidth === innerWidth;
                  const iconTitleGap = selectedTitleRect.left - selectedIconRect.right;
                  const rowAlignment = selectedRect.width > 230
                    && Math.abs(selectedRect.height - 30) <= 1
                    && Math.abs(centerY(selectedIconRect) - centerY(selectedTitleRect)) <= 1
                    && Math.abs(centerY(selectedMenuRect) - centerY(selectedTitleRect)) <= 1
                    && Math.abs(selectedIconRect.left - selectedRect.left - 8) <= 1
                    && iconTitleGap >= 4 && iconTitleGap <= 10
                    && Math.abs(selectedRect.right - selectedMenuRect.right) <= 1
                    && getComputedStyle(selectedRow).boxShadow === 'none'
                    && selectedRow.querySelector('.session-time') === null
                    && document.querySelector('.sidebar-section-head .session-count')?.textContent === String(grouped().length);
                  const headerAlignment = Math.abs(centerY(headerIconRect) - centerY(headerTitleRect)) <= 1
                    && Math.abs(centerY(headerStateRect) - centerY(headerTitleRect)) <= 1;
                  const shellGeometry = Math.abs(newIconRect.left - projectIconRect.left) <= 1
                    && Math.abs(projectIconRect.left - selectedIconRect.left) <= 1
                    && Math.abs(projectTitleRect.left - selectedTitleRect.left) <= 1
                    && Math.abs(projectIconRect.left - sidebarRect.left - 24) <= 1
                    && Math.abs(projectTitleRect.left - sidebarRect.left - 48) <= 1
                    && Math.abs(headerIconRect.left - conversationRect.left - 20) <= 1
                    && Math.abs(parseFloat(getComputedStyle(document.querySelector('[data-terminal-output]')).paddingLeft) - 20) <= 1
                    && Math.abs(terminalRect.left - conversationRect.left) <= 1
                    && Math.abs(composerDockRect.left - conversationRect.left - 20) <= 1;
                  const solarizedVisual = getComputedStyle(document.documentElement).colorScheme === 'light'
                    && getComputedStyle(document.body).backgroundColor === 'rgb(248, 243, 226)'
                    && getComputedStyle(sidebar).backgroundColor === 'rgb(248, 243, 226)'
                    && getComputedStyle(conversation).backgroundColor === 'rgb(253, 246, 227)'
                    && getComputedStyle(selectedRow).backgroundColor === 'rgb(238, 232, 213)'
                    && getComputedStyle(document.querySelector('[data-send]')).backgroundColor === 'rgb(38, 139, 210)'
                    && document.querySelector('.brand')?.textContent === 'Agent Workspace';
                  const newSessionButton = document.querySelector('[data-new]');
                  const newSessionDiscoverable = newSessionButton?.querySelector('span:not(.kbd)')?.textContent === 'New session'
                    && newSessionButton?.title === 'New session (⌘N)'
                    && newSessionButton?.getAttribute('aria-keyshortcuts') === 'Meta+N'
                    && newSessionButton?.getBoundingClientRect().width >= 90;
                  const searchCollapsed = document.querySelector('[data-search]') === null;
                  const blockedMutation = await fetch(`/api/create?cwd=${encodeURIComponent(state.cwd)}`);
                  const bridgeSecurity = blockedMutation.status >= 400
                    && targetQuery(item).includes('generation=');
                  const staleGenerationKey = 'stale:session:generation';
                  state.histories[staleGenerationKey] = {entries: []};
                  state.drafts[staleGenerationKey] = 'must be pruned';
                  await loadSessions();
                  const generationIsolation = state.histories[staleGenerationKey] === undefined
                    && state.drafts[staleGenerationKey] === undefined;
                  const claude = document.querySelector('.sidebar [data-provider-icon="claude"]');
                  const claudeSVG = claude?.querySelector('svg');
                  const claudePath = claudeSVG?.querySelector('path')?.getAttribute('d') || '';
                  const codexProbe = document.createElement('div');
                  codexProbe.innerHTML = providerIcon('codex');
                  const providerIdentity = claudeSVG?.getAttribute('viewBox') === '0 0 16 16'
                    && claudePath.startsWith('m3.127 10.604')
                    && getComputedStyle(claude).color === 'rgb(203, 75, 22)'
                    && document.querySelectorAll('.sidebar [data-provider-icon="claude"]').length === state.sessions.length
                    && codexProbe.querySelector('[data-provider-icon="codex"]') !== null;

                  const initialHistory = await api(`/api/history?${targetQuery(item)}`);
                  const initialText = (initialHistory.history || []).map(entry => entry.text || '').join('\\n');
                  const lateLayoutProbe = document.createElement('div');
                  lateLayoutProbe.style.height = '900px';
                  lateLayoutProbe.setAttribute('aria-hidden', 'true');
                  document.querySelector('[data-history]').append(lateLayoutProbe);
                  await new Promise(resolve => setTimeout(resolve, 750));
                  const lateLayoutViewport = document.querySelector('[data-history-scroll]');
                  const historyLateLayoutFollow = lateLayoutViewport.scrollHeight - lateLayoutViewport.clientHeight - lateLayoutViewport.scrollTop <= 2;
                  lateLayoutViewport.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
                  lateLayoutViewport.dispatchEvent(new MouseEvent('click', {bubbles: true}));
                  const historyClickPreservesFollow = historyFor(item).followOutput && historyFor(item).atBottom;
                  const historyContract = Array.isArray(initialHistory.history)
                    && initialHistory.unchanged === false
                    && typeof initialHistory.revision === 'string'
                    && initialText.includes('ccw-history-first')
                    && initialText.includes('ccw-history-last')
                    && historyLateLayoutFollow;
                  const terminalOutput = document.querySelector('[data-terminal-output]');
                  const directCLI = terminalOutput?.textContent.includes('ccw-history-first') === true
                    && terminalOutput?.textContent.includes('ccw-history-last') === true
                    && document.querySelectorAll('.message').length === 0
                    && document.querySelector('[data-history-count]')?.textContent === 'Live CLI';
                  lateLayoutProbe.remove();
                  jumpToLatest();

                  const historyBeforeError = JSON.stringify(historyFor(item).entries);
                  historyFor(item).revision = 'transient-history-probe';
                  handleHistoryError(item, identity(item), new Error('transient history probe'));
                  const historyErrorPreservesContent = JSON.stringify(historyFor(item).entries) === historyBeforeError
                    && historyFor(item).revision === '';
                  clearTimeout(toastTimer); state.toast = ''; render();
                  await loadHistory(item);

                  const menuTriggerCount = document.querySelectorAll('[data-session-menu-trigger]').length;
                  document.querySelector('[data-session-menu-trigger]').click();
                  const menu = document.querySelector('[data-session-menu]');
                  const deleteItem = menu?.querySelector(`[data-menu-delete="${CSS.escape(item.id)}"]`);
                  const explicitMenuTarget = menu?.getAttribute('role') === 'menu'
                    && deleteItem !== null
                    && menuTriggerCount === state.sessions.length;
                  deleteItem?.click();
                  const correctDeleteTarget = state.confirm === item.id
                    && document.querySelector('[role="alertdialog"]') !== null;
                  const deleteScopeWarning = document.querySelector('[role="alertdialog"]')?.innerText.includes('entire tmux session') === true
                    && document.querySelector('[role="alertdialog"]')?.innerText.includes('Project files are not deleted') === true;
                  const perSessionMenu = explicitMenuTarget && correctDeleteTarget && deleteScopeWarning;
                  document.querySelector('[data-cancel]')?.click();

                  const pageSource = [...document.scripts].map(node => node.textContent).join('');
                  const noGhostty = !document.body.innerText.includes('Ghostty')
                    && !document.querySelector('[data-open]')
                    && !pageSource.includes('/api/open')
                    && !pageSource.includes('function openSession(');
                  const historyTimerIsolation = Object.hasOwn(historyFor(item), 'settleTimer')
                    && !pageSource.includes('let historySettleTimer')
                    && !pageSource.includes('let historyUserScrollTimer');

                  let prompt = document.querySelector('[data-prompt]');
                  prompt.value = 'draft message';
                  prompt.dispatchEvent(new InputEvent('input', {bubbles: true, data: 'draft message', inputType: 'insertText'}));
                  const shiftEnter = new KeyboardEvent('keydown', {key: 'Enter', shiftKey: true, bubbles: true, cancelable: true});
                  prompt.dispatchEvent(shiftEnter);
                  const composerBounds = document.querySelector('[data-composer]').getBoundingClientRect();
                  const composerIconRect = document.querySelector('[data-composer] > [data-provider-icon]')?.getBoundingClientRect();
                  const promptRect = prompt.getBoundingClientRect();
                  const sendRect = document.querySelector('[data-send]')?.getBoundingClientRect();
                  const composerAlignment = Math.abs(centerY(composerIconRect) - centerY(promptRect)) <= 1
                    && Math.abs(centerY(sendRect) - centerY(promptRect)) <= 1;
                  const composerTopLineRemoved = getComputedStyle(document.querySelector('[data-composer]')?.parentElement).borderTopWidth === '0px';
                  const composerReady = prompt.getAttribute('aria-label') === 'Message Claude'
                    && document.querySelector('[data-send]')?.textContent.trim() === 'Send'
                    && state.drafts[identity(current())] === 'draft message'
                    && targetQuery(current()).includes('pane=%25')
                    && composerBounds.width > 0
                    && composerBounds.bottom <= window.innerHeight
                    && !shiftEnter.defaultPrevented;

                  prompt.focus();
                  const metaK = new KeyboardEvent('keydown', {key: 'k', metaKey: true, bubbles: true, cancelable: true});
                  prompt.dispatchEvent(metaK);
                  let search = document.querySelector('.sidebar [data-search]');
                  const searchShortcut = metaK.defaultPrevented && document.activeElement === search;
                  const ctrlK = new KeyboardEvent('keydown', {key: 'k', ctrlKey: true, bubbles: true, cancelable: true});
                  search.dispatchEvent(ctrlK);
                  const controlShortcutPreserved = !ctrlK.defaultPrevented;
                  search.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true, data: '测'}));
                  search.value = '测试';
                  search.dispatchEvent(new InputEvent('input', {bubbles: true, data: '试', inputType: 'insertCompositionText', isComposing: true}));
                  const imePreserved = search.isConnected && document.activeElement === search;
                  search.dispatchEvent(new CompositionEvent('compositionend', {bubbles: true, data: '测试'}));
                  state.query = ''; render();

                  let viewport = document.querySelector('[data-history-scroll]');
                  viewport.dispatchEvent(new WheelEvent('wheel', {deltaY: -120, bubbles: true}));
                  viewport.scrollTop = 0;
                  viewport.dispatchEvent(new Event('scroll', {bubbles: true}));
                  const readingBeforeUpdate = !historyFor(item).atBottom && viewport.scrollTop === 0;
                  const backgroundMarker = `background-output-${Date.now()}`;
                  await api(`/api/send?${targetQuery(item)}`, {method: 'POST', body: backgroundMarker});
                  let backgroundVisible = false;
                  for (let attempt = 0; attempt < 40 && !backgroundVisible; attempt += 1) {
                    await new Promise(resolve => setTimeout(resolve, 50));
                    await loadHistory(item);
                    await new Promise(resolve => requestAnimationFrame(resolve));
                    backgroundVisible = document.querySelector('[data-history]')?.innerText.includes(backgroundMarker) === true;
                  }
                  viewport = document.querySelector('[data-history-scroll]');
                  const latest = document.querySelector('[data-jump-latest]');
                  const stayedReading = viewport.scrollTop < 10 && latest && !latest.hidden;
                  latest?.click();
                  await new Promise(resolve => requestAnimationFrame(resolve));
                  viewport = document.querySelector('[data-history-scroll]');
                  const jumpedToLatest = viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop <= 2;
                  const historyScrollSafety = readingBeforeUpdate && backgroundVisible && stayedReading && jumpedToLatest;

                  const marker = `webview-post-${Date.now()}`;
                  const livePrompt = document.querySelector('[data-prompt]');
                  livePrompt.value = marker;
                  livePrompt.dispatchEvent(new InputEvent('input', {bubbles: true, data: marker, inputType: 'insertText'}));
                  document.querySelector('[data-composer]').requestSubmit();
                  let sentText = '';
                  for (let attempt = 0; attempt < 40 && !sentText.includes(marker); attempt += 1) {
                    await new Promise(resolve => setTimeout(resolve, 50));
                    const sentHistory = await api(`/api/history?${targetQuery(item)}`);
                    sentText = (sentHistory.history || []).map(entry => entry.text || '').join('\\n');
                  }
                  const composerSendTransport = sentText.includes(marker)
                    && document.querySelector('[data-prompt]')?.value === ''
                    && state.drafts[identity(item)] === undefined;
                  return {nativeDragRegion, workbenchLayout, rowAlignment, headerAlignment, shellGeometry, solarizedVisual, newSessionDiscoverable, searchCollapsed, bridgeSecurity, generationIsolation, providerIdentity, perSessionMenu, noGhostty, historyContract, directCLI, historyLateLayoutFollow, historyClickPreservesFollow, historyErrorPreservesContent, historyTimerIsolation, historyScrollSafety, composerAlignment, composerTopLineRemoved, composerReady, searchShortcut, imePreserved, controlShortcutPreserved, composerSendTransport};
                })()
                """
                let nativeWindowDrag = webView.superview?.subviews.first(where: { $0.identifier?.rawValue == "agent-workspace.window-drag" }).map { dragRegion in
                    abs(dragRegion.frame.height - 44) < 0.5
                        && dragRegion.frame.minX >= 72
                        && abs(dragRegion.frame.maxY - (dragRegion.superview?.bounds.maxY ?? 0)) < 0.5
                        && (dragRegion.superview?.bounds.maxX ?? 0) - dragRegion.frame.maxX >= 60
                } ?? false
                webView.callAsyncJavaScript("return await \(script)", arguments: ["nativeWindowDrag": nativeWindowDrag], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value):
                        let checks = value as? [String: Any]
                        let required = [
                            "nativeDragRegion", "workbenchLayout", "rowAlignment", "headerAlignment", "shellGeometry", "solarizedVisual", "newSessionDiscoverable", "searchCollapsed", "bridgeSecurity", "generationIsolation", "providerIdentity", "perSessionMenu",
                            "noGhostty", "historyContract", "directCLI", "historyLateLayoutFollow", "historyClickPreservesFollow", "historyErrorPreservesContent", "historyTimerIsolation", "historyScrollSafety", "composerAlignment", "composerTopLineRemoved", "composerReady",
                            "searchShortcut", "imePreserved", "controlShortcutPreserved", "composerSendTransport",
                        ]
                        let passed = checks != nil && required.allSatisfy { checks?[$0] as? Bool == true }
                        if passed {
                            print("PASS: Agent Workspace Solarized CLI, native window drag, session controls, scroll safety, keyboard/IME, and WebView POST send transport")
                            NSApp.terminate(nil)
                            return
                        }
                        self.backend.cleanupUITestSession()
                        fputs("FAIL: UI interaction checks failed: \(String(describing: value))\n", stderr)
                        Darwin.exit(1)
                    case .failure(let error):
                        self.backend.cleanupUITestSession()
                        fputs("FAIL: UI interaction checks failed: \(error.localizedDescription)\n", stderr)
                        Darwin.exit(1)
                    }
                }
                return
            }
            guard attempt < 30 else {
                self.backend.cleanupUITestSession()
                fputs("FAIL: UI did not become ready\n", stderr)
                Darwin.exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitForUITest(webView, attempt: attempt + 1)
            }
        }
    }

    private func waitForSnapshot(_ webView: WKWebView, attempt: Int) {
        webView.evaluateJavaScript("JSON.stringify({ready: document.documentElement.dataset.ready === 'true', href: location.href})") { [weak self, weak webView] value, _ in
            guard let self, let webView else { return }
            let snapshotState = (value as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if snapshotState?["ready"] as? Bool == true {
                print("UI_STATE: \(value as? String ?? "unknown")")
                // Let spring transitions settle so visual-regression snapshots are stable.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    webView.takeSnapshot(with: nil) { image, error in
                        guard let path = self.snapshotPath,
                              error == nil,
                              let tiff = image?.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let png = bitmap.representation(using: .png, properties: [:]) else {
                            print("FAIL: could not capture app window")
                            NSApp.terminate(nil)
                            return
                        }
                        do {
                            try png.write(to: URL(fileURLWithPath: path))
                            print("PASS: wrote UI snapshot to \(path)")
                        } catch {
                            print("FAIL: \(error.localizedDescription)")
                        }
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            guard attempt < 30 else {
                print("FAIL: UI did not become ready")
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitForSnapshot(webView, attempt: attempt + 1)
            }
        }
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Agent Workspace")
        appMenu.addItem(withTitle: "About Agent Workspace", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agent Workspace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Agent Workspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        return menu
    }
}

@main
private enum AgentWorkspaceMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let iconIndex = arguments.firstIndex(of: "--write-icon"), iconIndex + 1 < arguments.count {
            let path = arguments[iconIndex + 1]
            guard let tiff = makeAppIcon().tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fputs("FAIL: could not render app icon\n", stderr)
                Darwin.exit(1)
            }
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
            return
        }
        let snapshotIndex = arguments.firstIndex(of: "--snapshot")
        let snapshotPath = snapshotIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let cwd = arguments.first(where: { !$0.hasPrefix("--") && $0 != snapshotPath }) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let backend = TmuxBackend(defaultCwd: cwd)
        if CommandLine.arguments.contains("--smoke") {
            guard Bundle.main.url(forResource: "index", withExtension: "html") != nil else {
                fputs("FAIL: missing index.html\n", stderr)
                Darwin.exit(1)
            }
            do {
                try backend.validateBridge()
                try backend.validateSendTransport()
                try backend.validateTranscriptResolver()
                try backend.validateTranscriptTail()
                try backend.validateHistoryFallback()
                try backend.validateLifecycleIsolation()
                let demoBackend = TmuxBackend(defaultCwd: cwd)
                try demoBackend.validateDemoIsolation()
                print("PASS: Agent Workspace transcript tail over static tmux, pane fallback, exact send transport, lifecycle isolation, and read-only demo mode")
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate(
            defaultCwd: cwd,
            snapshotPath: snapshotPath,
            runUITest: arguments.contains("--ui-test"),
            demoMode: arguments.contains("--demo")
        )
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

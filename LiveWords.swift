// Live Words — shows what you're saying, word by word, while your dictation app
// (OpenWhispr, Wispr Flow, superwhisper) records.
//
// How it works:
//   1. Every 50ms we ask CoreAudio "is the dictation app capturing the mic?"
//      (read-only — we never touch the dictation app).
//   2. When it starts, we open the mic too (plain shared capture, no voice
//      processing) and stream it into Apple's on-device DictationTranscriber —
//      the same engine behind macOS dictation.
//   3. Words show up in a floating bar at the bottom of the screen. When
//      the dictation app stops, the bar lingers a moment and fades. The
//      dictation app still does the real transcription + paste.

import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import Speech
import SQLite3

// MARK: - Log

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("LiveWords.log")
    }()
    static let queue = DispatchQueue(label: "log")
    static func info(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

// MARK: - Settings

enum Settings {
    static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var localeID: String {
        get { d.string(forKey: "locale") ?? "en_US" }
        set { d.set(newValue, forKey: "locale") }
    }
    static var didSetupLogin: Bool {
        get { d.bool(forKey: "didSetupLogin") }
        set { d.set(newValue, forKey: "didSetupLogin") }
    }
}

// MARK: - Custom words (shared with OpenWhispr's Dictionary tab, read-only)

enum Vocabulary {
    static let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/open-whispr/transcriptions.db").path

    /// Words from OpenWhispr's Dictionary, minus plain everyday English words
    /// (those don't need hinting and just dilute the real names).
    static func load() -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT word FROM custom_dictionary ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var words: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { words.append(String(cString: c)) }
        }
        let checker = NSSpellChecker.shared
        return words.filter { w in
            let t = w.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            if t.contains(where: { $0.isUppercase || $0.isNumber }) || t.contains(" ") { return true }
            let miss = checker.checkSpelling(of: t, startingAt: 0, language: "en", wrap: false,
                                             inSpellDocumentWithTag: 0, wordCount: nil)
            return miss.location != NSNotFound  // not an everyday English word → keep
        }
    }
}

// MARK: - Dictation-app mic watcher (read-only CoreAudio polling)

final class MicWatcher {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var active = false
    private var lastOn = Date.distantPast
    private var cache: [AudioObjectID: (pid: pid_t, isOW: Bool)] = [:]
    /// Dictation apps we follow. Override with:
    ///   defaults write com.jpbarrios.livewords watchApps -array com.example.app
    static let defaultApps = ["com.gizmolabs.openwhispr", "com.electron.wispr-flow", "com.superduper.superwhisper"]
    private let watched: [String] = (UserDefaults.standard.stringArray(forKey: "watchApps") ?? MicWatcher.defaultApps)
        .map { $0.lowercased() }

    func start() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let on = openWhisprCapturing()
        let now = Date()
        if on { lastOn = now }
        if on && !active {
            active = true; onChange?(true)
        } else if !on && active && now.timeIntervalSince(lastOn) > 0.15 {
            active = false; onChange?(false)
        }
    }

    private func openWhisprCapturing() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return false }

        var found = false
        var seen = Set<AudioObjectID>()
        for id in ids {
            seen.insert(id)
            let pid = u32(id, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? -1
            let isOW: Bool
            if let c = cache[id], c.pid == pid {
                isOW = c.isOW
            } else {
                let bid = bundleID(id).lowercased()
                isOW = watched.contains { bid.hasPrefix($0) }
                cache[id] = (pid, isOW)
            }
            if isOW, u32(id, kAudioProcessPropertyIsRunningInput) == 1 { found = true }
        }
        cache = cache.filter { seen.contains($0.key) }
        return found
    }

    private func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func bundleID(_ obj: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &s) == noErr, let v = s else { return "" }
        return v.takeRetainedValue() as String
    }
}

// MARK: - One live transcription session

final class LiveSession {
    let id: Int
    var onText: ((_ final: String, _ volatile: String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var cont: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var stopped = false
    private let started = Date()
    private var firstResultLogged = false

    init(id: Int) { self.id = id }

    func start(locale: Locale, demoFile: URL? = nil) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "LiveWords", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio format"])
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.cont = cont

        // Mic first, so no words are lost while the analyzer spins up.
        if let demoFile { startDemo(file: demoFile, target: target) } else { try startMic(target: target) }
        if stopped { cont.finish(); return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let words = await MainActor.run { Vocabulary.load() }
        if !words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: words]
            do { try await analyzer.setContext(ctx) } catch { Log.info("vocab context error: \(error)") }
            Log.info("session \(id): \(words.count) custom words: \(words.joined(separator: ", "))")
        }
        resultsTask = Task { [weak self] in
            var finalized = ""
            do {
                for try await r in transcriber.results {
                    let t = String(r.text.characters)
                    var volatile = ""
                    if r.isFinal {
                        finalized = LiveSession.join(finalized, t)
                    } else {
                        volatile = t
                    }
                    guard let self else { return }
                    if !self.firstResultLogged {
                        self.firstResultLogged = true
                        Log.info("session \(self.id): first words after \(String(format: "%.2f", Date().timeIntervalSince(self.started)))s")
                    }
                    let f = finalized, v = volatile
                    await MainActor.run { self.onText?(f, v) }
                }
            } catch {
                Log.info("session results error: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func startMic(target: AVAudioFormat) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "LiveWords", code: 2, userInfo: [NSLocalizedDescriptionKey: "no mic input"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "LiveWords", code: 3, userInfo: [NSLocalizedDescriptionKey: "no converter"])
        }
        let cont = self.cont
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if out.frameLength > 0 { cont?.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()

        // Device switched mid-session (AirPods connecting, etc.) — re-arm on the new device.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopped else { return }
            Log.info("session \(self.id): audio device changed, re-arming mic")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.startMic(target: target)
        }
        Log.info("session \(id): mic open (\(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch)")
    }

    /// Test mode: feed a recording at real-time speed instead of the mic.
    private func startDemo(file url: URL, target: AVAudioFormat) {
        let cont = self.cont
        Thread.detachNewThread {
            guard let file = try? AVAudioFile(forReading: url),
                  let conv = AVAudioConverter(from: file.processingFormat, to: target) else { return }
            let chunk: AVAudioFrameCount = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length {
                guard let inb = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: inb, frameCount: chunk)) != nil, inb.frameLength > 0,
                      let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk + 64) else { break }
                var fed = false
                conv.convert(to: out, error: nil) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return inb
                }
                cont?.yield(AnalyzerInput(buffer: out))
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cont?.finish()
        if let analyzer {
            // Give the engine a moment to settle the last words, but never hang.
            await withTaskGroup(of: Void.self) { g in
                g.addTask { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
                g.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                await g.next(); g.cancelAll()
            }
        }
        resultsTask?.cancel()
        Log.info("session \(id): stopped after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b.trimmingCharacters(in: .whitespaces) }
        if b.isEmpty { return a }
        if a.hasSuffix(" ") || b.hasPrefix(" ") { return a + b }
        return a + " " + b
    }
}

// MARK: - Floating bar

final class Overlay {
    private let panel: NSPanel
    private let blur = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()
    private var hideWork: DispatchWorkItem?

    private let maxTextWidth: CGFloat = 620
    private let minWidth: CGFloat = 200
    private let padX: CGFloat = 18, padY: CGFloat = 12, dotSpace: CGFloat = 20
    private let font = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let maxLines = 3

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .vibrantDark)

        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        label.font = font
        label.textColor = .white
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.maximumNumberOfLines = 0
        blur.addSubview(label)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        blur.addSubview(dot)
    }

    private var screen: NSScreen?

    /// The screen you're working on. Apps like Claude or Chrome often have
    /// windows on several screens, so "the app's top window" is unreliable.
    /// Rule: the mouse's screen if the frontmost app has a window there
    /// (you clicked into the text box there); else that app's top window's
    /// screen; else the mouse's screen.
    static func activeScreen() -> NSScreen {
        let screens = NSScreen.screens
        let primaryH = screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        let mouseScreen = screens.first { NSMouseInRect(mouse, $0.frame, false) }

        var appWindows: [NSRect] = []  // front-to-back, AppKit coords
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                      wd > 100, ht > 100 else { continue }
                appWindows.append(NSRect(x: x, y: primaryH - y - ht, width: wd, height: ht))
            }
        }
        if let ms = mouseScreen, appWindows.contains(where: { $0.intersects(ms.frame) }) { return ms }
        if let r = appWindows.first,
           let best = screens.max(by: { a, b in
               let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
               return ia.width * ia.height < ib.width * ib.height
           }), best.frame.intersects(r) { return best }
        return mouseScreen ?? NSScreen.main ?? screens[0]
    }

    func begin() {
        screen = Overlay.activeScreen()
        Log.info("bar on screen: \(screen?.localizedName ?? "?") (front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        hideWork?.cancel()
        setDot(listening: true)
        render(final: "", volatile: "")
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(final: String, volatile: String) {
        render(final: final, volatile: volatile)
    }

    func end() {
        setDot(listening: false)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// Test helper: render the bar to a PNG (solid background stands in for the blur).
    func snapshot(final: String, volatile: String, to url: URL) {
        render(final: final, volatile: volatile)
        setDot(listening: true)
        let view = panel.contentView!
        view.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func setDot(listening: Bool) {
        guard let layer = dot.layer else { return }
        layer.removeAllAnimations()
        if listening {
            layer.backgroundColor = NSColor.systemRed.cgColor
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.35; a.duration = 0.7
            a.autoreverses = true; a.repeatCount = .infinity
            layer.add(a, forKey: "pulse")
        } else {
            layer.backgroundColor = NSColor.systemGreen.cgColor
        }
    }

    private func attributed(_ final: String, _ volatile: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if final.isEmpty && volatile.isEmpty {
            s.append(NSAttributedString(string: "Listening…", attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
            return s
        }
        s.append(NSAttributedString(string: final, attributes: [.font: font, .foregroundColor: NSColor.white]))
        if !volatile.isEmpty {
            let v = final.isEmpty ? volatile : " " + volatile.trimmingCharacters(in: .whitespaces)
            s.append(NSAttributedString(string: v, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.72)]))
        }
        return s
    }

    private func textSize(_ s: NSAttributedString) -> NSSize {
        // Measure with the label's own cell so wrapping matches what's drawn.
        label.attributedStringValue = s
        let sz = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxTextWidth, height: 10_000))
        return NSSize(width: ceil(min(sz.width, maxTextWidth)), height: ceil(sz.height))
    }

    private func render(final: String, volatile: String) {
        var f = final, v = volatile
        var text = attributed(f, v)
        var size = textSize(text)
        let oneLine = textSize(NSAttributedString(string: "Ag", attributes: [.font: font])).height
        let maxH = oneLine * CGFloat(maxLines) + 4
        // Only ever show the most recent few lines — drop words off the front.
        while size.height > maxH {
            if let sp = f.firstIndex(of: " ") {
                f = String(f[f.index(after: sp)...])
            } else if !f.isEmpty {
                f = ""
            } else if let sp = v.firstIndex(of: " ") {
                v = String(v[v.index(after: sp)...])
            } else { break }
            text = f.isEmpty ? attributed("", "…" + v) : attributed("…" + f, v)
            size = textSize(text)
        }
        label.attributedStringValue = text

        let w = max(minWidth, size.width + padX * 2 + dotSpace)
        let h = max(44, size.height + padY * 2)
        let screen = self.screen ?? Overlay.activeScreen()
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.midX - w / 2, y: vf.minY + 70, width: w, height: h)
        panel.setFrame(frame, display: true)
        dot.frame = NSRect(x: padX, y: h - padY - oneLine / 2 - 4, width: 8, height: 8)
        label.frame = NSRect(x: padX + dotSpace, y: padY, width: size.width, height: size.height)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = MicWatcher()
    private let overlay = Overlay()
    private var statusItem: NSStatusItem!
    private var statusLine = NSMenuItem(title: "Watching your dictation app", action: nil, keyEquivalent: "")
    private var session: LiveSession?
    private var sessionCounter = 0
    private var micAllowed = false

    static let languages: [(String, String)] = [("en_US", "English"), ("es_ES", "Español (España)"),
                                                ("es_MX", "Español (México)"), ("es_US", "Español (EE. UU.)")]

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.info("Live Words starting")
        // Test mode: LiveWords --snapshot out.png "final" "volatile"  → renders the bar to a PNG.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 3 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            overlay.snapshot(final: a[i + 2], volatile: a[i + 3], to: URL(fileURLWithPath: a[i + 1]))
            exit(0)
        }
        // Test mode: LiveWords --demo file.wav  → plays the file through the bar, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            runDemo(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }

        setupMenu()
        setupLoginItemOnce()

        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                self.micAllowed = ok
                Log.info("mic permission: \(ok)")
                self.refreshStatus()
            }
        }
        Task { await ensureAssets(for: Settings.localeID) }

        watcher.onChange = { [weak self] on in
            guard let self else { return }
            on ? self.beginSession() : self.endSession()
        }
        watcher.start()
    }

    // MARK: sessions

    private func beginSession() {
        Log.info("dictation app started recording")
        guard Settings.enabled, micAllowed else { return }
        sessionCounter += 1
        let s = LiveSession(id: sessionCounter)
        session = s
        overlay.begin()
        s.onText = { [weak self, weak s] f, v in
            guard let self, let s, self.session === s else { return }
            self.overlay.update(final: f, volatile: v)
        }
        let locale = Locale(identifier: Settings.localeID)
        Task {
            do { try await s.start(locale: locale) }
            catch {
                Log.info("session \(s.id) failed to start: \(error.localizedDescription)")
                await MainActor.run {
                    if self.session === s { self.overlay.end() }
                }
            }
        }
    }

    private func runDemo(_ url: URL) {
        let s = LiveSession(id: 0)
        session = s
        overlay.begin()
        s.onText = { [weak self] f, v in
            self?.overlay.update(final: f, volatile: v)
            print("TEXT:", f, "|", v); fflush(stdout)
        }
        let dur = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 5
        Task {
            try? await s.start(locale: Locale(identifier: Settings.localeID), demoFile: url)
            try? await Task.sleep(nanoseconds: UInt64((dur + 0.5) * 1e9))
            await MainActor.run { self.overlay.end() }
            await s.stop()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    private func endSession() {
        Log.info("dictation app stopped recording")
        guard let s = session else { return }
        overlay.end()
        Task {
            await s.stop()
            await MainActor.run { if self.session === s { self.session = nil } }
        }
    }

    // MARK: speech model assets

    private func ensureAssets(for id: String) async {
        let tr = DictationTranscriber(locale: Locale(identifier: id), preset: .progressiveLongDictation)
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
                await MainActor.run { self.statusLine.title = "Downloading speech model…" }
                Log.info("downloading speech model for \(id)")
                try await req.downloadAndInstall()
                Log.info("speech model ready for \(id)")
            }
        } catch {
            Log.info("speech model error for \(id): \(error.localizedDescription)")
        }
        await MainActor.run { self.refreshStatus() }
    }

    // MARK: menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Live Words")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let m = NSMenu()
        let title = NSMenuItem(title: "Live Words", action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        statusLine.isEnabled = false
        m.addItem(statusLine)
        m.addItem(.separator())

        let en = NSMenuItem(title: "Show live words", action: #selector(toggleEnabled), keyEquivalent: "")
        en.target = self; en.state = Settings.enabled ? .on : .off
        m.addItem(en)

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (id, name) in Self.languages {
            let it = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = id
            it.state = Settings.localeID == id ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        m.addItem(langItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Live Words", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        statusItem.menu = m
        refreshStatus()
    }

    private func refreshStatus() {
        if !micAllowed {
            statusLine.title = "⚠️ Needs microphone access"
        } else if !Settings.enabled {
            statusLine.title = "Paused"
        } else {
            let name = Self.languages.first { $0.0 == Settings.localeID }?.1 ?? Settings.localeID
            statusLine.title = "Watching your dictation app · \(name)"
        }
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        if !Settings.enabled { endSession() }
        rebuildMenu()
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.localeID = id
        rebuildMenu()
        Task { await ensureAssets(for: id) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item toggle failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    private func setupLoginItemOnce() {
        guard !Settings.didSetupLogin else { return }
        Settings.didSetupLogin = true
        do { try SMAppService.mainApp.register(); Log.info("registered as login item") }
        catch { Log.info("login item register failed: \(error.localizedDescription)") }
    }
}

@main
enum Main {
    static func main() {
        // Used by uninstall.sh: remove our login item and exit.
        if CommandLine.arguments.contains("--unregister-login") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

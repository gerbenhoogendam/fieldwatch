import AVFoundation
import FieldwatchCore
import Foundation
import UserNotifications

/// Kotlin `MutableSharedFlow` without replay: `observe` gets every later `tryEmit`, on the emitter's thread.
public final class EventFlow<T>: @unchecked Sendable {
    private let inner = MutableStateFlow<T?>(nil)
    public init() {}

    @discardableResult
    public func tryEmit(_ value: T) -> Bool {
        inner.value = value
        return true
    }

    /// Keep the token; dropping it unsubscribes.
    @discardableResult
    public func observe(_ f: @escaping (T) -> Void) -> FlowToken {
        inner.observe { v in if let v { f(v) } }
    }
}

/// Port of alert/Alerter.kt.
///
/// - Watchlist chirp: synthesized ~1 kHz double pip (85 ms, 55 ms gap, 85 ms) through AVAudioEngine.
/// - Voice: AVSpeechSynthesizer, same phrases as Kotlin (`spokenWatchPhrase` / `testWatchPhrase`), ~220 ms after the pip.
/// - "Shade" card: a silent UserNotifications banner. Authorization is requested the first time it is needed.
/// - Hunt geiger tick: 22 ms 1680 Hz click.
/// - Vibrate: no-op on the Mac.
/// - `flashes` emits the device key of every new watch hit (row flash / jump / radar ping).
public final class Alerter: NSObject, UNUserNotificationCenterDelegate, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let announcedLock = NSLock()
    private var announced = Set<String>()

    /// Main thread only from here down.
    private let main = DispatchQueue.main
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pipBuffer: AVAudioPCMBuffer?
    private var huntBuffer: AVAudioPCMBuffer?
    private var engineIdleWork: DispatchWorkItem?
    private var beepGeneration = 0
    private var tts: AVSpeechSynthesizer?
    private var speaking = false
    private var utteranceStarted = false
    private var ttsSpeakTries = 0
    private var pendingSpeak: String?
    private var speakAfterBeep: String?
    private var speakWatchdog: DispatchWorkItem?
    private var startWait: DispatchWorkItem?

    private let notifyLock = NSLock()
    private var notifyAsked = false
    private var notifyAllowed = false

    public let flashes = EventFlow<String>()

    /// A watchlist banner was clicked (Android `EXTRA_DEVICE_KEY` → `vm.select`). Called on the main thread.
    public var onNotificationOpen: ((String) -> Void)?

    public override init() {
        super.init()
        ensureChannel()
    }

    public func checkLive(
        devices: [Sighting],
        fleets: [Fleet],
        watchlist: [WatchTarget],
        alertsOn: Bool,
        beepOn: Bool,
        voiceOn: Bool = false,
        voiceWhat: AlertVoiceWhat = .class,
        shadeOn: Bool = false,
        visibleOnLive: (Sighting) -> Bool = { !$0.gone },
        arrivalsOnly: Bool = false,
        demoMode: Bool = false
    ) {
        if !alertsOn || watchlist.isEmpty { return }
        if shadeOn { requestNotificationAuthorization() }
        fireNewAppearances(
            devices: devices, fleets: fleets, watchlist: watchlist, beepOn: beepOn, voiceOn: voiceOn,
            voiceWhat: voiceWhat, shadeOn: shadeOn, visibleOnLive: visibleOnLive, arrivalsOnly: arrivalsOnly,
            demoMode: demoMode
        )
    }

    public func playTestBeep(beepOn: Bool = true, speakClass: Bool = false, voiceWhat: AlertVoiceWhat = .class) {
        if speakClass { prepareVoice() }
        if beepOn {
            beep(holdFocus: !speakClass)
            vibrate()
        }
        if speakClass { queueVoice(text: testWatchPhrase(what: voiceWhat), afterBeep: beepOn) }
    }

    /// Warm the speech engine (and the tone engine) so the first alert is not late.
    public func prepareVoice() {
        onMain {
            self.ensureTts()
            self.ensureEngine()
        }
    }

    /// GNSS interference banner. A Mac has no GNSS receiver, so the scan service never calls this; kept for parity.
    public func gnssAlert(title: String, text: String, phrase: String?, beep: Bool, shade: Bool) {
        if shade {
            post(id: Alerter.GNSS_NOTE_ID, title: title, subtitle: nil, body: text, deviceKey: nil)
        } else {
            clearGnssNote()
        }
        if beep { self.beep(holdFocus: phrase.isNullOrBlank) }
        if let p = phrase, p.isNotBlank {
            prepareVoice()
            queueVoice(text: p, afterBeep: beep)
        }
    }

    public func clearGnssNote() {
        guard Alerter.notificationsUsable else { return }
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [Alerter.GNSS_NOTE_ID])
        c.removePendingNotificationRequests(withIdentifiers: [Alerter.GNSS_NOTE_ID])
    }

    /// Short Hunt geiger tick. Not the watchlist double-pip. Vibrate is a no-op on the Mac.
    public func huntTick(beepOn: Bool, vibrateOn: Bool) {
        if beepOn { onMain { self.playHuntClick() } }
    }

    public func forgetAnnounced() {
        announcedLock.lock(); announced.removeAll(); announcedLock.unlock()
    }

    /// Ask for banner permission now (Settings → System notification switched on). Safe to call often.
    public func requestNotificationAuthorization() {
        guard Alerter.notificationsUsable else { return }
        notifyLock.lock()
        if notifyAsked { notifyLock.unlock(); return }
        notifyAsked = true
        notifyLock.unlock()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            self.notifyLock.lock(); self.notifyAllowed = granted; self.notifyLock.unlock()
        }
    }

    // MARK: Watchlist

    private func fireNewAppearances(
        devices: [Sighting],
        fleets: [Fleet],
        watchlist: [WatchTarget],
        beepOn: Bool,
        voiceOn: Bool,
        voiceWhat: AlertVoiceWhat,
        shadeOn: Bool,
        visibleOnLive: (Sighting) -> Bool,
        arrivalsOnly: Bool,
        demoMode: Bool
    ) {
        let now = nowMs()
        let onAir = devices.filter { !$0.gone }
        let liveKeys = Set(onAir.map { $0.key })
        let fleetNames = fleets.associateBy { $0.id }
        let mineKeys = RadioBookmarks.mineKeys(watchlist: watchlist)
        var beepFired = false
        var voicePhrase: String?
        var flashed: [String] = []
        var notes: [(String, Sighting)] = []
        if voiceOn { prepareVoice() }

        announcedLock.lock()
        announced = announced.filter { liveKeys.contains($0.substringAfter("\t")) }
        for target in watchlist {
            for device in onAir {
                if !shouldRaiseWatch(target: target, device: device, mineKeys: mineKeys) { continue }
                if !visibleOnLive(device) { continue }
                let token = "\(target.id)\t\(device.key)"
                if announced.contains(token) { continue }
                if !arrivalsOnly && !isNewAppearance(device: device, now: now) { continue }
                announced.insert(token)
                let base = target.label.isBlank
                    ? (target.fleetId.flatMap { fleetNames[$0]?.name } ?? device.displayName)
                    : target.label
                let label = MacUtil.redactMacIn(text: base, mac: device.mac, demo: demoMode)
                if shadeOn && target.notify { notes.append((label, device)) }
                if target.vibrate { vibrate() }
                if beepOn && !beepFired {
                    beep(holdFocus: !voiceOn)
                    beepFired = true
                }
                if beepOn || voiceOn { flashed.append(device.key) }
                if voiceOn && voicePhrase == nil {
                    voicePhrase = spokenWatchPhrase(device: device, fleets: fleets, what: voiceWhat, target: target)
                }
            }
        }
        announcedLock.unlock()

        for (label, device) in notes { notify(label: label, device: device, demoMode: demoMode) }
        for key in flashed { flashes.tryEmit(key) }
        if let voicePhrase { queueVoice(text: voicePhrase, afterBeep: beepFired) }
    }

    private func queueVoice(text: String, afterBeep: Bool) {
        let phrase = text.trim()
        if phrase.isEmpty { return }
        onMain {
            if afterBeep {
                self.speakAfterBeep = phrase
            } else {
                self.speakClassName(text: phrase)
            }
        }
    }

    private func isNewAppearance(device: Sighting, now: Int) -> Bool {
        if now - device.firstSeen <= Alerter.NEW_WINDOW_MS { return true }
        let spanStart = device.presence.last?.start ?? device.firstSeen
        return now - spanStart <= Alerter.NEW_WINDOW_MS
    }

    // MARK: Banner ("shade card")

    private func notify(label: String, device: Sighting, demoMode: Bool) {
        let mac = MacUtil.screenMac(mac: device.mac, demo: demoMode)
        let name = MacUtil.redactMacIn(text: device.displayName, mac: device.mac, demo: demoMode)
        post(
            id: "watch-\(device.key)",
            title: "Fieldwatch watchlist",
            subtitle: "\(label)  \(device.rssi) dBm  \(mac)",
            body: "\(label) appeared\n\(device.kind.rawValue)  \(mac)\n\(device.rssi) dBm  \(name)",
            deviceKey: device.key
        )
    }

    private func post(id: String, title: String, subtitle: String?, body: String, deviceKey: String?) {
        guard Alerter.notificationsUsable else { return }
        requestNotificationAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = nil
        content.threadIdentifier = id == Alerter.GNSS_NOTE_ID ? Alerter.GNSS_CHANNEL : Alerter.CHANNEL
        if let deviceKey { content.userInfo = [Alerter.EXTRA_DEVICE_KEY: deviceKey] }
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Android channel setup → set the delegate so banners show while Fieldwatch is frontmost and clicks select the row.
    private func ensureChannel() {
        guard Alerter.notificationsUsable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo[Alerter.EXTRA_DEVICE_KEY] as? String
        if let key { onMain { self.onNotificationOpen?(key) } }
        completionHandler()
    }

    /// UserNotifications aborts in a process without a bundle identifier (e.g. `swift run`).
    static var notificationsUsable: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: Tones

    private func beep(holdFocus: Bool = true) {
        // No audio focus on macOS; holdFocus is kept for the Kotlin call sites.
        onMain { self.playSynthBeep() }
    }

    private func playSynthBeep() {
        guard ensureEngine(), let player, let buf = pipBuffer else {
            finishBeep()
            return
        }
        beepGeneration += 1
        let gen = beepGeneration
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
        let playMs = Alerter.PIP_MS + Alerter.GAP_MS + Alerter.PIP_MS
        main.asyncAfter(deadline: .now() + .milliseconds(playMs + 40)) {
            if self.beepGeneration == gen { self.finishBeep() }
        }
        scheduleEngineIdle()
    }

    private func finishBeep() {
        guard let phrase = speakAfterBeep else { return }
        speakAfterBeep = nil
        main.asyncAfter(deadline: .now() + .milliseconds(Alerter.VOICE_AFTER_TRACK_MS)) {
            self.speakClassName(text: phrase)
        }
    }

    private func playHuntClick() {
        guard ensureEngine(), let player, let buf = huntBuffer else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
        scheduleEngineIdle()
    }

    /// Main thread. Builds the engine and the two PCM buffers once; restarts the engine after an idle stop.
    @discardableResult
    private func ensureEngine() -> Bool {
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Alerter.SAMPLE_RATE, channels: 1) else { return false }
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: fmt)
            engine = e
            player = p
            format = fmt
            pipBuffer = Alerter.makePips(format: fmt)
            huntBuffer = Alerter.makeTone(format: fmt, ms: Alerter.HUNT_PIP_MS, freqHz: Alerter.HUNT_FREQ_HZ)
        }
        guard let e = engine else { return false }
        if !e.isRunning {
            do { try e.start() } catch { return false }
        }
        return true
    }

    /// Let the audio device sleep a few seconds after the last sound.
    private func scheduleEngineIdle() {
        engineIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let e = self.engine, e.isRunning else { return }
            if self.player?.isPlaying == true { self.player?.stop() }
            e.pause()
        }
        engineIdleWork = work
        main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private static func makePips(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = Int(format.sampleRate)
        let pip = sr * PIP_MS / 1000
        let gap = sr * GAP_MS / 1000
        let total = pip + gap + pip
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { ch[i] = 0 }
        writeSine(dest: ch, offset: 0, n: pip, sampleRate: sr, freqHz: FREQ_HZ)
        writeSine(dest: ch, offset: pip + gap, n: pip, sampleRate: sr, freqHz: FREQ_HZ)
        return buf
    }

    private static func makeTone(format: AVAudioFormat, ms: Int, freqHz: Double) -> AVAudioPCMBuffer? {
        let sr = Int(format.sampleRate)
        let n = sr * ms / 1000
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        writeSine(dest: ch, offset: 0, n: n, sampleRate: sr, freqHz: freqHz)
        return buf
    }

    /// Kotlin `writeSine`: 4 ms attack, 8 ms release, peak 0.62 of full scale.
    private static func writeSine(dest: UnsafeMutablePointer<Float>, offset: Int, n: Int, sampleRate: Int, freqHz: Double) {
        let step = 2.0 * Double.pi * freqHz / Double(sampleRate)
        let attack = max(1, Int(Double(sampleRate) * 0.004))
        let release = max(1, Int(Double(sampleRate) * 0.008))
        let peak = 0.62
        for i in 0..<n {
            var env: Double
            if i < attack { env = Double(i) / Double(attack) }
            else if i > n - release { env = Double(n - i) / Double(release) }
            else { env = 1 }
            env = env.coerceIn(0, 1)
            dest[offset + i] = Float(sin(step * Double(i)) * peak * env)
        }
    }

    private func vibrate() {}

    // MARK: Speech

    private func speakClassName(text: String) {
        let phrase = text.trim()
        if phrase.isEmpty { return }
        pendingSpeak = phrase
        ensureTts()
        startSpeak(text: phrase)
    }

    private func ensureTts() {
        if tts != nil { return }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        tts = s
    }

    private func startSpeak(text: String) {
        guard let engine = tts else { return }
        // A phrase is already being spoken: later hits in the burst are skipped so names do not overlap.
        if speaking && utteranceStarted { return }
        pendingSpeak = text
        ttsSpeakTries += 1
        speaking = true
        utteranceStarted = false
        let u = AVSpeechUtterance(string: text)
        u.voice = Alerter.voice()
        engine.speak(u)
        startWait?.cancel()
        let wait = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.speaking && !self.utteranceStarted && self.ttsSpeakTries < 2 {
                self.speaking = false
                self.tts?.stopSpeaking(at: .immediate)
                self.startSpeak(text: text)
            } else if self.speaking && !self.utteranceStarted {
                self.speaking = false
                self.pendingSpeak = nil
                self.ttsSpeakTries = 0
            }
        }
        startWait = wait
        main.asyncAfter(deadline: .now() + .milliseconds(Alerter.TTS_START_WAIT_MS), execute: wait)
    }

    private static func voice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.identifier.replace("_", "-")
        return AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onMain {
            self.utteranceStarted = true
            self.speaking = true
            self.startWait?.cancel()
            self.speakWatchdog?.cancel()
            let dog = DispatchWorkItem {
                guard self.speaking else { return }
                let retry = self.pendingSpeak
                self.speaking = false
                self.utteranceStarted = false
                self.tts?.stopSpeaking(at: .immediate)
                if let retry, self.ttsSpeakTries < 2 { self.speakClassName(text: retry) }
            }
            self.speakWatchdog = dog
            self.main.asyncAfter(deadline: .now() + .milliseconds(Alerter.SPEAK_TIMEOUT_MS), execute: dog)
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onMain {
            self.speaking = false
            self.utteranceStarted = false
            self.pendingSpeak = nil
            self.ttsSpeakTries = 0
            self.speakWatchdog?.cancel()
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onMain {
            self.speaking = false
            self.utteranceStarted = false
            self.speakWatchdog?.cancel()
        }
    }

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { main.async(execute: f) }
    }

    // MARK: Companion

    public static let CHANNEL = "fieldwatch_watch_v3"
    public static let GNSS_CHANNEL = "fieldwatch_gnss"
    private static let GNSS_NOTE_ID = "fieldwatch-gnss-71001"
    public static let EXTRA_DEVICE_KEY = "device_key"
    private static let SAMPLE_RATE = 44_100.0
    private static let FREQ_HZ = 1050.0
    private static let PIP_MS = 85
    private static let GAP_MS = 55
    private static let NEW_WINDOW_MS = 20_000
    private static let HUNT_FREQ_HZ = 1680.0
    private static let HUNT_PIP_MS = 22
    private static let VOICE_AFTER_TRACK_MS = 220
    private static let TTS_START_WAIT_MS = 1_500
    private static let SPEAK_TIMEOUT_MS = 8_000
}

/// Mine skips beep, voice, flash, vibrate, and the banner for that device key.
/// A fleet watch still matches every other radio. Alert on the row is left as set.
func shouldRaiseWatch(target: WatchTarget, device: Sighting, mineKeys: Set<String>) -> Bool {
    if mineKeys.contains(device.key) { return false }
    if target.deviceKey != nil && !target.alert { return false }
    if let dk = target.deviceKey { return device.key == dk }
    if let fid = target.fleetId { return device.fleetIds.contains(fid) }
    return false
}

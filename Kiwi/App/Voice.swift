import AVFoundation
import Foundation
import Observation
import Speech

enum VoiceMode: String {
    case write
    case command
}

enum VoiceOutcome: Equatable {
    case ran(String)
    case refused(String)
    case notACommand
    case written
}

enum VoiceState: Equatable {
    case idle
    case starting
    case listening(heard: String, level: Float)
    case finishing(heard: String)
    case heard(said: String, outcome: VoiceOutcome)
    case failed(String)

    var isListening: Bool {
        switch self {
        case .starting, .listening: return true
        default: return false
        }
    }
}

private final class VoiceLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Float = 0
    private var peak: Float = 0

    func store(_ level: Float) {
        lock.lock()
        latest = level
        peak = max(peak, level)
        lock.unlock()
    }

    func consume() -> (latest: Float, peak: Float) {
        lock.lock()
        let sample = (latest, peak)
        peak = 0
        lock.unlock()
        return sample
    }

    func reset() {
        lock.lock()
        latest = 0
        peak = 0
        lock.unlock()
    }
}

/// Apple's speech recognizer, in process. Hold fn to write a line; cmd-fn to run a command.
@MainActor
@Observable
final class Voice {
    var state: VoiceState = .idle
    var mode: VoiceMode = .write
    var fnHeld = false
    var target: PaneID?
    @ObservationIgnored private(set) var currentLevel: Float = 0
    @ObservationIgnored private let levelMeter = VoiceLevelMeter()
    private var session: UInt64 = 0
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var heard = ""
    private var lastLoud = Date()
    private var opened = Date()
    private var quietTimer: Timer?
    private var levelTimer: Timer?
    private var shownTimer: Timer?

    private let quietEnough: TimeInterval = 1
    private let loudEnough: Float = 0.02
    private let patience: TimeInterval = 6
    private let shownFor: TimeInterval = 4

    func saying(_ pane: PaneID) -> String? {
        guard target == pane else { return nil }
        switch state {
        case .listening(let heard, _), .finishing(let heard):
            return heard.isEmpty ? nil : heard
        default:
            return nil
        }
    }

    func start(mode: VoiceMode, target: PaneID?, onFinal: @escaping (String, VoiceMode, UInt64) -> Void) {
        if state.isListening { return }
        shownTimer?.invalidate()
        self.mode = mode
        self.target = mode == .write ? target : nil
        session += 1
        let this = session
        heard = ""
        currentLevel = 0
        levelMeter.reset()
        state = .starting

        let locale = Locale(identifier: ProcessInfo.processInfo.environment["KIWI_SPEECH_LOCALE"] ?? "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            state = .failed("Speech recognition is not available for this language.")
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard this == self.session else { return }
                switch status {
                case .authorized:
                    AVCaptureDevice.requestAccess(for: .audio) { ok in
                        DispatchQueue.main.async {
                            guard this == self.session else { return }
                            if ok {
                                self.begin(recognizer: recognizer, session: this, onFinal: onFinal)
                            } else {
                                self.state = .failed("Microphone permission was refused.")
                            }
                        }
                    }
                case .denied:
                    self.state = .failed("Speech recognition permission was refused.")
                case .restricted:
                    self.state = .failed("Speech recognition is restricted on this Mac.")
                default:
                    self.state = .failed("Speech recognition is not authorized.")
                }
            }
        }
    }

    func stop() {
        guard state.isListening || finishing else { return }
        request?.endAudio()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        quietTimer?.invalidate()
        levelTimer?.invalidate()
        levelTimer = nil
        currentLevel = 0
        switch state {
        case .starting:
            state = .finishing(heard: "")
        case .listening(let heard, _):
            state = .finishing(heard: heard)
        default:
            break
        }
    }

    func cancel() {
        session += 1
        teardown()
        target = nil
        state = .idle
    }

    func settle(_ session: UInt64) {
        guard session == self.session else { return }
        if case .heard = state {
            state = .idle
        }
    }

    func markHeard(said: String, outcome: VoiceOutcome) {
        state = .heard(said: said, outcome: outcome)
        shownTimer?.invalidate()
        let this = session
        shownTimer = Timer.scheduledTimer(withTimeInterval: shownFor, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.settle(this)
            }
        }
    }

    private var finishing: Bool {
        if case .finishing = state { return true }
        return false
    }

    private func begin(recognizer: SFSpeechRecognizer, session: UInt64, onFinal: @escaping (String, VoiceMode, UInt64) -> Void) {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13, *) {
            request.addsPunctuation = false
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let levelMeter = self.levelMeter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak levelMeter] buffer, _ in
            request.append(buffer)
            levelMeter?.store(Voice.level(of: buffer))
        }

        do {
            try engine.start()
        } catch {
            state = .failed("Couldn't open the microphone: \(error.localizedDescription)")
            return
        }

        self.engine = engine
        self.request = request
        opened = Date()
        lastLoud = Date()
        state = .listening(heard: "", level: 0)

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishLevel(session: session)
            }
        }

        if mode == .command {
            quietTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.checkQuiet(session: session)
                }
            }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, session == self.session else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish(said: self.heard, session: session, onFinal: onFinal)
                    } else {
                        switch self.state {
                        case .listening:
                            self.state = .listening(heard: self.heard, level: self.currentLevel)
                        case .finishing:
                            self.state = .finishing(heard: self.heard)
                        default:
                            break
                        }
                    }
                }
                if let error, self.task != nil {
                    if self.heard.isEmpty {
                        self.state = .failed(error.localizedDescription)
                        self.teardown()
                    } else {
                        self.finish(said: self.heard, session: session, onFinal: onFinal)
                    }
                }
            }
        }
    }

    private func checkQuiet(session: UInt64) {
        guard session == self.session, mode == .command, state.isListening else { return }
        let now = Date()
        if !heard.isEmpty, now.timeIntervalSince(lastLoud) >= quietEnough {
            stop()
        } else if heard.isEmpty, now.timeIntervalSince(opened) >= patience {
            cancel()
        }
    }

    private func publishLevel(session: UInt64) {
        guard session == self.session, state.isListening else { return }
        let sample = levelMeter.consume()
        currentLevel = sample.latest
        if sample.peak >= loudEnough { lastLoud = Date() }
    }

    private func finish(said: String, session: UInt64, onFinal: @escaping (String, VoiceMode, UInt64) -> Void) {
        guard session == self.session else { return }
        let mode = self.mode
        teardown()
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .idle
            return
        }
        onFinal(trimmed, mode, session)
    }

    private func teardown() {
        quietTimer?.invalidate()
        quietTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        currentLevel = 0
        levelMeter.reset()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = data[i]
            sum += sample * sample
        }
        return min(1, sqrt(sum / Float(count)) * 8)
    }
}

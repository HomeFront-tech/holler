import Foundation
import AVFoundation
import Speech
import CoreAudio

struct HollerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SpeechSession {
    let analyzer: SpeechAnalyzer
    let transcriber: DictationTranscriber
    let format: AVAudioFormat
    var input: AsyncStream<AnalyzerInput>.Continuation?
    var results: Task<Void, Error>?
    init(_ analyzer: SpeechAnalyzer, _ transcriber: DictationTranscriber, _ format: AVAudioFormat) {
        self.analyzer = analyzer; self.transcriber = transcriber; self.format = format
    }
    static func make(words: [String]) async throws -> SpeechSession {
        var locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil { locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw HollerError(message: "Apple dictation does not support the current locale or English.") }
        let transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        // Transcription is always on-device. If Apple's dictation model isn't on this Mac yet, fetch it once
        // from Apple (the same download System Settings does); nothing you say ever leaves the Mac.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.event("installing Apple dictation assets")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw HollerError(message: "Apple dictation provided no compatible audio format.")
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        return SpeechSession(analyzer, transcriber, format)
    }
    func begin(onResult: @escaping (String, Bool) -> Void, onFailure: @escaping () -> Void = {}) async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        results = Task {
            do {
                for try await result in transcriber.results { onResult(String(result.text.characters), result.isFinal) }
            } catch {
                // If Apple's recognizer dies mid-dictation, say so now; otherwise a hands-free session would keep
                // the microphone open feeding a dead stream until you tap Fn.
                if !Task.isCancelled { onFailure() }
                throw error
            }
        }
        try await analyzer.start(inputSequence: stream)
    }
    func finish() async throws {
        input?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
    }
    func cancel() async {
        input?.finish(); await analyzer.cancelAndFinishNow(); results?.cancel()
    }
}

func audioConverter(from: AVAudioFormat, to: AVAudioFormat) -> AVAudioConverter? {
    guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
    if from.channelCount > 1 { converter.channelMap = [0] }
    return converter
}
func converted(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 64)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if given { status.pointee = .noDataNow; return nil }
        given = true; status.pointee = .haveData; return buffer
    }
    return error == nil && output.frameLength > 0 ? output : nil
}

// The engine owns tap buffers only until its callback returns, so copy before dispatching.
private func copyAudio(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
    copy.frameLength = source.frameLength
    let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for i in 0..<src.count {
        guard let from = src[i].mData, let to = dst[i].mData else { return nil }
        memcpy(to, from, Int(src[i].mDataByteSize))
    }
    return copy
}

final class Dictation {
    var onText: (String) -> Void = { _ in }
    var onError: () -> Void = {}
    var words: () -> [String] = { [] }
    private var engine: AVAudioEngine?
    private var session: SpeechSession?
    private var warm: SpeechSession?
    private var warming: Task<SpeechSession, Error>?
    private var expiry: DispatchWorkItem?
    private var generation = 0
    private var pending: [AVAudioPCMBuffer] = []
    private var converter: AVAudioConverter?
    private var transcript = Transcript()
    private var active = false
    private var finishing = false
    private var finalizing = false
    private var completion: ((String) -> Void)?

    func prepare() {
        generation += 1
        let gen = generation
        active = false; finishing = false; finalizing = false; transcript = Transcript(); pending = []; converter = nil
        expiry?.cancel()
        // Test hook, never set in normal use: `defaults write com.github.homefront-tech.holler testAudioFile /path/to.aiff` makes
        // dictations read that file instead of the microphone, so the whole Fn -> text-in-the-box path can be tested
        // with nobody talking. `defaults delete com.github.homefront-tech.holler testAudioFile` switches it off.
        if let path = UserDefaults.standard.string(forKey: "testAudioFile"),
           let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
            Log.event("test audio file used instead of the microphone")
            while file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
                guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                pending.append(buffer)
            }
        } else { do {
            // A headless Mac may have no input; touching inputNode then can raise an ObjC exception.
            guard let device: UInt32 = audioValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0)), device != 0 else {
                throw HollerError(message: "No default microphone")
            }
            let engine = AVAudioEngine()
            let node = engine.inputNode, format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw HollerError(message: "No microphone format") }
            node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let copy = copyAudio(buffer) else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, !self.finishing else { return }
                    self.accept(copy)
                }
            }
            self.engine = engine
            engine.prepare(); try engine.start()
        } catch { fail(); return } }
        let cached = warm; warm = nil
        let task = warming; warming = nil
        Task { @MainActor [self] in
            do {
                let ready: SpeechSession
                if let cached { ready = cached }
                else if let task { ready = try await task.value }
                else { ready = try await SpeechSession.make(words: words()) }
                guard generation == gen else { await ready.cancel(); return }
                let context = AnalysisContext()
                context.contextualStrings[.general] = words()
                try await ready.analyzer.setContext(context)
                guard generation == gen else { await ready.cancel(); return }
                session = ready
                try await ready.begin(onResult: { [weak self] text, final in
                    DispatchQueue.main.async {
                        guard let self, self.generation == gen else { return }
                        self.transcript.receive(text, isFinal: final)
                        if self.active { self.onText(self.transcript.text) }
                    }
                }, onFailure: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.generation == gen, !self.finishing else { return }
                        self.fail()
                    }
                })
                guard generation == gen else { await ready.cancel(); return }
                flush()
                if finishing { finishSession(ready, gen: gen) }
            } catch { if generation == gen { fail() } }
        }
    }
    private func accept(_ buffer: AVAudioPCMBuffer) {
        if active, let session, session.input != nil { feed(buffer, to: session) }
        else {
            pending.append(buffer)
            // A stalled service must not accumulate unbounded raw microphone audio.
            if pending.reduce(0.0, { $0 + Double($1.frameLength) / $1.format.sampleRate }) > 10 { fail() }
        }
    }
    private func feed(_ buffer: AVAudioPCMBuffer, to session: SpeechSession) {
        if converter == nil { converter = audioConverter(from: buffer.format, to: session.format) }
        guard let converter, let audio = converted(buffer, using: converter, to: session.format) else { return }
        session.input?.yield(AnalyzerInput(buffer: audio))
    }
    private func flush() {
        guard active, let session, session.input != nil else { return }
        for buffer in pending { feed(buffer, to: session) }
        pending.removeAll()
    }
    func start() { active = true; flush() }
    func finish(_ callback: @escaping (String) -> Void) {
        finishing = true; completion = callback; stopMic()
        let gen = generation
        if let session, session.input != nil { flush(); finishSession(session, gen: gen) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == gen, self.finishing else { return }
            Log.event("finalization timeout; using latest result")
            self.deliver(gen: gen)
        }
    }
    private func finishSession(_ session: SpeechSession, gen: Int) {
        guard !finalizing else { return }
        finalizing = true
        Task { @MainActor [self] in
            do { try await session.finish() } catch { Log.event("speech finalization failed") }
            // Result callbacks are dispatched before this main-queue barrier.
            DispatchQueue.main.async { [weak self] in self?.deliver(gen: gen) }
        }
    }
    private func deliver(gen: Int) {
        guard generation == gen, finishing else { return }
        let text = transcript.text, callback = completion
        completion = nil
        cancel()
        keepWarm()
        callback?(text)
    }
    func cancel() {
        generation += 1; stopMic(); pending.removeAll(); transcript = Transcript()
        active = false; finishing = false; finalizing = false; completion = nil; converter = nil
        if let session { Task { await session.cancel() } }
        session = nil
    }
    private func stopMic() {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
    }
    private func fail() { Log.event("microphone or speech setup failed"); cancel(); onError() }
    private func keepWarm() {
        // A finished analyzer cannot restart. Prepare its replacement, retaining it for 90 s.
        warming = Task { try await SpeechSession.make(words: words()) }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let task = self.warming; self.warming = nil; self.warm = nil
            Task { if let ready = try? await task?.value { await ready.cancel() } }
            Log.event("released warm recognizer")
        }
        expiry = item; DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: item)
    }
}

func transcribeFile(_ path: String) async throws -> String {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    // Use the user's word list when it exists, so the test exercises the same hints as live dictation.
    let list = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Holler/words.txt")
    let words = ((try? String(contentsOf: list, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let session = try await SpeechSession.make(words: words)
    let lock = NSLock()
    var transcript = Transcript()
    try await session.begin { text, final in
        lock.lock(); transcript.receive(text, isFinal: final); lock.unlock()
    }
    guard let converter = audioConverter(from: file.processingFormat, to: session.format) else {
        throw HollerError(message: "Cannot convert input audio")
    }
    // AVAudioFile.read throws eofErr instead of returning an empty buffer, so stop at the known length.
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        if let output = converted(buffer, using: converter, to: session.format) { session.input?.yield(AnalyzerInput(buffer: output)) }
    }
    try await session.finish()
    return transcript.text
}

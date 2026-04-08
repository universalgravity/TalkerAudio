//
//  ReusableAzureSynthesizer.swift
//  TalkerAudio
//
//  Long-lived Azure TTS session scoped to a single StreamSynthesizerPlayer.
//  Keeps SPXSpeechSynthesizer + SPXConnection alive across sentences,
//  eliminating per-sentence TLS handshakes.
//

import Foundation
import StreamAudio
import TalkerAudioObjC
import TalkerCommon

/// One in-flight synthesis request. Only accessed under `requestLock`.
struct ActiveSynthRequest {
    let resultId: String
    let player: StreamAudio.StreamAudioPlayer
    let channel: OneShotChannel<Void>
}

/// Player-scoped Azure TTS session.
///
/// Owns a single `SPXSpeechSynthesizer` + `SPXConnection` for the lifetime
/// of its parent `StreamSynthesizerPlayer`. Each `AzureStreamSynthesizer`
/// borrows this session to run one synthesis call.
///
/// **Concurrency contract**: only one `startSpeaking` may be active at a time.
/// `StreamSynthesizerPlayer` serialises load→play per sentence. The `synthLock`
/// acts as a safety net; reentry throws `synthesizerBusy`.
public final class ReusableAzureSynthesizer: @unchecked Sendable {
    private let sub: String
    private let region: String

    /// Serialises `startSpeaking` — reentry throws `synthesizerBusy`.
    private let synthLock = NSLock()

    private var speechSynthesizer: SPXSpeechSynthesizer?
    private var connection: SPXConnection?

    /// Current in-flight request. Only touched under `requestLock`.
    private let requestLock = NSLock()
    private var _activeRequest: ActiveSynthRequest?

    public init(sub: String, region: String) {
        self.sub = sub
        self.region = region
    }

    // MARK: - Lifecycle

    /// Lazily build the SPXSpeechSynthesizer and pre-open the connection.
    /// Safe to call multiple times; only the first does real work.
    public func ensureReady() throws {
        synthLock.lock()
        defer { synthLock.unlock() }
        guard speechSynthesizer == nil else { return }
        try buildSession()
    }

    /// Tear down the Azure session. Next `ensureReady()` or `startSpeaking()`
    /// rebuilds from scratch. Call on page teardown or provider switch.
    public func invalidate() {
        synthLock.lock()
        defer { synthLock.unlock() }
        cancelActiveRequestLocked(error: StreamSynthesizerError.synthesizeCancelled)
        connection = nil
        speechSynthesizer = nil
    }

    // MARK: - Synthesis

    /// Begin one synthesis. Audio data flows into `player` via the shared
    /// `writeHandler`. Returns a channel that fires when Azure signals
    /// completion or cancellation for this exact `resultId`.
    ///
    /// - Throws: `StreamSynthesizerError.synthesizerBusy` if another call is
    ///   already in flight.
    public func startSpeaking(ssml: String, player: StreamAudio.StreamAudioPlayer) throws -> OneShotChannel<Void> {
        synthLock.lock()
        defer { synthLock.unlock() }

        // Rebuild session if needed (first call, or after invalidate).
        if speechSynthesizer == nil {
            try buildSession()
        }

        // Guard against reentry.
        requestLock.lock()
        let busy = _activeRequest != nil
        requestLock.unlock()
        if busy {
            throw StreamSynthesizerError.synthesizerBusy
        }

        // 1) Kick off synthesis — synchronous SDK call that returns immediately
        //    with a result handle. The writeHandler callback fires on a background
        //    thread as audio data arrives.
        let result = try speechSynthesizer!.startSpeakingSsml(ssml)

        // 2) Now we have the real resultId. Install the request atomically.
        let channel = OneShotChannel<Void>()
        requestLock.lock()
        _activeRequest = ActiveSynthRequest(resultId: result.resultId, player: player, channel: channel)
        requestLock.unlock()

        // 3) If the SDK returned a synchronous cancellation, finish now.
        if result.reason == .canceled {
            finishActiveRequest(resultId: result.resultId, error: StreamSynthesizerError.synthesizeCancelled)
        }

        return channel
    }

    /// Stop the current utterance without tearing down the session.
    public func stopCurrentUtterance() {
        try? speechSynthesizer?.stopSpeaking()
    }

    // MARK: - Private: session setup

    /// Caller must hold `synthLock`.
    private func buildSession() throws {
        let config = try SPXSpeechConfiguration(subscription: sub, region: region)
        config.setSpeechSynthesisOutputFormat(.audio16Khz32KBitRateMonoMp3)

        let outputStream = SPXPushAudioOutputStream(
            writeHandler: { [weak self] data in
                guard let self else { return UInt(data.count) }
                self.requestLock.lock()
                let player = self._activeRequest?.player
                self.requestLock.unlock()
                try? player?.writeData(data)
                return UInt(data.count)
            },
            closeHandler: { /* nothing */ }
        )

        let audioConfig = try SPXAudioConfiguration(streamOutput: outputStream!)
        let synth = try SPXSpeechSynthesizer(
            speechConfiguration: config, audioConfiguration: audioConfig)

        synth.addSynthesisCompletedEventHandler { [weak self] _, arg in
            infoLog("ReusableAzureSynthesizer: synthesisCompleted resultId=\(arg.result.resultId)")
            self?.finishActiveRequest(resultId: arg.result.resultId, error: nil)
        }

        synth.addSynthesisCanceledEventHandler { [weak self] _, arg in
            infoLog("ReusableAzureSynthesizer: synthesisCanceled resultId=\(arg.result.resultId)")
            self?.finishActiveRequest(resultId: arg.result.resultId, error: StreamSynthesizerError.synthesizeCancelled)
        }

        let conn = try SPXConnection(from: synth)
        conn.open(true) // pre-connect: TCP + TLS handshake happens once here

        self.speechSynthesizer = synth
        self.connection = conn
        infoLog("ReusableAzureSynthesizer: session built, region=\(region)")
    }

    // MARK: - Private: request completion

    /// Take the active request only if `resultId` matches exactly.
    private func finishActiveRequest(resultId: String, error: Error?) {
        requestLock.lock()
        guard let req = _activeRequest, req.resultId == resultId else {
            requestLock.unlock()
            return
        }
        _activeRequest = nil
        requestLock.unlock()

        // Outside lock: finish data, then signal.
        try? req.player.finishData()
        if let error {
            req.channel.finish(throwing: error)
        } else {
            req.channel.finish(())
        }
    }

    /// Cancel whatever is active now. Caller must hold `synthLock`.
    private func cancelActiveRequestLocked(error: Error) {
        requestLock.lock()
        let req = _activeRequest
        _activeRequest = nil
        requestLock.unlock()

        if let req {
            try? req.player.finishData()
            req.channel.finish(throwing: error)
        }
    }
}

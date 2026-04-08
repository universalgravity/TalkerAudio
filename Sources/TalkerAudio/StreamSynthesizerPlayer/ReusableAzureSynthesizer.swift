//
//  ReusableAzureSynthesizer.swift
//  TalkerAudio
//
//  Long-lived Azure TTS session that keeps SPXSpeechSynthesizer + SPXConnection
//  alive across multiple synthesis requests, eliminating per-sentence TLS handshakes.
//

import Foundation
import StreamAudio
import TalkerAudioObjC
import TalkerCommon

/// Represents one in-flight synthesis request bound to a specific StreamAudioPlayer.
public struct ActiveSynthRequest: Sendable {
    let resultId: String
    let player: StreamAudio.StreamAudioPlayer
    let channel: OneShotChannel<Void>
}

/// A reusable Azure TTS session.
///
/// Holds a single `SPXSpeechSynthesizer` + `SPXConnection` for the lifetime of
/// the app (or until explicitly invalidated). Each `AzureStreamSynthesizer`
/// instance borrows this session to run one synthesis call.
///
/// **Concurrency contract**: only one `startSpeaking` may be active at a time.
/// `StreamSynthesizerPlayer` already serialises load→play per sentence, so this
/// is naturally satisfied. The `synthLock` acts as a safety net.
public final class ReusableAzureSynthesizer: @unchecked Sendable {
    private let sub: String
    private let region: String

    /// Serialises access to `startSpeaking` so two callers can never race.
    private let synthLock = NSLock()

    private var speechSynthesizer: SPXSpeechSynthesizer?
    private var connection: SPXConnection?

    /// The currently active request. Written under `requestLock`.
    private let requestLock = NSLock()
    private var _activeRequest: ActiveSynthRequest?

    public init(sub: String, region: String) {
        self.sub = sub
        self.region = region
    }

    // MARK: - Lifecycle

    /// Lazily creates the SPXSpeechSynthesizer and pre-opens the connection.
    /// Safe to call multiple times; only the first call does real work.
    public func ensureReady() throws {
        synthLock.lock()
        defer { synthLock.unlock() }
        guard speechSynthesizer == nil else { return }
        try buildSession()
    }

    /// Tear down the Azure session. Next `ensureReady()` or `startSpeaking()`
    /// will rebuild from scratch. Call on app background or provider switch.
    public func invalidate() {
        synthLock.lock()
        defer { synthLock.unlock() }

        // Cancel any in-flight request
        cancelActiveRequestLocked(error: StreamSynthesizerError.synthesizeCancelled)

        connection = nil
        speechSynthesizer = nil
    }

    // MARK: - Synthesis

    /// Begin a synthesis. Audio data flows into `player` via the shared
    /// `writeHandler`. Returns a channel that fires when Azure signals
    /// completion or cancellation for this specific `resultId`.
    ///
    /// - Precondition: no other synthesis is active (enforced by `synthLock`).
    public func startSpeaking(ssml: String, player: StreamAudio.StreamAudioPlayer) throws -> OneShotChannel<Void> {
        synthLock.lock()
        defer { synthLock.unlock() }

        // Ensure session is alive
        if speechSynthesizer == nil {
            try buildSession()
        }

        // 1) Prepare a pending request BEFORE calling startSpeakingSsml.
        //    The channel is already the one we'll return; the resultId is
        //    filled in after the SDK call returns.
        let channel = OneShotChannel<Void>()

        // Install the player so writeHandler can route audio immediately.
        requestLock.lock()
        // Placeholder with empty resultId — will be updated atomically below.
        _activeRequest = ActiveSynthRequest(resultId: "", player: player, channel: channel)
        requestLock.unlock()

        // 2) Kick off synthesis (synchronous call that returns a result handle).
        let result = try speechSynthesizer!.startSpeakingSsml(ssml)

        // 3) Atomically stamp the real resultId now that we have it.
        requestLock.lock()
        if let req = _activeRequest, req.channel === channel {
            _activeRequest = ActiveSynthRequest(resultId: result.resultId, player: player, channel: channel)
        }
        requestLock.unlock()

        // 4) If the SDK returned a synchronous cancellation, finish immediately.
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
        conn.open(true) // pre-connect: TCP + TLS handshake happens here

        self.speechSynthesizer = synth
        self.connection = conn
        infoLog("ReusableAzureSynthesizer: session built, region=\(region)")
    }

    // MARK: - Private: request completion

    /// Atomically take the active request if its `resultId` matches (or if
    /// the resultId is still the placeholder ""), finish the player, then
    /// signal the channel.
    private func finishActiveRequest(resultId: String, error: Error?) {
        requestLock.lock()
        guard let req = _activeRequest,
              req.resultId == resultId || req.resultId.isEmpty else {
            requestLock.unlock()
            return
        }
        _activeRequest = nil
        requestLock.unlock()

        // Outside lock: finish player data, then signal.
        try? req.player.finishData()
        if let error {
            req.channel.finish(throwing: error)
        } else {
            req.channel.finish(())
        }
    }

    /// Cancel whatever is active right now (used during invalidate).
    /// Caller must hold `synthLock`.
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

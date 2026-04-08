//
//  StreamSynthesizerPlayer.swift
//  iOS
//
//  Created by feichao on 2023/3/16.
//

import AsyncAlgorithms
import Foundation
import OSLog
import SwiftUI
import TalkerCommon

public enum StreamSynthesizerPlayerError: String, LocalizedError {
    case notSetup
    case noSynthesizerPlayer
    case writeToWavFile
    case unfinishedStreamBuffer

    public var errorDescription: String? {
        self.rawValue
    }
}

/// Per-round state. Each `streamSynthesize` call creates a fresh instance so
/// that concurrent-round confusion (waiting on the wrong `finished` channel,
/// leaking old players, etc.) is structurally impossible.
private final class RoundState: @unchecked Sendable {
    let finished = OneShotChannel<Void>()
    let players = Lock<[any StreamSynthesizerProtocol & Sendable]>([])
    var task: Task<Void, Error>?
}

@MainActor
public class StreamSynthesizerPlayer {
    /// Optional player-scoped Azure session. `nil` when the provider isn't Azure.
    public let azureSession: ReusableAzureSynthesizer?

    private var round: RoundState?
    private let newPlayerFunc:
        @Sendable (_ text: String, _ voiceId: String, _ style: String, _ role: String) ->
            any StreamSynthesizerProtocol & Sendable
    public private(set) var isPlaying: Bool = false

    public init(
        azureSession: ReusableAzureSynthesizer? = nil,
        newPlayer: @Sendable @escaping (
            _ text: String, _ voiceId: String, _ style: String, _ role: String
        ) -> StreamSynthesizerProtocol
    ) {
        self.azureSession = azureSession
        self.newPlayerFunc = newPlayer
    }

    // MARK: - Prewarm

    /// Pre-build the Azure TLS connection so the first sentence doesn't pay
    /// the full handshake cost. No-op when azureSession is nil.
    public func prewarmIfNeeded() {
        try? azureSession?.ensureReady()
    }

    // MARK: - Synthesize

    @MainActor
    public func synthesize(
        text: String, saveTo: String?, voiceId: String, style: String, role: String
    ) async throws {
        let tokenizor = Tokenizor()
        let sentences = tokenizor.splitToSentences(text, maxChars: 200)
        let stream = AsyncThrowingStream { cont in
            for s in sentences {
                cont.yield(s)
            }
            cont.finish()
        }
        try await streamSynthesize(
            textStream: stream, saveTo: saveTo, voiceId: voiceId, style: style, role: role)
    }

    @MainActor
    public func streamSynthesize(
        textStream: AsyncThrowingStream<String, Error>,
        saveTo: String?,
        voiceId: String,
        style: String,
        role: String
    ) async throws {
        // Cancel any previous round still running.
        if let oldRound = round {
            oldRound.task?.cancel()
            // Wait briefly for the old task to clean up (best-effort).
            try? await oldRound.task?.value
        }

        // Fresh per-round state — completely isolated from previous rounds.
        let r = RoundState()
        round = r
        let finished = r.finished
        isPlaying = true

        r.task = Task { [unowned self] in
            defer {
                infoLog("finished.")
                finished.finish(())
                isPlaying = false
            }

            let channel = AsyncChannel<(String, any StreamSynthesizerProtocol & Sendable)>()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @Sendable in
                    defer {
                        infoLog("all player finished load.")
                        channel.finish()
                    }

                    for try await text in textStream {
                        try Task.checkCancellation()
                        infoLog("load for: \(text)")
                        let player = self.newPlayerFunc(text, voiceId, style, role)
                        try player.load()
                        // Hand to consumer immediately so it can start streaming
                        // playback (first-packet-plays). Then wait for this sentence's
                        // synth to finish before starting the next one — keeps Azure
                        // single-session serialisation intact.
                        await channel.send((text, player))
                        try await player.waitForLoadFinished()
                        infoLog("load finished for: \(text)")
                    }
                }

                group.addTask { @Sendable in
                    for await (text, player) in channel.buffer(policy: .bounded(5)) {
                        try Task.checkCancellation()
                        r.players.withLock { $0.append(player) }
                        infoLog("start play for: \(text)")
                        try await player.play()
                        infoLog("wait for player to stop")
                        try await player.waitForPlayStopped()
                        infoLog("play stopped for: \(text)")
                    }
                }

                for try await _ in group {
                }
            }

            try Task.checkCancellation()

            infoLog("players count: \(r.players.withLock { $0.count })")
            guard let saveTo, !r.players.withLock({ $0.isEmpty }) else {
                return
            }

            let mp3Files = r.players.withLock {
                $0.map { player in
                    player.cachePath()
                }
            }
            let outputMp3File = buildURLForAudio(named: saveTo, format: .pcm)
            infoLog("will save to \(outputMp3File)")
            do {
                try FileManager.default.createDirectory(
                    at: outputMp3File.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: nil)
            } catch {
                errorLog("Error creating directory: \(error.localizedDescription)")
                throw error
            }

            do {
                try await mergeMP3Files(audioFileUrls: mp3Files, outputUrl: outputMp3File)
            } catch {
                errorLog("mergeMP3Files: \(error.localizedDescription)")
                throw error
            }
        }

        if let task = r.task {
            try await task.value
        }
    }

    @MainActor
    public func waitForPlayerToStop() async throws {
        guard let r = round else { return }
        try await r.finished.wait()
    }

    public func stopPlaying() throws {
        infoLog("stop Playing")
        guard let r = round else { return }
        if let task = r.task, !task.isCancelled {
            task.cancel()
        }
        r.players.withLock { players in
            for player in players {
                infoLog("stop player inner")
                if player.isPlaying {
                    try? player.stop()
                }
            }
        }
    }

    public func stopPlayingAndSynthesizing() throws {
        infoLog("stopPlayingAndSynthesizing")
        try stopPlaying()
    }
}

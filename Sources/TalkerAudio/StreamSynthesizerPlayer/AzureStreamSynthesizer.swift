//
//  AzureStreamSynthesizer.swift (refactored)
//
//  Lightweight per-sentence request object. Borrows a shared
//  ReusableAzureSynthesizer session instead of creating its own
//  SPXSpeechSynthesizer + SPXConnection.
//

import AudioToolbox
import Foundation
import StreamAudio
import SwiftUI
import TalkerCommon

public enum StreamSynthesizerError: String, LocalizedError, Sendable {
    case speechSynthesizerNotExist
    case synthesizeCancelled
    case synthesizerBusy
    case allocBuffer

    public var errorDescription: String? {
        self.rawValue
    }
}

public class AzureStreamSynthesizer: StreamSynthesizerProtocol {

    private let reusable: ReusableAzureSynthesizer
    private let text: String
    private let voiceId: String
    private let style: String
    private let role: String

    private nonisolated(unsafe) let player: StreamAudio.StreamAudioPlayer
    private var finishedSignal: OneShotChannel<Void>?
    private var isLoaded = false

    public init(
        text: String,
        voiceId: String,
        style: String,
        role: String,
        reusable: ReusableAzureSynthesizer
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        self.voiceId = voiceId
        self.style = style
        self.role = role
        self.reusable = reusable

        var cachePath = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        cachePath.appendPathExtension("mp3")
        self.player = StreamAudio.StreamAudioPlayer(cachePath: cachePath, fileType: kAudioFileMP3Type)
    }

    // MARK: - SSML

    private func buildSsmlText() -> String {
        let lang = getLangFromVoiceId(voiceId) ?? "en-US"
        return """
            <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="\(lang)">
                <voice name="\(voiceId)">
                    <mstts:express-as role="\(role)" style="\(style)">
                        \(text)
                    </mstts:express-as>
                </voice>
            </speak>
            """
    }

    // MARK: - StreamSynthesizerProtocol

    public var isPlaying: Bool {
        player.runningState == .playing
    }

    public func load() throws {
        guard !isLoaded else { return }
        isLoaded = true
        let ssml = buildSsmlText()
        infoLog("AzureStreamSynthesizer load: \(text)")
        finishedSignal = try reusable.startSpeaking(ssml: ssml, player: player)
    }

    public func waitForLoadFinished() async throws {
        guard let signal = finishedSignal else { return }
        try await signal.wait()
    }

    public func play() async throws {
        try load()
        try await waitForLoadFinished()
        infoLog("finish load:", text)
        try await player.play()
        infoLog("start play:", text)
    }

    public func stop() throws {
        try player.stop()
        reusable.stopCurrentUtterance()
    }

    public func waitForPlayStopped() async throws {
        try await player.waitForStop()
        infoLog("play finished:", text)
    }

    public func cachePath() -> URL {
        player.cacheFilePath()
    }
}

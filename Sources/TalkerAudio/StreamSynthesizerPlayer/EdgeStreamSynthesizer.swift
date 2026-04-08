//
//  EdgeTest.swift
//  iOS
//
//  Created by feichao on 2023/6/27.
//

import AVFoundation
import Foundation
import OSLog
import StreamAudio
import SwiftUI
import TalkerCommon
import CryptoKit


fileprivate class EdgeConstants {
    private static let BASE_URL = "speech.platform.bing.com/consumer/speech/synthesize/readaloud"
    private static let TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"

    private static let WSS_URL: String = {
        return "wss://\(BASE_URL)/edge/v1?TrustedClientToken=\(TRUSTED_CLIENT_TOKEN)"
    }()

    private static let VOICE_LIST: String = {
        return "https://\(BASE_URL)/voices/list?trustedclienttoken=\(TRUSTED_CLIENT_TOKEN)"
    }()

    static let DEFAULT_VOICE = "en-US-EmmaMultilingualNeural"

    private static let CHROMIUM_FULL_VERSION = "130.0.2849.68"
    private static let CHROMIUM_MAJOR_VERSION: String = {
        return CHROMIUM_FULL_VERSION.components(separatedBy: ".").first ?? ""
    }()

    private static let SEC_MS_GEC_VERSION: String = {
        return "1-\(CHROMIUM_FULL_VERSION)"
    }()

    private static let BASE_HEADERS: [String: String] = {
        return [
            "User-Agent": """
                Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                (KHTML, like Gecko) Chrome/\(CHROMIUM_MAJOR_VERSION).0.0.0 Safari/537.36 \
                Edg/\(CHROMIUM_MAJOR_VERSION).0.0.0
                """,
            "Accept-Encoding": "gzip, deflate, br",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }()

    static let WSS_HEADERS: [String: String] = {
        var headers = [
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
        ]
        headers.merge(BASE_HEADERS) { (_, new) in new }
        return headers
    }()

    static let VOICE_HEADERS: [String: String] = {
        var headers = [
            "Authority": "speech.platform.bing.com",
            "Sec-CH-UA": """
                " Not;A Brand";v="99", "Microsoft Edge";v="\(CHROMIUM_MAJOR_VERSION)", \
                "Chromium";v="\(CHROMIUM_MAJOR_VERSION)"
                """,
            "Sec-CH-UA-Mobile": "?0",
            "Accept": "*/*",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty"
        ]
        headers.merge(BASE_HEADERS) { (_, new) in new }
        return headers
    }()
    
    static func generateSecMsGecToken() -> String {
        // Get the current time in Windows file time format (100ns intervals since 1601-01-01)
        let now = Date()
        let unixEpoch = now.timeIntervalSince1970
        let windowsEpochOffset: Double = 11644473600  // Difference in seconds between 1601-01-01 and 1970-01-01
        let windowsTime = (unixEpoch + windowsEpochOffset) * 10_000_000  // Convert to 100ns intervals
        var ticks = UInt64(windowsTime)
        
        // Round down to the nearest 5 minutes (3,000,000,000 * 100ns = 5 minutes)
        ticks -= ticks % 3_000_000_000
        
        // Create the string to hash by concatenating the ticks and the trusted client token
        let strToHash = "\(ticks)\(TRUSTED_CLIENT_TOKEN)"
        
        // Compute the SHA256 hash
        let dataToHash = strToHash.data(using: .ascii)!
        let hash = SHA256.hash(data: dataToHash)
        
        // Convert the hash to an uppercase hexadecimal string
        let hexString = hash.compactMap { String(format: "%02X", $0) }.joined()
        
        return hexString
    }

    static func generateSecMsGecVersion() -> String {
        return "1-\(CHROMIUM_FULL_VERSION)"
    }
    
    static let BINARY_DELIM = Data("Path:audio\r\n".utf8)
    
    static func wssUrl() -> String {
        "\(Self.WSS_URL)&Sec-MS-GEC=\(EdgeConstants.generateSecMsGecToken())&Sec-MS-GEC-Version=\(EdgeConstants.generateSecMsGecVersion())&ConnectionId=\(UUID().uuidString)"
    }
    
    static func getVoiceListUrl() -> String {
        "\(Self.VOICE_LIST)&Sec-MS-GEC=\(EdgeConstants.generateSecMsGecToken())&Sec-MS-GEC-Version=\(EdgeConstants.generateSecMsGecVersion())&ConnectionId=\(UUID().uuidString)"
    }
}

public final class EdgeStreamSynthesizer: NSObject, URLSessionWebSocketDelegate, StreamSynthesizerProtocol {
    private nonisolated(unsafe) var webSocketTask: URLSessionWebSocketTask?
    private let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private let synthUrl: String
    private let text: String
    private let voice: String
    private let voiceLocale: String
    private let websocketConnected = OneShotChannel()
    private nonisolated(unsafe) var isDataLoaded = false
    private nonisolated(unsafe) let player: StreamAudio.StreamAudioPlayer

    public init(text: String, voice: String) {
        self.text = text
        self.voice = voice
        self.synthUrl = EdgeConstants.wssUrl()
        self.voiceLocale = getLangFromVoiceId(voice) ?? "en-US"
        var cachePath = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        cachePath.appendPathExtension("mp3")
        self.player = StreamAudio.StreamAudioPlayer(cachePath: cachePath, fileType: kAudioFileMP3Type)
    }

    public var isPlaying: Bool {
        return player.runningState == .playing
    }

    public func play() async throws {
        debugLog("start load: \(self.text)")
        try load()
        // Stream-play: start playback immediately, don't wait for full load.
        // StreamAudioPlayer pauses when data runs out and resumes when more arrives.
        debugLog("play (streaming): \(self.text)")
        try await player.play()
    }

    public func stop() throws {
        debugLog("stop player: \(self.text)")
        webSocketTask?.cancel()
        try player.stop()
    }

    public func waitForPlayStopped() async throws {
        try await player.waitForStop()
    }

    public func load() throws {
        guard webSocketTask == nil else {
            return
        }

        var request = URLRequest(url: URL(string: synthUrl)!)
        request.allHTTPHeaderFields = EdgeConstants.WSS_HEADERS
        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.delegate = self
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
    }

    public func waitForLoadFinished() async throws {
        guard let webSocketTask else {
            throw MessageError("No websocket available")
        }

        if isDataLoaded {
            infoLog("load finished, skip: \(self.text)")
            return
        }
        
        infoLog("websocket state: \(webSocketTask.state.rawValue), closeCode: \(webSocketTask.closeCode.rawValue), text: \(self.text)")

        defer {
            infoLog("player finish data: \(self.text)")
            do {
                try player.finishData()
            } catch {
                errorLog("finish data error:", error)
            }
        }

        try await websocketConnected.wait()

        infoLog("new task, url: \(synthUrl), text: \(self.text)")
        try await webSocketTask.send(
            .string(
                """
                Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{"context": {"synthesis": {"audio": {"metadataoptions": {"sentenceBoundaryEnabled": "false","wordBoundaryEnabled": "false"},"outputFormat": "\(self.outputFormat)"}}}}\r\n
                """))
        infoLog("send header: \(self.text)")

        try await self.rawSSMLRequest(requestSSML: self.ssmlTemplate())

        loop: while true {
            let message = try await webSocketTask.receive()
            //            debugLog("new message: \(String(describing: message))")
            switch message {
            case .string(let data):
                if data.contains("Path:turn.start") {
                    debugLog("Path:turn.start")
                } else if data.contains("Path:turn.end") {
                    debugLog("Path:turn.end")
                    break loop
                } else if data.contains("Path:response") {
                    debugLog("Path:response")
                } else {
                    errorLog("unknown message")
                }
            case .data(let data):
                if data == Data([0x00, 0x67, 0x58]) {
                    // end empty
                    debugLog("end empty bytes")
                    break
                } else {
                    //                    debugLog("binary audio data")
                    guard let range = data.range(of: EdgeConstants.BINARY_DELIM) else {
                        errorLog("no range found")
                        return
                    }
                    let audioData = data.subdata(in: range.upperBound..<data.count)
                    if audioData.isEmpty {
                        continue
                    }
                    //                    debugLog("receive \(audioData.count) bytes")
                    try player.writeData(audioData)
                }
            @unknown default:
                fatalError()
            }
        }
        infoLog("close websocket: \(self.text)")
        webSocketTask.cancel(with: .normalClosure, reason: "Normal close".data(using: .utf8))
        isDataLoaded = true
        infoLog(
            "websocket after close: \(String(describing: webSocketTask.state)), \(String(describing: webSocketTask.closeCode)), \(String(describing: webSocketTask.closeReason))"
        )
    }

    private func rawSSMLRequest(requestSSML: String) async throws {
        guard let webSocketTask else {
            return
        }
        let requestId = connectId()
        let request = "X-RequestId:\(requestId)\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n\(requestSSML)"
        // https://docs.microsoft.com/en-us/azure/cognitive-services/speech-service/speech-synthesis-markup
        try await webSocketTask.send(.string(request))
    }

    private func ssmlTemplate() -> String {
        return """
            <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="\(voiceLocale)"><voice name="\(voice)">\(text)</voice></speak>
            """
    }

    private func connectId() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        debugLog("websocket connected: \(self.text)")
        websocketConnected.finish(())
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        if websocketConnected.isFinished {
            return
        }
        debugLog("websocket close: \(closeCode.rawValue), \(self.text)")
        if closeCode == .normalClosure {
            websocketConnected.finish(())
        } else {
            websocketConnected.finish(throwing: MessageError(String(describing: closeCode)))
        }
    }

    public func cachePath() -> URL {
        player.cacheFilePath()
    }
}

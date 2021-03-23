//
//  YandexSpeechToText.swift
//  YandexSpeechKit
//
//  Created by Vladislav Popovich on 28.01.2020.
//  Copyright © 2020 Just Ai. All rights reserved.
//

import AVFoundation
import Foundation
#if canImport(Aimybox)
import Aimybox

public class YandexSpeechToText: AimyboxComponent, SpeechToText {
    /**
     Customize `config` parameter if you change recognition audioFormat in recognition config.
     */
    public var audioFormat: AVAudioFormat = .defaultFormat
    /**
     Used to notify *Aimybox* state machine about events.
     */
    public var notify: (SpeechToTextCallback)?
    /**
     Used for audio signal processing.
     */
    private let audioEngine: AVAudioEngine
    /**
     Node on which audio stream is routed.
     */
    private var audioInputNode: AVAudioNode?
    /**
     */
    private lazy var recognitionAPI = YandexRecognitionAPI(
        iAM: iamToken,
        folderID: folderID,
        language: languageCode,
        api: sttAPIAdress,
        config: config,
        dataLoggingEnabled: dataLoggingEnabled,
        operation: operationQueue
    )
    /**
     */
    private var wasSpeechStopped: Bool = true

    private let iamToken: String

    private let folderID: String

    private let languageCode: String

    private let sttAPIAdress: String

    private let config: Yandex_Cloud_Ai_Stt_V2_RecognitionConfig?

    private let dataLoggingEnabled: Bool

    /**
     Init that uses provided params.
     */
    public init?(
        tokenProvider: IAMTokenProvider,
        folderID: String,
        language code: String = "ru-RU",
        sttAPIAdress: String = "stt.api.cloud.yandex.net:443",
        config: Yandex_Cloud_Ai_Stt_V2_RecognitionConfig? = nil,
        dataLoggingEnabled: Bool = false
    ) {
        let token = tokenProvider.token()
        
        guard let iamToken = token?.iamToken else {
            return nil
        }

        self.iamToken = iamToken
        self.folderID = folderID
        self.languageCode = code
        self.sttAPIAdress = sttAPIAdress
        self.config = config
        self.audioEngine = AVAudioEngine()
        self.dataLoggingEnabled = dataLoggingEnabled
        super.init()
    }
    
    public func startRecognition() {
        guard wasSpeechStopped else { return }
        wasSpeechStopped = false

        checkPermissions { [weak self] result in
            switch result {
            case .success:
                self?.onPermissionGranted()
            default:
                self?.notify?(result)
            }
        }
    }
    
    public func stopRecognition() {
        wasSpeechStopped = true
        audioEngine.stop()
        audioInputNode?.removeTap(onBus: 0)
        audioInputNode = nil
        recognitionAPI.closeStream()
    }
    
    public func cancelRecognition() {
        wasSpeechStopped = true
        audioEngine.stop()
        audioInputNode?.removeTap(onBus: 0)
        audioInputNode = nil
        operationQueue.addOperation { [weak self] in
            self?.recognitionAPI.closeStream()
            self?.notify?(.success(.recognitionCancelled))
        }
    }
     
    // MARK: - Internals
    
    private func onPermissionGranted() {
        prepareRecognition()
        guard !wasSpeechStopped else { return }

        do {
            try audioEngine.start()
            notify?(.success(.recognitionStarted))
        } catch {
            notify?(.failure(.microphoneUnreachable))
        }
    }
    
    private func prepareRecognition() {
        guard let _notify = notify else { return }
        
        // Setup AudioSession for recording
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record)
            try audioSession.setMode(.measurement)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return _notify(.failure(.microphoneUnreachable))
        }
        
        recognitionAPI.openStream(onOpen: { [audioEngine, weak self, audioFormat] (stream) in
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let recordingFormat = audioFormat

            try? audioSession.setPreferredSampleRate(inputFormat.sampleRate)

            let converter = AVAudioConverter(from: inputFormat, to: recordingFormat)
            let ratio = Float(inputFormat.sampleRate) / Float(
                recordingFormat.sampleRate > 0 ? recordingFormat.sampleRate : AVAudioFormat.defaultFormat.sampleRate
            )

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak stream] buffer, time in
                try? stream?.send(
                    Yandex_Cloud_Ai_Stt_V2_StreamingRecognitionRequest.with({ request in
                        let capacity = UInt32(Float(buffer.frameCapacity) / Float(ratio > 0 ? ratio : 1))
                        guard let outputBuffer = AVAudioPCMBuffer(
                            pcmFormat: recordingFormat,
                            frameCapacity: capacity
                        ) else {
                            return
                        }

                        outputBuffer.frameLength = outputBuffer.frameCapacity

                        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                            outStatus.pointee = AVAudioConverterInputStatus.haveData
                            return buffer
                        }

                        let status = converter?.convert(
                            to: outputBuffer,
                            error: nil,
                            withInputFrom: inputBlock
                        )

                        switch status {
                        case .error:
                            return
                        default:
                            break
                        }

                        guard let _bytes = outputBuffer.int16ChannelData else { return }
                        
                        let channels = UnsafeBufferPointer(start: _bytes, count: Int(audioFormat.channelCount))
                        
                        request.audioContent = Data(bytesNoCopy: channels[0],
                                                    count: Int(buffer.frameCapacity*audioFormat.streamDescription.pointee.mBytesPerFrame),
                                                    deallocator: .none)
                    })
                )
            }

            self?.audioInputNode = inputNode
            audioEngine.prepare()

            }, onResponse: { [weak self] response in
                self?.proccessResults(response)
            }, error: { (error) in
                _notify(.failure(.speechRecognitionUnavailable))
            }, completion: { [weak self] in
                self?.stopRecognition()
        })
    }
    
    private func proccessResults(_ response: Yandex_Cloud_Ai_Stt_V2_StreamingRecognitionResponse) {
        guard !wasSpeechStopped, let phrase = response.chunks.first, let bestAlternative = phrase.alternatives.first else {
            return
        }

        guard phrase.final == true else {
            notify?(.success(.recognitionPartialResult(bestAlternative.text)))
            return
        }
        
        let finalResult = bestAlternative.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard finalResult.isEmpty == false else {
            notify?(.success(.emptyRecognitionResult))
            return
        }
        
        notify?(.success(.recognitionPartialResult(finalResult)))
        notify?(.success(.recognitionResult(finalResult)))
    }

    // MARK: - User Permissions
    private func checkPermissions(_ completion: @escaping (SpeechToTextResult) -> Void ) {
        
        var recordAllowed: Bool = false
        let permissionsDispatchGroup = DispatchGroup()
        
        permissionsDispatchGroup.enter()
        DispatchQueue.main.async {
            // Microphone recording permission
            AVAudioSession.sharedInstance().requestRecordPermission { isAllowed in
                recordAllowed = isAllowed
                permissionsDispatchGroup.leave()
            }
        }
        
        permissionsDispatchGroup.notify(queue: .main) {
            if recordAllowed {
                completion(.success(.recognitionPermissionsGranted))
            } else {
                completion(.failure(.microphonePermissionReject))
            }
        }
    }
}

extension AVAudioFormat {
    static var defaultFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: 48000,
                      channels: 1,
                      interleaved: false)!
    }
}

#endif

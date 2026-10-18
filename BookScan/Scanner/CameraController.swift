import Foundation
import AVFoundation
import UIKit

enum CameraError: LocalizedError {
    case unavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "カメラを使えません"
        case .captureFailed: return "撮影に失敗しました"
        }
    }
}

/// 背面カメラ（プレビュー・解析用フレーム・高解像度の静止画）
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "bookscan.camera.video", qos: .userInitiated)

    private let sessionQueue = DispatchQueue(label: "bookscan.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?
    private var captureAngle: CGFloat?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private let lock = NSLock()
    private var photoHandlers: [Int64: (Result<Data, Error>) -> Void] = [:]

    /// 解析用フレーム（videoQueue 上でだけ読み書きする）
    private var frameHandler: ((CVPixelBuffer, Double) -> Void)?

    /// 解析用フレームの受け取り先を設定（どのスレッドからでも安全）
    func setFrameHandler(_ handler: ((CVPixelBuffer, Double) -> Void)?) {
        videoQueue.async { self.frameHandler = handler }
    }

    var isAdjustingFocus: Bool {
        guard let d = device else { return false }
        return d.isAdjustingFocus || d.isAdjustingExposure
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// - Parameter highestResolution: true なら端末の最大解像度、false なら約1200万画素まで
    func configure(highestResolution: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureOnQueue(highestResolution: highestResolution)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue(highestResolution: Bool) throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.unavailable
        }
        self.device = device
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else { throw CameraError.unavailable }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let limit = highestResolution ? Int.max : 12_600_000
        if let best = dims
            .filter({ Int($0.width) * Int($0.height) <= limit })
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) ?? dims.first {
            photoOutput.maxPhotoDimensions = best
        }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.unavailable }
        session.addOutput(videoOutput)

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        device.unlockForConfiguration()
        configured = true
    }

    /// プレビューを接続し、端末の向きに合わせて回転させる
    @MainActor
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        setCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPreviewRotation(angle) }
            }
        }
        captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.setCaptureAngle(angle)
        }
    }

    /// いま撮ったら写真が何度回転するか
    var currentCaptureAngle: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(captureAngle ?? 90)
    }

    private func setCaptureAngle(_ angle: CGFloat) {
        lock.lock()
        captureAngle = angle
        lock.unlock()
    }

    @MainActor
    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let conn = previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) else { return }
        conn.videoRotationAngle = angle
    }

    func start() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let d = self.device, d.hasTorch else { return }
            do {
                try d.lockForConfiguration()
                if on {
                    try d.setTorchModeOn(level: 0.6)
                } else {
                    d.torchMode = .off
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    /// 画面をタップした位置にピントを合わせる（capture device 座標）
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = devicePoint
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                }
                if d.isExposurePointOfInterestSupported {
                    d.exposurePointOfInterest = devicePoint
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: 撮影

    func capture(fast: Bool, completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        let captureAngle = self.captureAngle
        lock.unlock()
        sessionQueue.async {
            guard self.session.isRunning else {
                completion(.failure(CameraError.captureFailed))
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = fast ? .balanced : .quality
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            if let conn = self.photoOutput.connection(with: .video), let angle = captureAngle,
               conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            self.lock.lock()
            self.photoHandlers[settings.uniqueID] = completion
            self.lock.unlock()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        lock.lock()
        let handler = photoHandlers.removeValue(forKey: id)
        lock.unlock()
        if let error {
            handler?(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            handler?(.success(data))
        } else {
            handler?(.failure(CameraError.captureFailed))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // didFinishProcessingPhoto が呼ばれずに終わった場合の保険
        lock.lock()
        let handler = photoHandlers.removeValue(forKey: resolvedSettings.uniqueID)
        lock.unlock()
        handler?(.failure(error ?? CameraError.captureFailed))
    }

    // MARK: フレーム

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        frameHandler?(pb, t)
    }
}

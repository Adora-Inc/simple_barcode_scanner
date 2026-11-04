import Flutter
import UIKit
import AVFoundation

class BarcodeScannerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return BarcodeScannerPlatformView(
            frame: frame,
            viewId: viewId,
            args: args as? [String: Any] ?? [:],
            messenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

private class CameraPreviewView: UIView {
    var onLayout: (() -> Void)?

    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}

class BarcodeScannerPlatformView: NSObject, FlutterPlatformView, AVCaptureMetadataOutputObjectsDelegate {
    private let previewView: CameraPreviewView
    private let channel: FlutterMethodChannel
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "simple_barcode_scanner.view.session")
    private let usesFrontCamera: Bool
    private let metadataTypes: [AVMetadataObject.ObjectType]
    private let scanAreaSize: CGSize?
    private let metadataOutput = AVCaptureMetadataOutput()
    private var isDetecting = true
    // Main thread only. Reset when starting fails, so startScanning can retry.
    private var hasStarted = false
    // sessionQueue only.
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []

    init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
        previewView = CameraPreviewView(frame: frame)
        previewView.backgroundColor = .black
        previewView.previewLayer.videoGravity = .resizeAspectFill
        channel = FlutterMethodChannel(
            name: "plugins.codingwithtashi/barcode_scanner_view_\(viewId)",
            binaryMessenger: messenger
        )
        usesFrontCamera = (args["cameraFace"] as? Int) == 1
        // Dart sends logical px, which are points on iOS.
        if let width = args["scannerWidth"] as? Int, let height = args["scannerHeight"] as? Int {
            scanAreaSize = CGSize(width: width, height: height)
        } else {
            scanAreaSize = nil
        }
        switch args["scanFormat"] as? String {
        case "ONLY_QR_CODE":
            metadataTypes = ONLY_QR_CODE
        case "ONLY_BARCODE":
            metadataTypes = ONLY_BARCODE
        default:
            metadataTypes = ALL_FORMATS
        }
        super.init()

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        previewView.onLayout = { [weak self] in
            self?.updatePreviewOrientation()
            self?.updateRectOfInterest()
        }
        observeSession()
        // The session starts on "startScanning", once Dart has attached its handler,
        // so an early onError can't be lost.
    }

    func view() -> UIView {
        return previewView
    }

    private func start() {
        guard !hasStarted else { return }
        hasStarted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureSession()
                } else {
                    self?.failStart(code: "PERMISSION_DENIED", message: "Camera permission denied")
                }
            }
        default:
            failStart(code: "PERMISSION_DENIED", message: "Camera permission denied")
        }
    }

    private func failStart(code: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.hasStarted = false
            self?.sendError(code: code, message: message)
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.failStart(
                code: "CAMERA_UNAVAILABLE",
                message: error?.localizedDescription ?? "Camera stopped unexpectedly"
            )
        })
        // AVFoundation resumes the session itself when the interruption ends.
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: captureSession, queue: .main
        ) { [weak self] _ in
            self?.sendError(code: "CAMERA_UNAVAILABLE", message: "Camera is in use by another app")
        })
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Already configured (a retry after a runtime error): just run it again.
            if !self.captureSession.inputs.isEmpty {
                self.runSession()
                return
            }
            let position: AVCaptureDevice.Position = self.usesFrontCamera ? .front : .back
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                    ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.captureSession.canAddInput(input)
            else {
                self.failStart(code: "CAMERA_UNAVAILABLE", message: "Camera not available")
                return
            }
            self.captureSession.addInput(input)
            self.device = device

            let metadataOutput = self.metadataOutput
            guard self.captureSession.canAddOutput(metadataOutput) else {
                self.failStart(code: "CAMERA_UNAVAILABLE", message: "Unable to read barcodes from the camera")
                return
            }
            self.captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = self.metadataTypes.filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }

            DispatchQueue.main.async {
                self.previewView.previewLayer.session = self.captureSession
            }
            self.runSession()
        }
    }

    /// Call on sessionQueue.
    private func runSession() {
        captureSession.startRunning()
        guard captureSession.isRunning else {
            failStart(code: "CAMERA_UNAVAILABLE", message: "Camera failed to start")
            return
        }
        // The layer-to-metadata conversion is only valid once the session is running.
        DispatchQueue.main.async { [weak self] in
            self?.updatePreviewOrientation()
            self?.updateRectOfInterest()
        }
    }

    /// Keeps the video upright when the interface rotates (e.g. on iPad).
    private func updatePreviewOrientation() {
        guard #available(iOS 13.0, *) else { return }
        guard
            let connection = previewView.previewLayer.connection,
            let orientation = previewView.window?.windowScene?.interfaceOrientation
        else { return }
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            let videoOrientation: AVCaptureVideoOrientation
            switch orientation {
            case .landscapeRight: videoOrientation = .landscapeRight
            case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
            case .landscapeLeft: videoOrientation = .landscapeLeft
            default: videoOrientation = .portrait
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation
            }
        }
    }

    /// Limits the search region to the scan area (centred, scannerWidth x scannerHeight), or to
    /// the visible preview when no size is given, so codes cropped off by aspect fill are ignored.
    /// rectOfInterest restricts where AVFoundation looks, so a code mostly outside the area may
    /// not be read; Android instead accepts a code whose centre falls inside the area.
    private func updateRectOfInterest() {
        let layer = previewView.previewLayer
        let bounds = layer.bounds
        guard layer.session != nil, captureSession.isRunning, !bounds.isEmpty else { return }
        var scanRect = bounds
        if let size = scanAreaSize {
            scanRect = CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ).intersection(bounds)
        }
        metadataOutput.rectOfInterest = layer.metadataOutputRectConverted(fromLayerRect: scanRect)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            isDetecting,
            let barcode = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = barcode.stringValue
        else { return }

        // continuous and delayMillis are applied in Dart (BarcodeViewController) for both platforms.
        channel.invokeMethod("onBarcodeDetected", arguments: value)
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScanning":
            start()
            result(nil)
        case "pauseScanning":
            isDetecting = false
            result(nil)
        case "resumeScanning":
            isDetecting = true
            result(nil)
        case "toggleFlash":
            // On sessionQueue so it waits for configureSession to add the camera.
            sessionQueue.async { [weak self] in
                let value = self?.toggleTorch()
                    ?? FlutterError(code: "CAMERA_ERROR", message: "Torch not available", details: nil)
                DispatchQueue.main.async { result(value) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Call on sessionQueue.
    private func toggleTorch() -> Any {
        guard
            let device = device,
            device.hasTorch
        else {
            return FlutterError(code: "CAMERA_ERROR", message: "Torch not available", details: nil)
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            device.unlockForConfiguration()
            return device.torchMode == .on
        } catch {
            return FlutterError(code: "FLASH_ERROR", message: error.localizedDescription, details: nil)
        }
    }

    private func sendError(code: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onError", arguments: ["code": code, "message": message])
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

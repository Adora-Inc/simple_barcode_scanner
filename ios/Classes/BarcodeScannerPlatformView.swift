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
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
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
    private let isContinuous: Bool
    private let delayMillis: Int
    private let usesFrontCamera: Bool
    private let metadataTypes: [AVMetadataObject.ObjectType]
    private var isDetecting = true
    private var lastDetectionTime: Date?

    init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
        previewView = CameraPreviewView(frame: frame)
        previewView.backgroundColor = .black
        previewView.previewLayer.videoGravity = .resizeAspectFill
        channel = FlutterMethodChannel(
            name: "plugins.codingwithtashi/barcode_scanner_view_\(viewId)",
            binaryMessenger: messenger
        )
        isContinuous = args["continuous"] as? Bool ?? false
        delayMillis = args["delayMillis"] as? Int ?? 0
        usesFrontCamera = (args["cameraFace"] as? Int) == 1
        switch args["scanFormat"] as? String {
        case "ONLY_QR_CODE":
            metadataTypes = ONLY_QR_CODE
        case "ONLY_BARCODE":
            metadataTypes = ONLY_BARCODE
        default:
            metadataTypes = (args["scanType"] as? Int) == ScanMode.QR.index ? ONLY_QR_CODE : ALL_FORMATS
        }
        super.init()

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        configureSession()
    }

    func view() -> UIView {
        return previewView
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let position: AVCaptureDevice.Position = self.usesFrontCamera ? .front : .back
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                    ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.captureSession.canAddInput(input)
            else {
                self.sendError("Camera not available")
                return
            }
            self.captureSession.addInput(input)

            let metadataOutput = AVCaptureMetadataOutput()
            guard self.captureSession.canAddOutput(metadataOutput) else {
                self.sendError("Unable to read barcodes from the camera")
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
            self.captureSession.startRunning()
        }
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

        if let lastDetectionTime = lastDetectionTime,
           Date().timeIntervalSince(lastDetectionTime) * 1000 < Double(delayMillis) {
            return
        }
        lastDetectionTime = Date()
        if !isContinuous {
            isDetecting = false
        }
        channel.invokeMethod("onBarcodeDetected", arguments: value)
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pauseScanning":
            isDetecting = false
            result(nil)
        case "resumeScanning":
            isDetecting = true
            result(nil)
        case "toggleFlash":
            result(toggleTorch())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func toggleTorch() -> Any {
        guard
            let device = (captureSession.inputs.first as? AVCaptureDeviceInput)?.device,
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

    private func sendError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("onError", arguments: message)
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

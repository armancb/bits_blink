import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var captureSession: AVCaptureSession?
    private var eventSink: FlutterEventSink?
    private var isStreaming = false
    private var lastFrameTime: CFTimeInterval = 0
    private let frameDelta: CFTimeInterval = 0.066  // ~15 FPS

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as! FlutterViewController
        let messenger = controller.binaryMessenger

        // ── Control channel ──
        let channel = FlutterMethodChannel(
            name: "com.bitsblink/hardware",
            binaryMessenger: messenger
        )

        channel.setMethodCallHandler { [weak self] (call, result) in
            switch call.method {
            case "startDebugStream":
                self?.requestCameraAndStart(result: result)
            case "stopDebugStream":
                self?.stopStreaming()
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // ── Event channel for frame streaming ──
        let eventChannel = FlutterEventChannel(
            name: "com.bitsblink/debug_stream",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(FrameStreamHandler(appDelegate: self))

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func requestCameraAndStart(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startStreaming()
            result(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startStreaming()
                        result(true)
                    } else {
                        result(FlutterError(code: "PERMISSION_DENIED",
                                           message: "Camera permission denied", details: nil))
                    }
                }
            }
        default:
            result(FlutterError(code: "PERMISSION_DENIED",
                               message: "Camera permission denied", details: nil))
        }
    }

    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true

        let session = AVCaptureSession()
        session.sessionPreset = .medium
        self.captureSession = session

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true

        let queue = DispatchQueue(label: "com.bitsblink.cameraQueue")
        let delegate = ContinuousFrameDelegate { [weak self] pixelBuffer in
            self?.handleFrame(pixelBuffer)
        }
        output.setSampleBufferDelegate(delegate, queue: queue)
        objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        session.addOutput(output)
        session.startRunning()
    }

    func stopStreaming() {
        isStreaming = false
        captureSession?.stopRunning()
        captureSession = nil
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isStreaming else { return }

        // Throttle
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= frameDelta else { return }
        lastFrameTime = now

        guard let jpegData = processPixelBuffer(pixelBuffer) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(FlutterStandardTypedData(bytes: jpegData))
        }
    }

    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let yData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        defer { yData.deallocate() }

        let src = yBaseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let srcRow = src.advanced(by: row * yRowBytes)
            let dstRow = yData.advanced(by: row * width)
            dstRow.update(from: srcRow, count: width)
        }

        // ROI detection
        let blockSize = 8
        let roiBlocks = 4
        let gridW = width / blockSize
        let gridH = height / blockSize

        var bestSum: Int = 0
        var bestX = 0
        var bestY = 0

        if gridW > roiBlocks && gridH > roiBlocks {
            for gy in 0..<(gridH - roiBlocks) {
                for gx in 0..<(gridW - roiBlocks) {
                    var sum = 0
                    for by in 0..<roiBlocks {
                        for bx in 0..<roiBlocks {
                            let px = (gx + bx) * blockSize + blockSize / 2
                            let py = (gy + by) * blockSize + blockSize / 2
                            if py < height && px < width {
                                sum += Int(yData[py * width + px])
                            }
                        }
                    }
                    if sum > bestSum {
                        bestSum = sum
                        bestX = gx * blockSize
                        bestY = gy * blockSize
                    }
                }
            }
        }

        let roiSize = roiBlocks * blockSize
        let roiX = min(max(bestX, 0), max(width - roiSize, 0))
        let roiY = min(max(bestY, 0), max(height - roiSize, 0))

        // Convert to RGB + red bounding box
        let rgbData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 3)
        defer { rgbData.deallocate() }
        for i in 0..<(width * height) {
            let gray = yData[i]
            rgbData[i * 3]     = gray
            rgbData[i * 3 + 1] = gray
            rgbData[i * 3 + 2] = gray
        }

        drawRedRect(rgbData, width: width, height: height,
                    rx: roiX, ry: roiY, rw: roiSize, rh: roiSize, thickness: 2)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: rgbData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 3,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.7)
    }

    private func drawRedRect(_ data: UnsafeMutablePointer<UInt8>,
                             width: Int, height: Int,
                             rx: Int, ry: Int, rw: Int, rh: Int, thickness: Int) {
        func setRed(_ px: Int, _ py: Int) {
            guard px >= 0, px < width, py >= 0, py < height else { return }
            let idx = (py * width + px) * 3
            data[idx]     = 255
            data[idx + 1] = 0
            data[idx + 2] = 0
        }

        for t in 0..<thickness {
            for x in rx..<min(rx + rw, width) {
                setRed(x, ry + t)
                setRed(x, ry + rh - 1 - t)
            }
            for y in ry..<min(ry + rh, height) {
                setRed(rx + t, y)
                setRed(rx + rw - 1 - t, y)
            }
        }
    }
}

// ── Stream handler to wire eventSink ──
private class FrameStreamHandler: NSObject, FlutterStreamHandler {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        appDelegate?.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        appDelegate?.eventSink = nil
        appDelegate?.stopStreaming()
        return nil
    }
}

// ── Continuous frame delegate ──
private class ContinuousFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CVPixelBuffer) -> Void

    init(handler: @escaping (CVPixelBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer)
    }
}

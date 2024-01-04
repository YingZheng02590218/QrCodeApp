//
//  ViewController.swift
//  QrCodeApp
//
//  Created by Hisashi Ishihara on 2024/01/04.
//

import AVFoundation
import UIKit
//import Vision

class ViewController: UIViewController {
    
    // MARK: - 変数　定数
    
    // MARK: カメラプレビュー
    // 背面カメラの画像をPreviewとして表示するには、CALayerのサブクラス、AVCaptureVideoPreviewLayerを使います。
    @IBOutlet var preview: UIView!
    // AVCaptureVideoPreviewLayerにセッションを食わせてあとはサイズなり向きなりの設定をし、previewと名付けたUIViewにSublayerとして追加すればOKです。
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: self.session)
        layer.frame = preview.bounds
        layer.videoGravity = .resizeAspectFill
        layer.connection?.videoOrientation = .portrait
        return layer
    }()
    
    // MARK: 検知エリアの枠
    @IBOutlet private weak var detectArea: UIView! {
        didSet {
            detectArea.layer.borderWidth = 3.0
            detectArea.layer.borderColor = UIColor.red.cgColor
        }
    }
    
    // MARK: 追跡しているQRコードの枠
    private var boundingBox = CAShapeLayer()
    
    // 設定値
    private var allowDuplicateReading: Bool = false
    private var makeSound: Bool = false
    private var makeHapticFeedback: Bool = false
    private var showBoundingBox: Bool = false
    private var scannedQRs = Set<String>()
    
    // AVCaptureSession　初期化
    private let session = AVCaptureSession()
    // キューで実行する理由は２つあって
    // １つ目は、複数のスレッドからAVCaptureSessionを同時にいじると安全ではないということ
    // ２つ目は、セッションを開始するためのstartRunning()がブロッキングコールなのでMainとは異なるキューで実行する必要がある（ブロッキングコール＝UIをブロックしてしまう）
    private let sessionQueue = DispatchQueue(label: "sessionQueue")
    
    // AVCaptureDeviceInput
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // AVCaptureOutput
    // カメラから入力したデータからQRというメタデータを検知するために、AVCaptureMetadataOutputを作成します。
    private let metadataOutput = AVCaptureMetadataOutput()
    // 検知された順番でメタデータを受け取るためのシリアルキューも作っておきます。
    private let metadataObjectQueue = DispatchQueue(label: "metadataObjectQueue")
    
    // MARK: - ライフサイクル
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 権限 カメラからVideoデータを扱う権限をリクエスト
        requestAuthorization()
        
        DispatchQueue.main.async {
            // 追跡しているQRコードの枠
            self.setupBoundingBox()
        }
        
        sessionQueue.async {
            self.configureSession()
        }
        
        preview.layer.addSublayer(previewLayer)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 読み取り範囲の制限
        sessionQueue.async {
            DispatchQueue.main.async {
                print(self.detectArea.frame)
                let metadataOutputRectOfInterest = self.previewLayer.metadataOutputRectConverted(fromLayerRect: self.detectArea.frame)
                print(metadataOutputRectOfInterest)
                self.sessionQueue.async {
                    self.metadataOutput.rectOfInterest = metadataOutputRectOfInterest
                }
            }
            // 最後、startRunning()でセッションを開始すればQRコードを読み取ることができるようになりました！
            self.session.startRunning()
        }
    }
    
    // MARK: - セットアップ
    
    // MARK: カメラ権限
    // 権限 カメラからVideoデータを扱う権限をリクエスト
    func requestAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    // 😭
                }
            }
        default:
            print("The user has previously denied access.")
        }
    }
    
    // MARK: configureSession
    // AVCapureSession初期化開始＆Device取得
    private func configureSession() {
        // これはもろもろのセッション初期化処理をバッチで変更するためのものです。
        session.beginConfiguration()
        // デバイスを指定
        let defaultVideoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
                                                         for: .video, // カメラの用途
                                                         position: .back // ポジション
        )
        guard let videoDevice = defaultVideoDevice else {
            session.commitConfiguration()
            return
        }
        // AVCaptureDeviceInput
        // 先程取得したvideoDeviceをAVCaptureDeviceInputにセットし、Sessionに追加します。
        // 後ほどデバイスの設定変更などで利用するのでこのときのvideoDeviceInputは保持しています。
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
        } catch {
            // この後のセッションに対する設定を加えていきますが、それらの変更はcommitConfiguration()を呼んだときに反映されます。ここではエラーになったときに、即commitConfiguration()を呼んで設定終了していますね。
            session.commitConfiguration()
            return
        }
        
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            // metadataOutputに、メタデータを検知したときのDelegateメソッドを追加する
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataObjectQueue)
            // 検知対象のmetadataObjectTypesに.qrを指定
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            // この後のセッションに対する設定を加えていきますが、それらの変更はcommitConfiguration()を呼んだときに反映されます。ここではエラーになったときに、即commitConfiguration()を呼んで設定終了していますね。
            session.commitConfiguration()
        }
        
        // VisionでQR検知したい場合はコメントアウトしてね
        //        if session.canAddOutput(videoDataOutput) {
        //            session.addOutput(videoDataOutput)
        //
        //            videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
        //        }
        
        session.commitConfiguration()
    }
    
    // MARK: QRコード読み取りよくある機能

    // MARK: 追跡しているQRコードの枠
    private func setupBoundingBox() {
        boundingBox.frame = preview.layer.bounds
        boundingBox.strokeColor = UIColor.green.cgColor
        boundingBox.lineWidth = 4.0
        boundingBox.fillColor = UIColor.clear.cgColor
        
        preview.layer.addSublayer(boundingBox)
    }
    
    // Draw bounding box
    private func updateBoundingBox(_ points: [CGPoint]) {
        guard let firstPoint = points.first else {
            return
        }
        
        let path = UIBezierPath()
        path.move(to: firstPoint)
        
        var newPoints = points
        newPoints.removeFirst()
        newPoints.append(firstPoint)
        
        newPoints.forEach { path.addLine(to: $0) }
        
        boundingBox.path = path.cgPath
        boundingBox.isHidden = false
    }
    
    private var resetTimer: Timer?
    fileprivate func hideBoundingBox(after: Double) {
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval() + after,
                                          repeats: false) { [weak self] (timer) in
            self?.boundingBox.isHidden = true }
    }
    
    private func resetViews() {
        boundingBox.isHidden = true
    }
    
    // MARK: Zoom
    private func setZoomFactor(_ zoomFactor: CGFloat) {
        guard let videoDeviceInput = self.videoDeviceInput else { return }
        do {
            try videoDeviceInput.device.lockForConfiguration()
            videoDeviceInput.device.videoZoomFactor = zoomFactor
            videoDeviceInput.device.unlockForConfiguration()
        } catch {
            print("Could not lock for configuration: \(error)")
        }
    }
    
    // MARK: Torch
    private func switchTorch(_ mode: AVCaptureDevice.TorchMode) {
        guard let videoDeviceInput = self.videoDeviceInput,
              videoDeviceInput.device.hasTorch == true,
              videoDeviceInput.device.isTorchAvailable == true
        else { return }
        do {
            try videoDeviceInput.device.lockForConfiguration()
            videoDeviceInput.device.torchMode = mode
            videoDeviceInput.device.unlockForConfiguration()
        } catch {
            print("Could not lock for configuration: \(error)")
        }
    }
    
    // MARK: Sounds
    private func playSuccessSound() {
        if makeSound == true {
            let soundIdRing: SystemSoundID = 1057
            AudioServicesPlaySystemSound(soundIdRing)
        }
    }
    
    private func playErrorSound() {
        if makeSound == true {
            let soundIdError: SystemSoundID = 1073
            AudioServicesPlayAlertSound(soundIdError)
        }
    }
    
    // MARK: Haptic feedback
    private func HapticSuccessNotification() {
        if makeHapticFeedback == true {
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.success)
        }
    }
    
    private func HapticErrorNotification() {
        if makeHapticFeedback == true {
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.error)
        }
    }
    
    // MARK: - アクション
            
    @IBAction func switchTorch(_ sender: UISwitch) {
        if sender.isOn {
            switchTorch(.on)
        } else {
            switchTorch(.off)
        }
    }
    
    @IBAction func makeSound(_ sender: UISwitch) {
        if sender.isOn {
            makeSound = true
        } else {
            makeSound = false
        }
    }
    
    @IBAction func makeHaptic(_ sender: UISwitch) {
        if sender.isOn {
            makeHapticFeedback = true
        } else {
            makeHapticFeedback = false
        }
    }
    
    @IBAction func allowDuplicateReading(_ sender: UISwitch) {
        scannedQRs = []
        if sender.isOn {
            allowDuplicateReading = true
        } else {
            allowDuplicateReading = false
        }
    }
    
    @IBAction func showBoundingBox(_ sender: UISwitch) {
        if sender.isOn {
            showBoundingBox = true
        } else {
            showBoundingBox = false
        }
    }
    
    @IBAction func changeZoom(_ sender: UISlider) {
        setZoomFactor(CGFloat(sender.value))
    }
    
}

// MARK: AVCaptureMetadataOutputObjectsDelegate
extension ViewController: AVCaptureMetadataOutputObjectsDelegate {
    // １点、気をつけておきたいのが、このデリゲートメソッドはメタデータを検知している限り、かなり短い間に連続して呼ばれます。なのでひたすら同じQRコードが読み取られ続けます。
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // metadataObjectsに含まれるそれぞれのmetadataObjectが、
        // AVMetadataMachineReadableCodeObjectであり、
        // タイプが.qrであり
        // 文字列の値を取り出せたら
        // 成功！無事QRコード読み取り成功となります
        for metadataObject in metadataObjects {
            guard let machineReadableCode = metadataObject as? AVMetadataMachineReadableCodeObject,
                  machineReadableCode.type == .qr,
                  let stringValue = machineReadableCode.stringValue
            else {
                return
            }
            
            if showBoundingBox {
                guard let transformedObject = previewLayer.transformedMetadataObject(for: machineReadableCode) as? AVMetadataMachineReadableCodeObject
                else { return }
                
                DispatchQueue.main.async {
                    self.updateBoundingBox(transformedObject.corners)
                    self.hideBoundingBox(after: 0.1)
                }
            }
            
            if allowDuplicateReading {
                if !self.scannedQRs.contains(stringValue) {
                    self.scannedQRs.insert(stringValue)
                    
                    // 読み取り成功🎉
                    self.playSuccessSound()
                    self.HapticSuccessNotification()
                    print("The content of QR code: \(stringValue)")
                }
            } else {
                // 読み取り成功🎉
                self.playSuccessSound()
                self.HapticSuccessNotification()
                print("The content of QR code: \(stringValue)")
            }
        }
    }
}

// MARK: AVCaptureVideoDataOutputSampleBufferDelegate
// VisionでQR検知したい場合はコメントアウトしてね
//extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
//    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//            return;
//        }
//
//        let detectRequest = VNDetectBarcodesRequest { [weak self](request, error) in
//            guard let self = self else { return }
//            guard let results = request.results as? [VNBarcodeObservation] else {
//                return
//            }
//
//            for observation in results {
//                if let payloadString = observation.payloadStringValue {
//                    if !self.scannedQRs.contains(payloadString) {
//                        print("The content of QR code: \(payloadString)")
//                        self.playSuccessSound()
//                        self.scannedQRs.insert(payloadString)
//                    }
//                }
//            }
//        }
//        detectRequest.symbologies = [VNBarcodeSymbology.qr]
//
//        do {
//            try requestHandler.perform([detectRequest], on: pixelBuffer)
//        } catch {
//            print(error.localizedDescription)
//        }
//    }
//}

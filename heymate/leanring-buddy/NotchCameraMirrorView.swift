//
//  NotchCameraMirrorView.swift
//  leanring-buddy
//
//  Opt-in, view-scoped camera mirror. Capture starts only while this card is
//  visible and stops as soon as the user leaves the Apps surface.
//

import AVFoundation
import AppKit
import Combine
import SwiftUI

private enum NotchCameraMirrorState: Equatable {
    case idle
    case requesting
    case running
    case denied
    case unavailable
    case failed(String)
}

/// Owns AVFoundation work off the main thread. SwiftUI receives only a small
/// completion value; the capture session remains the preview layer's source.
private nonisolated final class NotchCameraSessionWorker: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.heymate.notch-camera", qos: .userInitiated)
    private var isConfigured = false

    func start(completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            if !isConfigured {
                session.beginConfiguration()
                session.sessionPreset = .medium
                defer { session.commitConfiguration() }

                guard let camera = AVCaptureDevice.default(for: .video) else {
                    completion("No camera found")
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input) else {
                        completion("Camera input unavailable")
                        return
                    }
                    session.addInput(input)
                    isConfigured = true
                } catch {
                    completion(error.localizedDescription)
                    return
                }
            }

            if !session.isRunning {
                session.startRunning()
            }
            completion(session.isRunning ? nil : "Camera did not start")
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

@MainActor
private final class NotchCameraMirrorModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var state: NotchCameraMirrorState = .idle

    private let worker = NotchCameraSessionWorker()
    var session: AVCaptureSession { worker.session }

    func activate() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            state = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                Task { @MainActor in
                    if granted {
                        self.startSession()
                    } else {
                        self.state = .denied
                    }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .unavailable
        }
    }

    func deactivate() {
        worker.stop()
        if state == .running { state = .idle }
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startSession() {
        state = .requesting
        worker.start { [self] errorText in
            Task { @MainActor in
                if let errorText {
                    self.state = errorText == "No camera found" ? .unavailable : .failed(errorText)
                } else {
                    self.state = .running
                }
            }
        }
    }
}

private final class NotchCameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct NotchCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NotchCameraPreviewNSView {
        let view = NotchCameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        view.previewLayer.connection?.isVideoMirrored = true
        return view
    }

    func updateNSView(_ nsView: NotchCameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

struct NotchCameraMirrorView: View {
    @StateObject private var model = NotchCameraMirrorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            DSSectionLabel(title: "Camera mirror")

            ZStack {
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DSSurface.row.fill(isHighlighted: false))

                NotchCameraPreview(session: model.session)
                    .opacity(model.state == .running ? 1 : 0)

                if model.state != .running {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: 126, maxHeight: 146)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: placeholderSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text(placeholderText)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if model.state == .denied {
                Button("Camera Settings") { model.openCameraSettings() }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
            }
        }
        .padding(12)
    }

    private var placeholderSymbol: String {
        switch model.state {
        case .requesting: return "camera.aperture"
        case .denied: return "camera.fill.badge.xmark"
        case .unavailable, .failed: return "video.slash"
        case .idle, .running: return "camera"
        }
    }

    private var placeholderText: String {
        switch model.state {
        case .idle: return "Camera is off"
        case .requesting: return "Starting camera…"
        case .denied: return "Camera access is off"
        case .unavailable: return "No camera available"
        case .failed(let message): return message
        case .running: return ""
        }
    }
}

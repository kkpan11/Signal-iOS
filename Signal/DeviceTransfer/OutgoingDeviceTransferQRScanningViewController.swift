//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import MultipeerConnectivity
import SignalServiceKit
import SignalUI

class OutgoingDeviceTransferQRScanningViewController: DeviceTransferBaseViewController {

    private let qrCodeScanViewController = QRCodeScanViewController(appearance: .unadorned)

    lazy var activityIndicator: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = Theme.primaryIconColor
        return activityIndicator
    }()
    lazy var label: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeBody2
        label.textColor = Theme.primaryTextColor
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        return label
    }()
    lazy var hStack: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.setContentHuggingVerticalLow()
        stackView.setCompressionResistanceVerticalHigh()

        let leadingSpacer = UIView.hStretchingSpacer()
        stackView.addArrangedSubview(leadingSpacer)

        stackView.addArrangedSubview(activityIndicator)

        stackView.addArrangedSubview(label)
        label.setCompressionResistanceHorizontalHigh()
        label.setCompressionResistanceVerticalHigh()

        let trailingSpacer = UIView.hStretchingSpacer()
        stackView.addArrangedSubview(trailingSpacer)

        leadingSpacer.autoMatch(.width, to: .width, of: trailingSpacer)

        return stackView
    }()
    lazy var captureContainerView: UIView = {
        let view = UIView()

        let qrView = qrCodeScanViewController.view!
        view.addSubview(qrView)

        view.addSubview(maskingView)
        maskingView.autoPinHeightToSuperview()
        maskingView.autoHCenterInSuperview()

        qrView.autoPinEdges(toEdgesOf: maskingView)

        view.addSubview(cameraToggleButton)
        cameraToggleButton.autoSetDimensions(to: .square(32))
        cameraToggleButton.autoPinEdge(.trailing, to: .trailing, of: maskingView)
        cameraToggleButton.autoPinEdge(.bottom, to: .bottom, of: view)

        return view
    }()
    lazy var maskingView: UIView = {
        let maskingView = BezierPathView { layer, bounds in
            let path = UIBezierPath(rect: bounds)

            let circlePath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.size.height * 0.5)
            path.append(circlePath)
            path.usesEvenOddFillRule = true

            layer.path = path.cgPath
            layer.fillRule = .evenOdd
            layer.fillColor = Theme.actionSheetBackgroundColor.cgColor
        }
        maskingView.autoPinToSquareAspectRatio()
        maskingView.autoSetDimension(.height, toSize: 256)
        return maskingView
    }()

    private lazy var cameraToggleButton: UIButton = {
        let button = UIButton()
        button.setImage(UIImage(named: "switch-camera-28"), animated: false)
        button.tintColor = Theme.primaryIconColor
        button.addTarget(
            self,
            action: #selector(didTapCameraToggle),
            for: .touchUpInside
        )
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = self.titleLabel(
            text: OWSLocalizedString("DEVICE_TRANSFER_SCANNING_TITLE",
                                    comment: "The title for the action sheet asking the user to scan the QR code to transfer")
        )
        contentView.addArrangedSubview(titleLabel)

        contentView.addArrangedSubview(.spacer(withHeight: 12))

        let explanationLabel = self.explanationLabel(
            explanationText: OWSLocalizedString("DEVICE_TRANSFER_SCANNING_EXPLANATION",
                                               comment: "The explanation for the action sheet asking the user to scan the QR code to transfer")
        )
        contentView.addArrangedSubview(explanationLabel)

        let topSpacer = UIView.vStretchingSpacer()
        contentView.addArrangedSubview(topSpacer)

        contentView.addArrangedSubview(captureContainerView)
        contentView.addArrangedSubview(hStack)
        hStack.isHidden = true

        let bottomSpacer = UIView.vStretchingSpacer()
        contentView.addArrangedSubview(bottomSpacer)
        topSpacer.autoMatch(.height, to: .height, of: bottomSpacer)
        topSpacer.autoSetDimension(.height, toSize: 25, relation: .greaterThanOrEqual)

        qrCodeScanViewController.delegate = self
        addChild(qrCodeScanViewController)
    }

    @objc
    private func didTapCameraToggle() {
        qrCodeScanViewController.prefersFrontFacingCamera =
            !qrCodeScanViewController.prefersFrontFacingCamera
    }
}

// MARK: -

extension OutgoingDeviceTransferQRScanningViewController: QRCodeScanDelegate {

    func qrCodeScanViewDismiss(_ qrCodeScanViewController: QRCodeScanViewController) {
        AssertIsOnMainThread()

        navigationController?.popViewController(animated: true)
    }

    func qrCodeScanViewScanned(
        qrCodeData: Data?,
        qrCodeString: String?
    ) -> QRCodeScanOutcome {
        AssertIsOnMainThread()

        guard let qrCodeString = qrCodeString else {
            // TODO: The user has probably scanned the wrong QR code.
            // We could show an error alert to help them resolve the issue.
            // For now, ignore the QR code and continue scanning.
            owsFailDebug("QR code does not have a valid string payload.")
            return .continueScanning
        }

        guard let scannedURL = URL(string: qrCodeString) else {
            // TODO: The user has probably scanned the wrong QR code.
            // We could show an error alert to help them resolve the issue.
            // For now, ignore the QR code and continue scanning.
            owsFailDebug("QR code does not have a valid URL payload: \(qrCodeString).")
            return .continueScanning
        }

        // Ignore if a non-signal url was scanned
        guard scannedURL.scheme == UrlOpener.Constants.sgnlPrefix else {
            // TODO: The user has probably scanned the wrong QR code.
            // We could show an error alert to help them resolve the issue.
            // For now, ignore the QR code and continue scanning.
            owsFailDebug("QR code does not have a transfer URL payload: \(qrCodeString).")
            return .continueScanning
        }

        showConnecting()

        DispatchQueue.global().async {
            do {
                let (peerId, certificateHash) = try AppEnvironment.shared.deviceTransferServiceRef.parseTransferURL(scannedURL)
                AppEnvironment.shared.deviceTransferServiceRef.addObserver(self)
                try AppEnvironment.shared.deviceTransferServiceRef.transferAccountToNewDevice(with: peerId, certificateHash: certificateHash)
            } catch {
                owsFailDebug("Something went wrong \(error)")

                if let error = error as? DeviceTransferService.Error {
                    switch error {
                    case .unsupportedVersion:
                        self.showError(
                            text: OWSLocalizedString("DEVICE_TRANSFER_ERROR_UNSUPPORTED_VERSION",
                                                    comment: "An error indicating the user must update their device before trying to transfer.")
                        )
                        return
                    case .modeMismatch:
                        let desiredMode: DeviceTransferService.TransferMode =
                            DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isPrimaryDevice ?? true
                            ? .linked : .primary
                        switch desiredMode {
                        case .linked:
                            self.showError(
                                text: OWSLocalizedString("DEVICE_TRANSFER_ERROR_MODE_MISMATCH_LINKED",
                                                        comment: "An error indicating the user must scan this code with a linked device to transfer.")
                            )
                        case .primary:
                            self.showError(
                                text: OWSLocalizedString("DEVICE_TRANSFER_ERROR_MODE_MISMATCH_PRIMARY",
                                                        comment: "An error indicating the user must scan this code with a primary device to transfer.")
                            )
                        }
                        return
                    default:
                        break
                    }
                }

                self.showError(
                    text: OWSLocalizedString("DEVICE_TRANSFER_ERROR_GENERIC",
                                            comment: "An error indicating that something went wrong with the transfer and it could not complete")
                )
            }
        }

        return .stopScanning
    }

    func showConnecting() {
        captureContainerView.isHidden = true
        hStack.isHidden = false
        label.text = OWSLocalizedString("DEVICE_TRANSFER_SCANNING_CONNECTING",
                                       comment: "Text indicating that we are connecting to the scanned device")
        label.textColor = Theme.primaryTextColor
        activityIndicator.isHidden = false
        activityIndicator.startAnimating()
    }

    func showError(text: String) {
        DispatchMainThreadSafe {
            self.captureContainerView.isHidden = true
            self.hStack.isHidden = false
            self.label.text = text
            self.label.textColor = .ows_accentRed
            self.activityIndicator.stopAnimating()
            self.activityIndicator.isHidden = true
        }
    }
}

// MARK: -

extension OutgoingDeviceTransferQRScanningViewController: DeviceTransferServiceObserver {
    func deviceTransferServiceDiscoveredNewDevice(peerId: MCPeerID, discoveryInfo: [String: String]?) {}

    func deviceTransferServiceDidStartTransfer(progress: Progress) {
        AppEnvironment.shared.deviceTransferServiceRef.removeObserver(self)
        let vc = OutgoingDeviceTransferProgressViewController(progress: progress)
        navigationController?.pushViewController(vc, animated: true)
    }

    func deviceTransferServiceDidEndTransfer(error: DeviceTransferService.Error?) {
        if error != nil {
            showError(
                text: OWSLocalizedString("DEVICE_TRANSFER_ERROR_GENERIC",
                                        comment: "An error indicating that something went wrong with the transfer and it could not complete")
            )
        }
    }

    func deviceTransferServiceDidRequestAppRelaunch() {
        owsFail("Relaunch not supported for outgoing transfer; only on the receiving device during transfer")
    }
}

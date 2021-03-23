//
//  ConnectViewController.swift
//  MullvadVPN
//
//  Created by pronebird on 20/03/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import UIKit
import NetworkExtension
import Logging

class ConnectViewController: UIViewController, RootContainment, TunnelObserver
{
    private var relayConstraints: RelayConstraints?

    private lazy var mainContentView: ConnectMainContentView = {
        let view = ConnectMainContentView(frame: UIScreen.main.bounds)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var sidebarLocationController: SelectLocationViewController = {
        let contentController = SelectLocationViewController()
        contentController.scrollToSelectedRelayOnViewWillAppear = false
        contentController.didSelectRelayLocation = { [weak self] (controller, relayLocation) in
            self?.selectLocationControllerDidSelectRelayLocation(relayLocation)
        }

        return contentController
    }()
    private var sidebarViewWidthConstraint: NSLayoutConstraint?

    private let logger = Logger(label: "ConnectViewController")
    private let alertPresenter = AlertPresenter()

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    var preferredHeaderBarStyle: HeaderBarStyle {
        switch tunnelState {
        case .connecting, .reconnecting, .connected:
            return .secured

        case .disconnecting, .disconnected:
            return .unsecured
        }
    }

    var prefersHeaderBarHidden: Bool {
        return false
    }

    private var tunnelState: TunnelState = .disconnected {
        didSet {
            setNeedsHeaderBarStyleAppearanceUpdate()
            updateTunnelConnectionInfo()
            updateUserInterfaceForTunnelStateChange()
        }
    }

    private var showedAccountView = false

    override func viewDidLoad() {
        super.viewDidLoad()

        mainContentView.connectionPanel.collapseButton.addTarget(self, action: #selector(handleConnectionPanelButton(_:)), for: .touchUpInside)
        mainContentView.connectButton.addTarget(self, action: #selector(handleConnect(_:)), for: .touchUpInside)
        mainContentView.splitDisconnectButton.primaryButton.addTarget(self, action: #selector(handleDisconnect(_:)), for: .touchUpInside)
        mainContentView.splitDisconnectButton.secondaryButton.addTarget(self, action: #selector(handleReconnect(_:)), for: .touchUpInside)

        mainContentView.selectLocationButton.addTarget(self, action: #selector(handleSelectLocation(_:)), for: .touchUpInside)

        TunnelManager.shared.addObserver(self)
        self.tunnelState = TunnelManager.shared.tunnelState

        switch traitCollection.userInterfaceIdiom {
        case .pad:
            setupSplitViewLayout()

        case .phone:
            setupSingleViewLayout()

        default:
            break
        }

        fetchRelayConstraints { (relayConstraints) in
            if case .pad = self.traitCollection.userInterfaceIdiom {
                self.sidebarLocationController.prefetchData(completionHandler: { (error) in
                    if let error = error {
                        self.logger.error(chainedError: error, message: "Failed to prefetch data for SelectLocationViewController (sidebar)")
                    }
                    self.sidebarLocationController.setSelectedRelayLocation(
                        relayConstraints?.location.value, animated: false, scrollPosition: .middle)
                })
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if case .pad = traitCollection.userInterfaceIdiom {
            sidebarViewWidthConstraint?.constant = preferredWidthForSidebarView(viewSize: size)
            coordinator.animate { (context) in
                self.view.layoutSubviews()
            }
        }
    }

    private func fetchRelayConstraints(completion: @escaping (RelayConstraints?) -> Void) {
        TunnelManager.shared.getRelayConstraints { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success(let relayConstraints):
                    self.relayConstraints = relayConstraints
                    completion(relayConstraints)

                case .failure(let error):
                    self.logger.error(chainedError: error)
                    completion(nil)
                }
            }
        }
    }

    private func selectLocationControllerDidSelectRelayLocation(_ relayLocation: RelayLocation) {
        let relayConstraints = makeRelayConstraints(relayLocation)

        self.setTunnelRelayConstraints(relayConstraints)
        self.relayConstraints = relayConstraints
    }

    private func preferredWidthForSidebarView(viewSize: CGSize) -> CGFloat {
        return max(300, viewSize.width * 0.3)
    }

    private func setupSingleViewLayout() {
        view.addSubview(mainContentView)
        NSLayoutConstraint.activate([
            mainContentView.topAnchor.constraint(equalTo: view.topAnchor),
            mainContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSplitViewLayout() {
        let columnLayoutStackView = UIStackView()
        columnLayoutStackView.spacing = 0
        columnLayoutStackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(columnLayoutStackView)
        NSLayoutConstraint.activate([
            columnLayoutStackView.topAnchor.constraint(equalTo: view.topAnchor),
            columnLayoutStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columnLayoutStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columnLayoutStackView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let separatorView = UIView()
        separatorView.backgroundColor = UIColor.MainSplitView.columnSeparatorColor
        separatorView.widthAnchor.constraint(equalToConstant: 1).isActive = true
        columnLayoutStackView.addArrangedSubview(mainContentView)
        columnLayoutStackView.addArrangedSubview(separatorView)

        addChild(sidebarLocationController)
        sidebarLocationController.view.translatesAutoresizingMaskIntoConstraints = false

        columnLayoutStackView.addArrangedSubview(sidebarLocationController.view)
        sidebarLocationController.didMove(toParent: self)

        sidebarViewWidthConstraint = sidebarLocationController.view.widthAnchor
            .constraint(equalToConstant: preferredWidthForSidebarView(viewSize: view.frame.size))
        sidebarViewWidthConstraint?.isActive = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        showAccountViewForExpiredAccount()
    }

    // MARK: - TunnelObserver

    func tunnelStateDidChange(tunnelState: TunnelState) {
        DispatchQueue.main.async {
            self.tunnelState = tunnelState
        }
    }

    func tunnelPublicKeyDidChange(publicKeyWithMetadata: PublicKeyWithMetadata?) {
        // no-op
    }

    // MARK: - Private

    private func makeRelayConstraints(_ location: RelayLocation) -> RelayConstraints {
        return RelayConstraints(location: .only(location))
    }

    private func setTunnelRelayConstraints(_ relayConstraints: RelayConstraints) {
        TunnelManager.shared.setRelayConstraints(relayConstraints) { [weak self] (result) in
            guard let self = self else { return }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.logger.debug("Updated relay constraints: \(relayConstraints)")
                    self.connectTunnel()

                case .failure(let error):
                    self.logger.error(chainedError: error, message: "Failed to update relay constraints")
                }
            }
        }
    }

    private func updateUserInterfaceForTunnelStateChange() {
        mainContentView.secureLabel.text = tunnelState.localizedTitleForSecureLabel.uppercased()
        mainContentView.secureLabel.textColor = tunnelState.textColorForSecureLabel

        mainContentView.connectButton.setTitle(tunnelState.localizedTitleForConnectButton, for: .normal)
        mainContentView.selectLocationButton.setTitle(tunnelState.localizedTitleForSelectLocationButton, for: .normal)
        mainContentView.splitDisconnectButton.primaryButton.setTitle(tunnelState.localizedTitleForDisconnectButton, for: .normal)
        mainContentView.setActionButtons(tunnelState.actionButtons)
    }

    private func attributedStringForLocation(string: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineHeightMultiple = 0.80
        return NSAttributedString(string: string, attributes: [
            .paragraphStyle: paragraphStyle])
    }

    private func updateTunnelConnectionInfo() {
        switch tunnelState {
        case .connected(let connectionInfo),
             .reconnecting(let connectionInfo):
            mainContentView.cityLabel.attributedText = attributedStringForLocation(string: connectionInfo.location.city)
            mainContentView.countryLabel.attributedText = attributedStringForLocation(string: connectionInfo.location.country)

            mainContentView.connectionPanel.dataSource = ConnectionPanelData(
                inAddress: "\(connectionInfo.ipv4Relay) UDP",
                outAddress: nil
            )
            mainContentView.connectionPanel.isHidden = false
            mainContentView.connectionPanel.collapseButton.setTitle(connectionInfo.hostname, for: .normal)

        case .connecting, .disconnected, .disconnecting:
            mainContentView.cityLabel.attributedText = attributedStringForLocation(string: " ")
            mainContentView.countryLabel.attributedText = attributedStringForLocation(string: " ")
            mainContentView.connectionPanel.dataSource = nil
            mainContentView.connectionPanel.isHidden = true
        }
    }

    private func connectTunnel() {
        TunnelManager.shared.startTunnel { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    break

                case .failure(let error):
                    self.logger.error(chainedError: error, message: "Failed to start the VPN tunnel")

                    let alertController = UIAlertController(
                        title: NSLocalizedString("Failed to start the VPN tunnel", comment: ""),
                        message: error.errorChainDescription,
                        preferredStyle: .alert
                    )
                    alertController.addAction(
                        UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel)
                    )

                    self.alertPresenter.enqueue(alertController, presentingController: self)
                }
            }
        }
    }

    private func disconnectTunnel() {
        TunnelManager.shared.stopTunnel { (result) in
            if case .failure(let error) = result {
                self.logger.error(chainedError: error, message: "Failed to stop the VPN tunnel")

                let alertController = UIAlertController(
                    title: NSLocalizedString("Failed to stop the VPN tunnel", comment: ""),
                    message: error.errorChainDescription,
                    preferredStyle: .alert
                )
                alertController.addAction(
                    UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel)
                )

                self.alertPresenter.enqueue(alertController, presentingController: self)
            }
        }
    }

    private func reconnectTunnel() {
        TunnelManager.shared.reconnectTunnel(completionHandler: nil)
    }

    private func showAccountViewForExpiredAccount() {
        guard !showedAccountView else { return }

        showedAccountView = true

        if let accountExpiry = Account.shared.expiry, AccountExpiry(date: accountExpiry).isExpired {
            rootContainerController?.showSettings(navigateTo: .account, animated: true)
        }
    }

    private func showSelectLocationModal() {
        let contentController = SelectLocationViewController()
        contentController.navigationItem.title = NSLocalizedString("Select location", comment: "Navigation title")
        contentController.navigationItem.largeTitleDisplayMode = .never
        contentController.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(handleDismissSelectLocationController(_:)))

        contentController.didSelectRelayLocation = { [weak self] (controller, relayLocation) in
            controller.view.isUserInteractionEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                controller.view.isUserInteractionEnabled = true
                controller.dismiss(animated: true) {
                    self?.selectLocationControllerDidSelectRelayLocation(relayLocation)
                }
            }
        }

        let navController = SelectLocationNavigationController(contentController: contentController)

        view.isUserInteractionEnabled = false
        contentController.setSelectedRelayLocation(self.relayConstraints?.location.value, animated: false, scrollPosition: .none)
        contentController.prefetchData { (error) in
            if let error = error {
                self.logger.error(chainedError: error, message: "Failed to prefetch the relays for SelectLocationViewController")
            }

            self.present(navController, animated: true) {
                self.view.isUserInteractionEnabled = true
            }
        }
    }

    // MARK: - Actions

    @objc func handleConnectionPanelButton(_ sender: Any) {
        mainContentView.connectionPanel.toggleConnectionInfoVisibility()
    }

    @objc func handleConnect(_ sender: Any) {
        connectTunnel()
    }

    @objc func handleDisconnect(_ sender: Any) {
        disconnectTunnel()
    }

    @objc func handleReconnect(_ sender: Any) {
        reconnectTunnel()
    }

    @objc func handleSelectLocation(_ sender: Any) {
        showSelectLocationModal()
    }

    @objc func handleDismissSelectLocationController(_ sender: Any) {
        self.presentedViewController?.dismiss(animated: true)
    }

}

private extension TunnelState {

    var textColorForSecureLabel: UIColor {
        switch self {
        case .connecting, .reconnecting:
            return .white

        case .connected:
            return .successColor

        case .disconnecting, .disconnected:
            return .dangerColor
        }
    }

    var localizedTitleForSecureLabel: String {
        switch self {
        case .connecting, .reconnecting:
            return NSLocalizedString("Creating secure connection", comment: "")

        case .connected:
            return NSLocalizedString("Secure connection", comment: "")

        case .disconnecting, .disconnected:
            return NSLocalizedString("Unsecured connection", comment: "")
        }
    }

    var localizedTitleForSelectLocationButton: String? {
        switch self {
        case .disconnected, .disconnecting:
            return NSLocalizedString("Select location", comment: "")
        case .connecting, .connected, .reconnecting:
            return NSLocalizedString("Switch location", comment: "")
        }
    }

    var localizedTitleForConnectButton: String? {
        return NSLocalizedString("Secure connection", comment: "")
    }

    var localizedTitleForDisconnectButton: String? {
        switch self {
        case .connecting:
            return NSLocalizedString("Cancel", comment: "")
        case .connected, .reconnecting:
            return NSLocalizedString("Disconnect", comment: "")
        case .disconnecting, .disconnected:
            return nil
        }
    }

    var actionButtons: [ConnectMainContentView.ActionButton] {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            switch self {
            case .disconnected, .disconnecting:
                return [.selectLocation, .connect]

            case .connecting, .connected, .reconnecting:
                return [.selectLocation, .disconnect]
            }

        case .pad:
            switch self {
            case .disconnected, .disconnecting:
                return [.connect]

            case .connecting, .connected, .reconnecting:
                return [.disconnect]
            }

        default:
            fatalError("Not supported")
        }
    }

}

//
//  ConnectViewController.swift
//  MullvadVPN
//
//  Created by pronebird on 20/03/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import UIKit
import MapKit
import NetworkExtension
import Logging

class CustomOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let drawRect = self.rect(for: mapRect)
        context.setFillColor(UIColor.secondaryColor.cgColor)
        context.fill(drawRect)
    }
}

class ConnectViewController: UIViewController, RootContainment, TunnelObserver, MKMapViewDelegate
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

    private var lastLocation: CLLocationCoordinate2D?
    private let locationMarker = MKPointAnnotation()

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

            // Avoid unnecessary animations, particularly when this property is changed from inside
            // the `viewDidLoad`.
            let isViewVisible = self.viewIfLoaded?.window != nil

            updateLocation(animated: isViewVisible)
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

        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            setupSplitViewLayout()

        case .phone:
            setupSingleViewLayout()

        default:
            break
        }

        setupMapView()
        updateLocation(animated: false)

        fetchRelayConstraints { (relayConstraints) in
            if case .pad = UIDevice.current.userInterfaceIdiom {
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

        if case .pad = UIDevice.current.userInterfaceIdiom {
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

    private func locationMarkerOffset() -> CGPoint {
        // The spacing between the secure label and the marker
        let markerSecureLabelSpacing = CGFloat(22)

        // Compute the secure label's frame within the view coordinate system
        let secureLabelFrame = mainContentView.secureLabel.convert(mainContentView.secureLabel.bounds, to: view)

        // The marker's center coincides with the geo coordinate
        let markerAnchorOffsetInPoints = locationMarkerSecureImage.size.height * 0.5

        // Compute the distance from the top of the label's frame to the center of the map
        let secureLabelDistanceToMapCenterY = secureLabelFrame.minY - mainContentView.mapView.frame.midY

        // Compute the marker offset needed to position it above the secure label
        let offsetY = secureLabelDistanceToMapCenterY - markerAnchorOffsetInPoints - markerSecureLabelSpacing

        return CGPoint(x: 0, y: offsetY)
    }

    private func computeCoordinateRegion(centerCoordinate: CLLocationCoordinate2D, centerOffsetInPoints: CGPoint) -> MKCoordinateRegion  {
        let span = MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
        var region = MKCoordinateRegion(center: centerCoordinate, span: span)
        region = mainContentView.mapView.regionThatFits(region)

        let latitudeDeltaPerPoint = region.span.latitudeDelta / Double(mainContentView.mapView.frame.height)
        var offsetCenter = centerCoordinate
        offsetCenter.latitude += CLLocationDegrees(latitudeDeltaPerPoint * Double(centerOffsetInPoints.y))
        region.center = offsetCenter

        return region
    }

    private func updateLocation(animated: Bool) {
        switch tunnelState {
        case .connected(let connectionInfo),
             .reconnecting(let connectionInfo):
            let coordinate = connectionInfo.location.geoCoordinate
            if let lastLocation = self.lastLocation, coordinate.approximatelyEqualTo(lastLocation) {
                return
            }

            let markerOffset = locationMarkerOffset()
            let region = computeCoordinateRegion(centerCoordinate: coordinate, centerOffsetInPoints: markerOffset)

            locationMarker.coordinate = coordinate
            mainContentView.mapView.addAnnotation(locationMarker)
            mainContentView.mapView.setRegion(region, animated: animated)

            self.lastLocation = coordinate

        case .disconnected, .disconnecting:
            let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            if let lastLocation = self.lastLocation, coordinate.approximatelyEqualTo(lastLocation) {
                return
            }

            let span = MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
            let region = MKCoordinateRegion(center: coordinate, span: span)
            mainContentView.mapView.removeAnnotation(locationMarker)
            mainContentView.mapView.setRegion(region, animated: animated)

            self.lastLocation = coordinate

        case .connecting:
            break
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

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = UIColor.primaryColor
            renderer.strokeColor = UIColor.secondaryColor
            renderer.lineWidth = 1.0
            renderer.lineCap = .round
            renderer.lineJoin = .round

            return renderer
        }

        if #available(iOS 13, *) {
            if let multiPolygon = overlay as? MKMultiPolygon {
                let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
                renderer.fillColor = UIColor.primaryColor
                renderer.strokeColor = UIColor.secondaryColor
                renderer.lineWidth = 1.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
        }

        if let tileOverlay = overlay as? MKTileOverlay {
            return CustomOverlayRenderer(overlay: tileOverlay)
        }

        fatalError()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === locationMarker {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "location", for: annotation)
            view.isDraggable = false
            view.canShowCallout = false
            view.image = self.locationMarkerSecureImage
            return view
        }
        return nil
    }

    // MARK: - Private

    private var locationMarkerSecureImage: UIImage {
        return UIImage(named: "LocationMarkerSecure")!
    }

    private func setupMapView() {
        mainContentView.mapView.insetsLayoutMarginsFromSafeArea = false
        mainContentView.mapView.delegate = self
        mainContentView.mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "location")

        if #available(iOS 13.0, *) {
            // Use dark style for the map to dim the map grid
            mainContentView.mapView.overrideUserInterfaceStyle = .dark
        }

        addTileOverlay()
        loadGeoJSONData()
        hideMapsAttributions()
    }

    private func addTileOverlay() {
        // Use `nil` for template URL to make sure that Apple maps do not load
        // tiles from remote.
        let tileOverlay = MKTileOverlay(urlTemplate: nil)

        // Replace the default map tiles
        tileOverlay.canReplaceMapContent = true

        mainContentView.mapView.addOverlay(tileOverlay)
    }

    private func loadGeoJSONData() {
        let fileURL = Bundle.main.url(forResource: "countries.geo", withExtension: "json")!
        let data = try! Data(contentsOf: fileURL)

        let overlays = try! GeoJSON.decodeGeoJSON(data)
        mainContentView.mapView.addOverlays(overlays, level: .aboveLabels)
    }

    private func hideMapsAttributions() {
        for subview in mainContentView.mapView.subviews {
            if subview.description.starts(with: "<MKAttributionLabel") {
                subview.isHidden = true
            }
        }
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

extension CLLocationCoordinate2D {
    func approximatelyEqualTo(_ other: CLLocationCoordinate2D) -> Bool {
        return fabs(self.latitude - other.latitude) <= .ulpOfOne &&
            fabs(self.longitude - other.longitude) <= .ulpOfOne
    }
}

extension MKCoordinateRegion {
    var mapRect: MKMapRect {
        let topLeft = CLLocationCoordinate2D(latitude: self.center.latitude + (self.span.latitudeDelta/2), longitude: self.center.longitude - (self.span.longitudeDelta/2))
        let bottomRight = CLLocationCoordinate2D(latitude: self.center.latitude - (self.span.latitudeDelta/2), longitude: self.center.longitude + (self.span.longitudeDelta/2))

        let a = MKMapPoint(topLeft)
        let b = MKMapPoint(bottomRight)

        return MKMapRect(x: min(a.x, b.x),
                         y: min(a.y, b.y),
                         width: abs(a.x - b.x),
                         height: abs(a.y - b.y)
        )
    }
}

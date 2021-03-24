//
//  AutomaticKeyboardResponder.swift
//  MullvadVPN
//
//  Created by pronebird on 24/03/2021.
//  Copyright © 2021 Mullvad VPN AB. All rights reserved.
//

import UIKit

class AutomaticKeyboardResponder {
    weak var targetView: UIView?
    private let handler: (UIView, CGFloat) -> Void

    private var previousAdjustment: CGFloat = 0
    private var lastKeyboardRect: CGRect?

    init<T: UIView>(targetView: T, handler: @escaping (T, CGFloat) -> Void) {
        self.targetView = targetView
        self.handler = { (view, adjustment) in
            handler(view as! T, adjustment)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboard(_:)), name: UIWindow.keyboardWillChangeFrameNotification, object: nil)

        // Add didShow observer for keyboard because on iPad the sheet presentation may move the view controller
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboard(_:)), name: UIWindow.keyboardDidShowNotification, object: nil)
    }

    @objc private func handleKeyboard(_ notification: Notification) {
        guard let keyboardFrameValue = notification.userInfo?[UIWindow.keyboardFrameEndUserInfoKey] as? NSValue else { return }

        lastKeyboardRect = keyboardFrameValue.cgRectValue

        adjustContentInsets(keyboardRect: keyboardFrameValue.cgRectValue)
    }

    func updateContentInsets() {
        guard let keyboardRect = lastKeyboardRect else { return }

        adjustContentInsets(keyboardRect: keyboardRect)
    }

    private func adjustContentInsets(keyboardRect: CGRect) {
        guard let targetView = targetView, let superview = targetView.superview else { return }

        let screenRect = superview.convert(targetView.frame, to: nil)
        let intersection = keyboardRect.intersection(screenRect)

        if previousAdjustment != intersection.height {
            previousAdjustment = intersection.height
            handler(targetView, intersection.height)
        }
    }
}

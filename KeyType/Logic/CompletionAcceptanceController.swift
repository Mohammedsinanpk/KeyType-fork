//
//  CompletionAcceptanceController.swift
//  KeyType
//
//  Global acceptance hotkeys (M6 / ADR-016). A session-level CGEvent tap consumes the configured
//  accept keys only while a completion is visible and the app's CompletionPolicy allows Tab
//  acceptance; otherwise every key passes straight through so native behaviour is untouched.
//
//  The accept-word and accept-full hotkeys are user-configurable (SettingsStore); they default to
//  Tab and Shift+Tab respectively.
//

import AppKit
import CoreGraphics
import os

@MainActor
final class CompletionAcceptanceController {
    weak var completionController: CompletionController?
    /// Source of the configurable acceptance hotkeys. Read on every matching key-down.
    weak var settings: SettingsStore?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "acceptance")

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CompletionAcceptanceController>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    controller.process(type: type, event: event)
                }
            },
            userInfo: refcon
        ) else {
            log.error("Failed to create Tab event tap (Accessibility not granted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        log.debug("Tab acceptance tap installed")
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    /// Decide whether to consume (return nil) or pass through (return the event). Runs on the main
    /// run loop, so `MainActor.assumeIsolated` at the call site is valid.
    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that times out or is interrupted; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let acceptWord = settings?.acceptWordShortcut ?? .defaultAcceptWord
        let acceptFull = settings?.acceptFullShortcut ?? .defaultAcceptFull

        // Match the full-acceptance hotkey first: it is typically the same key as accept-word plus a
        // modifier (Shift+Tab vs Tab), so checking the more specific binding first is required.
        let matchesFull = acceptFull.matches(keyCode: keyCode, flags: flags)
        let matchesWord = acceptWord.matches(keyCode: keyCode, flags: flags)
        guard matchesFull || matchesWord else {
            return Unmanaged.passUnretained(event)
        }

        guard let controller = completionController, controller.canAcceptCompletion else {
            return Unmanaged.passUnretained(event) // nothing to accept → native key behaviour
        }

        if matchesFull {
            controller.acceptFullCompletion()
        } else {
            controller.acceptNextWord()
        }
        return nil // consume — the key accepted the completion instead of its native action
    }
}

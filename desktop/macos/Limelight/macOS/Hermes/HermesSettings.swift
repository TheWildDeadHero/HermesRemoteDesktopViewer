//
//  HermesSettings.swift
//  Hermes for macOS
//
//  App-wide remote-desktop preferences. These live alongside (not inside) the
//  per-host Moonlight profile so upstream settings keep decoding unchanged.
//

import Cocoa
import AVFoundation

/// How the Mac's pointer drives the remote computer.
@objc enum HermesPointerMode: Int {
    /// Chrome Remote Desktop style: the pointer moves freely and lands exactly where
    /// you point. Nothing is captured.
    case desktop = 0
    /// Moonlight's original behaviour: the pointer is captured and sends relative
    /// motion (best for games). Release with Control-Option.
    case captured = 1
}

/// How the remote picture fits the window.
@objc enum HermesScaleMode: Int {
    case fit = 0
    case fill = 1
    case stretch = 2
}

@objc(HermesSettings)
final class HermesSettings: NSObject {
    static let matchDisplayKey = "hermes.matchDisplay"
    static let virtualDisplayKey = "hermes.virtualDisplay"
    static let hostScalingKey = "hermes.hostScaling"
    static let pointerModeKey = "hermes.pointerMode"
    static let scaleModeKey = "hermes.scaleMode"
    static let showSessionHandleKey = "hermes.showSessionHandle"

    /// Posted (on the main thread) when the picture scale mode changes mid-stream.
    @objc static let scaleModeDidChangeNotification = Notification.Name("HermesScaleModeDidChange")

    /// 0 means "match this Mac" (use the display's backing scale); otherwise a percentage.
    static let hostScalingChoices: [Int] = [0, 100, 125, 150, 175, 200, 250, 300]

    private static var defaults: UserDefaults { .standard }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// Stream at this Mac's own display resolution instead of a fixed preset.
    @objc static var matchDisplay: Bool {
        get { bool(matchDisplayKey, default: true) }
        set { defaults.set(newValue, forKey: matchDisplayKey) }
    }

    /// Ask Apollo for a virtual display sized to the stream.
    @objc static var useVirtualDisplay: Bool {
        get { bool(virtualDisplayKey, default: true) }
        set { defaults.set(newValue, forKey: virtualDisplayKey) }
    }

    @objc static var showSessionHandle: Bool {
        get { bool(showSessionHandleKey, default: true) }
        set { defaults.set(newValue, forKey: showSessionHandleKey) }
    }

    @objc static var hostScaling: Int {
        get { defaults.object(forKey: hostScalingKey) == nil ? 0 : defaults.integer(forKey: hostScalingKey) }
        set { defaults.set(newValue, forKey: hostScalingKey) }
    }

    @objc static var pointerMode: HermesPointerMode {
        get { HermesPointerMode(rawValue: defaults.integer(forKey: pointerModeKey)) ?? .desktop }
        set { defaults.set(newValue.rawValue, forKey: pointerModeKey) }
    }

    @objc static var scaleMode: HermesScaleMode {
        get { HermesScaleMode(rawValue: defaults.integer(forKey: scaleModeKey)) ?? .fit }
        set {
            defaults.set(newValue.rawValue, forKey: scaleModeKey)
            NotificationCenter.default.post(name: scaleModeDidChangeNotification, object: nil)
        }
    }

    /// AVLayerVideoGravity string for the current scale mode (used by the renderer).
    @objc static var videoGravity: String {
        switch scaleMode {
        case .fit: return AVLayerVideoGravity.resizeAspect.rawValue
        case .fill: return AVLayerVideoGravity.resizeAspectFill.rawValue
        case .stretch: return AVLayerVideoGravity.resize.rawValue
        }
    }

    /// The screen a new stream will most likely appear on.
    @objc(preferredScreen) static func preferredScreen() -> NSScreen? {
        NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
    }

    /// Display scale percent to request from Apollo for its virtual display.
    @objc(hostScaleFactorForScreen:) static func hostScaleFactor(for screen: NSScreen?) -> Int32 {
        let choice = hostScaling
        if choice > 0 {
            return Int32(choice)
        }
        let backing = screen?.backingScaleFactor ?? 2
        return Int32((backing * 100).rounded())
    }

    /// Pixel size of `screen`, minus the camera housing on notched MacBooks, clamped to what
    /// the chosen codec can encode, with even dimensions.
    @objc(displayResolutionForScreen:allowHevc:) static func displayResolution(for screen: NSScreen?, allowHevc: Bool) -> CGSize {
        guard let screen = screen else {
            return CGSize(width: 1920, height: 1080)
        }
        let scale = screen.backingScaleFactor
        var points = screen.frame.size
        if #available(macOS 12.0, *) {
            points.height -= screen.safeAreaInsets.top
        }
        var width = points.width * scale
        var height = points.height * scale

        // H.264 hardware encoders top out at 4096 pixels wide; HEVC handles 8K.
        let maxWidth: CGFloat = allowHevc ? 7680 : 4096
        let maxHeight: CGFloat = allowHevc ? 4320 : 2304
        let fit = min(1, maxWidth / width, maxHeight / height)
        width *= fit
        height *= fit

        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v) & ~1) }
        return CGSize(width: max(640, even(width)), height: max(360, even(height)))
    }
}

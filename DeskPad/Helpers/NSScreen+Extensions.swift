import Foundation

extension NSScreen {
    var displayID: CGDirectDisplayID {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as! CGDirectDisplayID
    }

    var pixelSize: CGSize {
        return CGSize(
            width: (frame.width * backingScaleFactor).rounded(),
            height: (frame.height * backingScaleFactor).rounded()
        )
    }

    static var builtIn: NSScreen? {
        return screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
    }
}

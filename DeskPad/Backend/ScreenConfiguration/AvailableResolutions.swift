import Foundation

struct AvailableResolution {
    let label: String
    let size: CGSize
}

let availableResolutions: [AvailableResolution] = [
    // 32:9
    AvailableResolution(label: "5120 × 1440", size: CGSize(width: 5120, height: 1440)),
    // 21:9 (239:100, 12:5)
    AvailableResolution(label: "5120 × 2160", size: CGSize(width: 5120, height: 2160)),
    AvailableResolution(label: "3840 × 1600", size: CGSize(width: 3840, height: 1600)),
    AvailableResolution(label: "3440 × 1440", size: CGSize(width: 3440, height: 1440)),
    // 16:9
    AvailableResolution(label: "3840 × 2160", size: CGSize(width: 3840, height: 2160)),
    AvailableResolution(label: "2560 × 1440", size: CGSize(width: 2560, height: 1440)),
    AvailableResolution(label: "1920 × 1080", size: CGSize(width: 1920, height: 1080)),
    AvailableResolution(label: "1600 × 900", size: CGSize(width: 1600, height: 900)),
    AvailableResolution(label: "1366 × 768", size: CGSize(width: 1366, height: 768)),
    AvailableResolution(label: "1280 × 720", size: CGSize(width: 1280, height: 720)),
    // 16:10
    AvailableResolution(label: "2560 × 1600", size: CGSize(width: 2560, height: 1600)),
    AvailableResolution(label: "1920 × 1200", size: CGSize(width: 1920, height: 1200)),
    AvailableResolution(label: "1680 × 1050", size: CGSize(width: 1680, height: 1050)),
    AvailableResolution(label: "1440 × 900", size: CGSize(width: 1440, height: 900)),
    AvailableResolution(label: "1280 × 800", size: CGSize(width: 1280, height: 800)),
]

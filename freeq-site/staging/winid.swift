// List on-screen windows of the app named in argv[1]: "<CGWindowID>\t<WxH>\t<title>"
// Used by stage.sh to feed `screencapture -l<id>`. Requires Screen Recording
// permission (same one screencapture itself needs).
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == target || target.isEmpty else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 0 else { continue }  // real windows only, not menubar items
    let name = w[kCGWindowName as String] as? String ?? ""
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.intValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.intValue ?? 0
    print("\(num)\t\(owner)\t\(width)x\(height)\t\(name)")
}

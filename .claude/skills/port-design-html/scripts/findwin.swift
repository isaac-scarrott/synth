// PID -> CGWindowID. Prints the on-screen window number(s) owned by the given PID,
// so a specific Synth instance can be screenshotted even when occluded by other
// agents' windows. Usage: swift findwin.swift <pid>
import CoreGraphics
import Foundation

let target = Int(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list where (w["kCGWindowOwnerPID"] as? Int == target) {
    if let n = w["kCGWindowNumber"] as? Int { print(n) }
}

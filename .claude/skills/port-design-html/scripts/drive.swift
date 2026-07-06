// Drive a specific Synth instance by posting CGEvents straight to its PID — works
// regardless of focus / lock screen, and never steals input from another agent's
// instance (osascript `frontmost` targets the wrong same-named process). Mouse
// clicks do NOT land on inactive windows, so drive the keyboard-first UI by keys.
//
// Usage:
//   swift drive.swift <pid> key <keycode> [cmd|ctrl|shift|opt]...
//   swift drive.swift <pid> type <text...>
//
// Handy key codes: 36 Return · 53 Esc · 49 Space · 51 Delete
//   123 ← · 124 → · 125 ↓ · 126 ↑ · 40 k · 45 n
// Examples: `drive 4210 key 40 cmd` (⌘K) · `drive 4210 type feat/login` · `drive 4210 key 36`
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: drive <pid> key <code> [mods]... | type <text>\n".utf8))
    exit(2)
}

func flags(_ names: ArraySlice<String>) -> CGEventFlags {
    var f = CGEventFlags()
    for n in names {
        switch n {
        case "cmd":        f.insert(.maskCommand)
        case "ctrl":       f.insert(.maskControl)
        case "shift":      f.insert(.maskShift)
        case "opt", "alt": f.insert(.maskAlternate)
        default: break
        }
    }
    return f
}

let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?, _ f: CGEventFlags = []) { e?.flags = f; e?.postToPid(pid) }

switch args[2] {
case "key":
    guard args.count >= 4, let code = UInt16(args[3]) else { exit(2) }
    let f = flags(args[4...])
    post(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true), f)
    post(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false), f)
case "type":
    for scalar in args[3...].joined(separator: " ").unicodeScalars where scalar.value <= 0xFFFF {
        var u = UniChar(scalar.value)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        up?.postToPid(pid)
    }
default:
    exit(2)
}

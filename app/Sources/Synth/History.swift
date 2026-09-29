import Foundation
import Observation

/// Somewhere the content pane can be — what back and forward walk between.
enum Place: Equatable {
    case session(UUID)
    case settings
    case usage
    case routines
}

/// Vim's jumplist over places: ⌃O walks back, ⌃I forward. A place appears in it once, at the
/// spot you last left it, so bouncing between two sessions never buries a third under copies.
/// Going somewhere new drops the forward half, as a browser does.
struct PlaceHistory {
    static let limit = 100

    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []
    /// Where the history believes you are. Only a real place: the setup skeleton and an empty
    /// pane are not destinations, so leaving them never records them.
    private(set) var current: Place?

    mutating func arrive(at place: Place) {
        guard place != current else { return }
        if let current {
            back.removeAll { $0 == current }
            back.append(current)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        }
        forward.removeAll()
        current = place
    }

    /// Step one place back (`direction` -1) or forward (+1), skipping anything `reachable`
    /// refuses — a closed session stays in the list until it is stepped over, then it is gone.
    mutating func step(_ direction: Int, reachable: (Place) -> Bool) -> Place? {
        while let next = direction < 0 ? back.popLast() : forward.popLast() {
            guard reachable(next), next != current else { continue }
            if let current {
                if direction < 0 { forward.append(current) } else { back.append(current) }
            }
            current = next
            return next
        }
        return nil
    }

    /// The place actually shown after a step — opening a session can land somewhere adjacent.
    mutating func settle(at place: Place?) {
        if let place { current = place }
    }
}

extension AppStore {
    /// The one place the content pane is showing, if it is showing a place at all.
    var currentPlace: Place? {
        if routinesOpen { return .routines }
        if usageOpen { return .usage }
        if settingsOpen { return .settings }
        return openSessionID.map(Place.session)
    }

    /// Records every move, whichever of the many open/enter paths made it. Observing the one
    /// derived value is the seam: a new way to open something is in history without touching
    /// it, and the intermediate states inside one `open` coalesce into the move it made.
    func trackPlaces() {
        let place = withObservationTracking { currentPlace } onChange: {
            Guarded.mainTask { [weak self] in self?.trackPlaces() }
        }
        if let place { history.arrive(at: place) }
    }

    /// ⌃O / ⌃I. `keepSidebar` holds the keyboard on the tree, as a sidebar click does, so the
    /// chord repeats from where it was pressed; otherwise the pane you land in takes the keys.
    func travel(_ direction: Int, keepSidebar: Bool) {
        guard let place = history.step(direction, reachable: isReachable) else { return }
        switch place {
        case .session(let id):
            guard let s = session(id) else { return }
            if keepSidebar {
                suppressShellFocusOnOpen = true
                jump(to: s)
                handToSidebar(s.id)
            } else {
                jump(to: s)
                focusContent(self)
            }
        case .settings: enterSettings()
        case .usage: enterUsage()
        case .routines: enterRoutines()
        }
        history.settle(at: currentPlace)
    }

    private func isReachable(_ place: Place) -> Bool {
        guard case .session(let id) = place else { return true }
        guard let s = session(id), let br = branch(of: s) else { return false }
        return !br.isArchived
    }
}

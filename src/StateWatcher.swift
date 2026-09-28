import Foundation

// Notices when the on/off flag changes underneath us - typically `mutewake on|off`
// from a terminal - so the menu bar icon never disagrees with the CLI.
//
// Watches the config directory rather than the flag itself: the flag comes and
// goes, and a vnode source can only watch something that exists. Event-driven,
// so there is no polling.
final class StateWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var lastDisabled = isDisabled()
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (_ disabled: Bool) -> Void) {
        self.onChange = onChange
        arm()
    }

    private func arm() {
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let fd = open(stateDir.path, O_EVTONLY)
        guard fd >= 0 else {
            log("state watcher: cannot open \(stateDir.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // The directory itself was removed or moved (e.g. by uninstall);
            // re-arm on a fresh one so later toggles are still seen.
            if !src.data.intersection([.delete, .rename]).isEmpty {
                src.cancel()
                self.arm()
            }
            self.check()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func check() {
        let disabled = isDisabled()
        guard disabled != lastDisabled else { return }
        lastDisabled = disabled
        log(disabled ? "feature: off" : "feature: on")
        onChange(disabled)
    }
}

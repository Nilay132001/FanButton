import Foundation

/// Live fan readings shared by the menu-bar panel and the desktop widget.
final class FanModel: ObservableObject {
    @Published private(set) var status: ThermalStatus?
    /// Why the last button press failed; kept until the next press.
    @Published private(set) var actionError: String?
    /// Why the latest reading failed; cleared by the next good one.
    @Published private(set) var readError: String?
    @Published private(set) var busy = false
    @Published var target: Double = 0

    private var timer: Timer?
    private var viewers = 0
    private var refreshing = false
    /// The fastest fan speed macOS picked on its own at the last reading taken in automatic mode.
    private var autoRpm: Int?

    var error: String? { actionError ?? readError }

    var isManual: Bool { status?.fans.contains { $0.mode == "manual" } ?? false }

    /// Slider bottom: never below the speed macOS chose itself, so a manual setting can only speed fans up.
    var floor: Int {
        guard let fans = status?.fans, !fans.isEmpty else { return 0 }
        let hardwareMin = fans.map(\.minRpm).max() ?? 0
        return max(autoRpm ?? fans.map(\.actualRpm).max() ?? 0, hardwareMin)
    }

    /// Slider top: `thermalforge set` drives every fan, so stop at the slowest fan's maximum.
    var ceiling: Int { status?.fans.map(\.maxRpm).min() ?? 0 }

    /// Poll only while something is on screen. Every `startWatching` needs a matching `stopWatching`.
    func startWatching() {
        viewers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopWatching() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func boost() { perform(["max"]) }
    func automatic() { perform(["auto"]) }
    func apply() { perform(["set", String(Int(target))]) }

    private func perform(_ arguments: [String]) {
        busy = true
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                try ThermalForge.run(arguments)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                self.actionError = failure
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ThermalForge.status() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let status): self.update(status)
                case .failure(let error): self.readError = error.localizedDescription
                }
            }
        }
    }

    private func update(_ new: ThermalStatus) {
        let firstReading = status == nil
        status = new
        readError = nil
        if !isManual, let fastest = new.fans.map(\.actualRpm).max() { autoRpm = fastest }
        guard ceiling > floor else { return }
        target = firstReading ? Double(floor) : min(max(target, Double(floor)), Double(ceiling))
    }
}

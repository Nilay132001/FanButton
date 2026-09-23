# FanButton Own Fan Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ThermalForge with FanButton's own SMC reader (in the app) and a small root helper (for fan writes), verified on the user's M5 Pro before ThermalForge is removed.

**Architecture:** `Shared/` holds SMC access, the socket protocol and the pure safety rules. `Helper/` is a root launchd daemon that owns every fan write and enforces the watchdog, the 95 °C override and mode-drift repair. `App/` reads sensors directly and sends `max`/`set`/`auto`/`heartbeat` over a 0600 Unix socket.

**Tech Stack:** Swift 6 toolchain from Xcode Command Line Tools (`swiftc`, no Xcode project, no XCTest), AppKit + SwiftUI, IOKit (AppleSMC), launchd, Metal (GPU load tool only), bash + python3 for test scripts.

**Spec:** `docs/superpowers/specs/2026-09-23-own-fan-helper-design.md`

## Global Constraints

- Target: MacBook Pro `Mac17,8` (M5 Pro), macOS 26.6.2, 2 fans, mode key `F%dmd` (0 = auto, 1 = manual), no `Ftst`.
- Only the helper writes to the SMC. The app never writes.
- Helper paths: binary `/Library/PrivilegedHelperTools/local.fanbutton.helper`, plist `/Library/LaunchDaemons/local.fanbutton.helper.plist`, socket `/var/run/fanbutton.sock` (owner uid, mode 0600), launchd label `local.fanbutton.helper`.
- Protocol: one JSON line per connection, max 1 KB, `HelperProtocol.version = 1`.
- Safety numbers: heartbeat every 5 s, timeout 15 s, override at ≥ 95 °C, clear below 90 °C, 3 unreadable checks → Automatic, helper tick every 2 s, mode unlock retry up to 10 s.
- `set` accepted only when `max(fan mins) ≤ rpm ≤ min(fan maxes)`; `max` writes each fan's own `F%dMx`.
- Helper writes Automatic at start and on SIGTERM/SIGINT.
- SMC code adapted from ThermalForge (MIT, Copyright (c) 2026 ProducerGuy) with credit in the file header.
- The safety rules are complete only when Gates 1–4 in the spec pass on this Mac, recorded in `docs/verification/2026-09-23-helper-safety.md`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## File Structure

| Path | Responsibility |
|---|---|
| `Shared/SMC.swift` | IOKit AppleSMC connection, read/write, value decoding, fan readings, verified sensor lists |
| `Shared/Protocol.swift` | Request/response types, socket path, frame limits, `unixSocketAddress` |
| `Shared/Safety.swift` | Pure rules: `Hold`, `FanLimits`, `HelperState`, `SafetyRules.checkSet`, `SafetyRules.tick` |
| `Helper/HelperCore.swift` | `FanHardware` protocol and the helper's state machine |
| `Helper/SMCFans.swift` | Real `FanHardware` over the SMC |
| `Helper/FakeFans.swift` | File-backed `FanHardware` for tests without root |
| `Helper/main.swift` | Arguments, socket server, peer-uid check, 2 s ticker, signal handling |
| `App/FanButton.swift` | App delegate, status item, popover, widget (moved from repo root) |
| `App/FanModel.swift` | Readings, slider floor/ceiling, helper status, heartbeat, commands |
| `App/Views.swift` | Panel, widget, readings views |
| `App/Readings.swift` | `ThermalStatus` read from the SMC (replaces the JSON from `thermalforge status`) |
| `App/HelperClient.swift` | Socket client |
| `App/HelperInstaller.swift` | Admin-prompt install, update and uninstall |
| `Resources/install-helper.sh`, `Resources/uninstall-helper.sh` | Run as root by the installer |
| `tools/fan-probe/main.swift` | Read-only probe of fan keys and CPU/GPU readouts |
| `tools/sensor-survey/main.swift`, `tools/gpu-load/main.swift`, `tools/analyze-survey.py`, `tools/run-sensor-survey.sh` | Gate 1 |
| `tools/helperctl/main.swift` | Command-line client for the helper (tests and gates) |
| `tools/render-views/main.swift` | Renders panel/widget PNGs offscreen for visual checks |
| `tests/main.swift`, `tests/SafetyTests.swift`, `tests/HelperCoreTests.swift`, `tests/ProtocolTests.swift`, `tests/run.sh` | Unit tests (plain asserts, no XCTest) |
| `tests/helper-integration.sh` | Runs the real helper binary against `FakeFans` |
| `docs/verification/2026-09-23-helper-safety.md` | Gate results with numbers |

`ThermalForge.swift` is deleted in Task 6.

---

### Task 1: Read fans and temperatures directly from the SMC

**Files:**
- Create: `Shared/SMC.swift`, `App/Readings.swift`, `tools/fan-probe/main.swift`
- Move: `FanButton.swift`, `FanModel.swift`, `Views.swift`, `ThermalForge.swift` → `App/`
- Modify: `App/FanModel.swift` (refresh + `isManual`), `App/Views.swift:19` (mode label), `App/ThermalForge.swift` (drop `ThermalStatus` and `status()`), `build.sh`

**Interfaces:**
- Produces: `SMCConnection` (`init?()`, `read(_:) -> SMCValue?`, `write(_:_:) -> Bool`, `keyCount: UInt32`, `key(at:) -> String?`, `float(_:) -> Float?`, `fans() -> [FanReading]?`, `peak(_:) -> Float?`), `SMCValue` (`bytes`, `type`, `float`), `smcBytes(_ value: Float) -> [UInt8]`, `FanReading` (`index: Int`, `actual/target/min/max: Float`, `manual: Bool`), `Sensors.cpu/gpu: [String]`, `ThermalStatus` (`fans: [Fan]`, `cpu/gpu: Double?`, `static read() throws`), `ThermalStatus.Fan` (`index, actualRpm, targetRpm, minRpm, maxRpm: Int`, `manual: Bool`).

- [ ] **Step 1: Move the app sources**

```bash
mkdir -p App Shared tools/fan-probe
git mv FanButton.swift FanModel.swift Views.swift ThermalForge.swift App/
```

- [ ] **Step 2: Write `Shared/SMC.swift`**

```swift
//
//  SMC access for FanButton.
//  Adapted from ThermalForge's SMCConnection.swift and SMCKeys.swift
//  (https://github.com/ProducerGuy/ThermalForge, MIT License, Copyright (c) 2026 ProducerGuy),
//  which adapt agoodkind/macos-smc-fan (MIT).
//

import Foundation
import IOKit

/// 80-byte struct the AppleSMC kernel interface expects. Layout must not change.
private struct SMCParamStruct {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum SMCCommand: UInt8 {
    case readBytes = 5, writeBytes = 6, getKeyFromIndex = 8, readKeyInfo = 9
}

/// A raw SMC value and its four-character type code (for example "flt ", "ui8 ").
struct SMCValue {
    let bytes: [UInt8]
    let type: String

    /// Decodes Apple Silicon float ("flt ", little-endian IEEE 754) and 16.16 fixed-point ("ioft") values.
    var float: Float? {
        guard bytes.count >= 4 else { return nil }
        var raw: UInt32 = 0
        memcpy(&raw, bytes, 4)
        switch type {
        case "flt ": return Float(bitPattern: raw)
        case "ioft": return Float(raw >> 16) + Float(raw & 0xFFFF) / 65536
        default: return nil
        }
    }
}

func smcBytes(_ value: Float) -> [UInt8] {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
}

/// Direct IOKit connection to the System Management Controller. Reads work as any user; writes need root.
final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit { IOServiceClose(connection) }

    func read(_ key: String) -> SMCValue? {
        guard let code = fourCharCode(key) else { return nil }
        var input = SMCParamStruct(), output = SMCParamStruct()
        input.key = code
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard call(&input, &output), output.result == 0 else { return nil }
        let size = output.keyInfo.dataSize, type = fourCharString(output.keyInfo.dataType)
        guard size > 0, size <= 32 else { return nil }
        input.keyInfo.dataSize = size
        input.data8 = SMCCommand.readBytes.rawValue
        guard call(&input, &output), output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
        return SMCValue(bytes: bytes, type: type)
    }

    /// True only when the SMC firmware accepted the write, not just IOKit.
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let code = fourCharCode(key), bytes.count <= 32 else { return false }
        var input = SMCParamStruct(), output = SMCParamStruct()
        input.key = code
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard call(&input, &output), output.result == 0 else { return false }
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCCommand.writeBytes.rawValue
        let padded = bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: padded) }
        guard call(&input, &output) else { return false }
        return output.result == 0
    }

    var keyCount: UInt32 {
        guard let bytes = read("#KEY")?.bytes, bytes.count >= 4 else { return 0 }
        return bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    func key(at index: UInt32) -> String? {
        var input = SMCParamStruct(), output = SMCParamStruct()
        input.data8 = SMCCommand.getKeyFromIndex.rawValue
        input.data32 = index
        guard call(&input, &output) else { return nil }
        return fourCharString(output.key)
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride,
                                         &output, &outputSize) == kIOReturnSuccess
    }

    private func fourCharCode(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func fourCharString(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xFF) }, encoding: .ascii) ?? "????"
    }
}

/// One fan as the SMC reports it.
struct FanReading: Equatable {
    let index: Int
    let actual: Float
    let target: Float
    let min: Float
    let max: Float
    let manual: Bool
}

/// Temperature sensors used for the CPU/GPU readouts and the helper's 95 °C override.
/// Provisional until Gate 1 (docs/verification/2026-09-23-helper-safety.md) replaces them with measured lists.
enum Sensors {
    static let cpu = ["TCMb", "TCHP", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0X"]
    static let gpu = ["TG0B", "TG0H", "TG0V", "Tg0j"]
}

extension SMCConnection {
    func float(_ key: String) -> Float? { read(key)?.float }

    /// Every fan, or nil when the fan count can't be read. Mode uses the M5 key `F%dmd`.
    func fans() -> [FanReading]? {
        guard let count = read("FNum")?.bytes.first else { return nil }
        return (0..<Int(count)).map { i in
            FanReading(index: i,
                       actual: float("F\(i)Ac") ?? 0,
                       target: float("F\(i)Tg") ?? 0,
                       min: float("F\(i)Mn") ?? 0,
                       max: float("F\(i)Mx") ?? 0,
                       manual: read("F\(i)md")?.bytes.first == 1)
        }
    }

    /// Hottest plausible (0–150 °C) reading among `keys`, or nil when none can be read.
    func peak(_ keys: [String]) -> Float? {
        keys.compactMap { float($0) }.filter { $0 > 0 && $0 < 150 }.max()
    }
}
```

- [ ] **Step 3: Write the read-only probe `tools/fan-probe/main.swift`**

```swift
import Foundation

// Read-only snapshot of the fan keys and CPU/GPU readouts. Never writes to the SMC.
// Usage: fan-probe            print once
//        fan-probe watch N    print every 0.5 s for N seconds, with a timestamp
guard let smc = SMCConnection() else { print("can't open the SMC"); exit(1) }

func line() -> String {
    let fans = smc.fans() ?? []
    let parts = fans.map { "F\($0.index)md=\($0.manual ? 1 : 0) F\($0.index)Tg=\(Int($0.target)) F\($0.index)Ac=\(Int($0.actual))" }
    let cpu = smc.peak(Sensors.cpu).map { String(format: "%.1f", $0) } ?? "-"
    let gpu = smc.peak(Sensors.gpu).map { String(format: "%.1f", $0) } ?? "-"
    return (parts + ["cpu=\(cpu)", "gpu=\(gpu)"]).joined(separator: " ")
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "watch", let seconds = Double(args[2]) {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        print(String(format: "%6.1f ", Date().timeIntervalSince(start)) + line())
        fflush(stdout)
        Thread.sleep(forTimeInterval: 0.5)
    }
} else {
    print(line())
}
```

- [ ] **Step 4: Run the probe and compare with ThermalForge**

```bash
S=$(mktemp -d); swiftc -O tools/fan-probe/main.swift Shared/SMC.swift -o "$S/fan-probe" && "$S/fan-probe"; thermalforge status | head -20
```

Expected: the probe prints `F0md=0 F0Tg=… F0Ac=… F1md=0 …` with RPMs within ~50 of `actual_rpm`/`target_rpm` from `thermalforge status`, and `cpu=`/`gpu=` values. If the RPMs disagree, stop: the SMC reader is wrong.

- [ ] **Step 5: Write `App/Readings.swift`**

```swift
import Foundation

/// One reading of every fan plus the CPU/GPU temperatures, straight from the SMC (no admin rights needed).
struct ThermalStatus {
    struct Fan {
        let index: Int
        let actualRpm: Int
        let targetRpm: Int
        let minRpm: Int
        let maxRpm: Int
        let manual: Bool
    }

    struct ReadError: LocalizedError {
        var errorDescription: String? { "Can't read the fan controller." }
    }

    let fans: [Fan]
    let cpu: Double?
    let gpu: Double?

    private static let smc = SMCConnection()

    /// Blocks briefly on IOKit; call it off the main thread.
    static func read() throws -> ThermalStatus {
        guard let smc, let fans = smc.fans(), !fans.isEmpty else { throw ReadError() }
        return ThermalStatus(
            fans: fans.map {
                Fan(index: $0.index, actualRpm: Int($0.actual.rounded()), targetRpm: Int($0.target.rounded()),
                    minRpm: Int($0.min.rounded()), maxRpm: Int($0.max.rounded()), manual: $0.manual)
            },
            cpu: smc.peak(Sensors.cpu).map(Double.init),
            gpu: smc.peak(Sensors.gpu).map(Double.init))
    }
}
```

- [ ] **Step 6: Strip the JSON status from `App/ThermalForge.swift`**

Delete the whole `struct ThermalStatus: Decodable { … }` block and the `static func status() throws -> ThermalStatus { … }` function. Keep `ThermalForgeError` and `ThermalForge.run(_:)`; Task 6 deletes the file.

- [ ] **Step 7: Point `App/FanModel.swift` at the SMC**

In `refresh()`, replace
```swift
            let result = Result { try ThermalForge.status() }
```
with
```swift
            let result = Result { try ThermalStatus.read() }
```
and replace
```swift
    var isManual: Bool { status?.fans.contains { $0.mode == "manual" } ?? false }
```
with
```swift
    var isManual: Bool { status?.fans.contains { $0.manual } ?? false }
```

- [ ] **Step 8: Update the mode label in `App/Views.swift`**

Replace
```swift
                        Text(fan.mode == "manual" ? "Manual" : "Auto")
```
with
```swift
                        Text(fan.manual ? "Manual" : "Auto")
```

- [ ] **Step 9: Update `build.sh` to compile the new layout**

Replace
```bash
swiftc -O -parse-as-library *.swift -o FanButton.app/Contents/MacOS/FanButton
```
with
```bash
swiftc -O -parse-as-library App/*.swift Shared/*.swift -o FanButton.app/Contents/MacOS/FanButton
```

- [ ] **Step 10: Build, launch and check readings**

```bash
bash build.sh && pkill -f MacOS/FanButton; open /Applications/FanButton.app; sleep 3; pgrep -lf MacOS/FanButton
```

Expected: build succeeds, the process is running. Render the panel to confirm real readings (the harness is added in Task 6; for now run the probe again and confirm the app is alive).

- [ ] **Step 11: Commit**

```bash
git add -A && git commit -m "Read fans and temperatures straight from the SMC

The app no longer runs thermalforge status; Shared/SMC.swift (adapted from
ThermalForge, MIT) reads the fan keys and sensors without admin rights.
Commands still go through ThermalForge until the helper lands.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Gate 1 — verify the CPU/GPU sensors on this M5 Pro

**Files:**
- Create: `tools/sensor-survey/main.swift`, `tools/gpu-load/main.swift`, `tools/analyze-survey.py`, `tools/run-sensor-survey.sh`, `docs/verification/2026-09-23-helper-safety.md`
- Modify: `Shared/SMC.swift` (`Sensors` lists and their comment)

**Interfaces:**
- Consumes: `SMCConnection`, `Sensors`, `peak(_:)` from Task 1.
- Produces: final `Sensors.cpu` and `Sensors.gpu` lists used by Tasks 4–7.

- [ ] **Step 1: Write `tools/sensor-survey/main.swift`**

```swift
import Foundation

// Gate 1: find which temperature sensors follow CPU and GPU load on this Mac. Read-only.
// Usage: sensor-survey list                every readable T* key with its type and value
//        sensor-survey sample N out.csv    sample every T* key once a second for N seconds,
//                                          plus the app's cpu/gpu readouts (app_cpu, app_gpu)
guard let smc = SMCConnection() else { print("can't open the SMC"); exit(1) }

let keys = (0..<smc.keyCount).compactMap { smc.key(at: $0) }
    .filter { $0.hasPrefix("T") }
    .filter { key in smc.float(key).map { $0 > 0 && $0 < 150 } ?? false }
    .sorted()

func format(_ value: Float?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list":
    for key in keys { print(key, smc.read(key)!.type, format(smc.float(key))) }
case "sample" where args.count == 4:
    guard let seconds = Int(args[2]) else { print("N must be a number"); exit(2) }
    var csv = "t," + keys.joined(separator: ",") + ",app_cpu,app_gpu\n"
    let start = Date()
    for t in 0..<seconds {
        let row = keys.map { format(smc.float($0)) }
        csv += "\(t)," + row.joined(separator: ",") + "," + format(smc.peak(Sensors.cpu)) + "," + format(smc.peak(Sensors.gpu)) + "\n"
        Thread.sleep(until: start.addingTimeInterval(Double(t + 1)))
    }
    try! csv.write(toFile: args[3], atomically: true, encoding: .utf8)
default:
    print("usage: sensor-survey list | sensor-survey sample N out.csv")
    exit(2)
}
```

- [ ] **Step 2: Write `tools/gpu-load/main.swift`**

```swift
import Foundation
import Metal

// Keeps the GPU busy for N seconds (default 60) so Gate 1 can see which sensors follow GPU load.
let seconds = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "60") ?? 60
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("no Metal device"); exit(1)
}
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 0.0001;
    for (int i = 0; i < 20000; i++) { x = fma(x, 1.000001, 0.000001); x = sin(x) + cos(x); }
    out[id] = x;
}
"""
let pipeline = try device.makeComputePipelineState(
    function: try device.makeLibrary(source: source, options: nil).makeFunction(name: "burn")!)
let count = 1 << 20
let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.size)!
let end = Date().addingTimeInterval(seconds)
var batches = 0
while Date() < end {
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    if let error = commands.error { print("GPU error: \(error)"); exit(1) }
    batches += 1
}
print("gpu-load: \(batches) batches in \(Int(seconds)) s")
```

- [ ] **Step 3: Write `tools/analyze-survey.py`**

```python
"""Gate 1 analysis.

  analyze-survey.py cpu.csv gpu.csv   rank every sensor by how much it follows each load and
                                      print the CPU and GPU key lists that pass the rule
  analyze-survey.py check run.csv     confirm app_cpu/app_gpu equal the hottest listed key

Each survey CSV is 100 rows: 10 s idle, 60 s load, 30 s cooldown.
Rule: a key follows a load when it rises >= 10 C above its idle mean during the load and
falls back by at least half of that rise during the cooldown. CPU keys must start with TC/Tp,
GPU keys with TG/Tg.
"""
import csv
import sys

RISE = 10.0


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def series(data, key):
    return [float(r[key]) if r[key] else None for r in data]


def stats(data, key):
    values = series(data, key)
    idle = [v for v in values[:10] if v is not None]
    load = [v for v in values[10:70] if v is not None]
    cool = [v for v in values[70:] if v is not None]
    if not idle or not load or not cool:
        return None
    base = sum(idle) / len(idle)
    peak = max(load)
    return {"idle": base, "peak": peak, "rise": peak - base, "fall": peak - cool[-1]}


def follows(s):
    return s is not None and s["rise"] >= RISE and s["fall"] >= s["rise"] / 2


def survey(cpu_path, gpu_path):
    cpu, gpu = rows(cpu_path), rows(gpu_path)
    keys = [k for k in cpu[0] if k not in ("t", "app_cpu", "app_gpu")]
    print(f"{'key':5} {'cpu idle':>8} {'peak':>6} {'rise':>6}   {'gpu idle':>8} {'peak':>6} {'rise':>6}")
    table = []
    for k in keys:
        c = stats(cpu, k)
        g = stats(gpu, k) if k in gpu[0] else None
        table.append((k, c, g))
    for k, c, g in sorted(table, key=lambda t: -max(t[1]["rise"] if t[1] else 0, t[2]["rise"] if t[2] else 0)):
        f = lambda s: f"{s['idle']:8.1f} {s['peak']:6.1f} {s['rise']:6.1f}" if s else f"{'-':>8} {'-':>6} {'-':>6}"
        print(f"{k:5} {f(c)}   {f(g)}")
    cpu_keys = [k for k, c, _ in table if k[:2] in ("TC", "Tp") and follows(c)]
    gpu_keys = [k for k, _, g in table if k[:2] in ("TG", "Tg") and follows(g)]
    print("\nCPU keys:", cpu_keys)
    print("GPU keys:", gpu_keys)
    return 0 if cpu_keys and gpu_keys else 1


def check(path, cpu_keys, gpu_keys):
    worst = 0.0
    for r in rows(path):
        for col, keys in (("app_cpu", cpu_keys), ("app_gpu", gpu_keys)):
            listed = [float(r[k]) for k in keys if r.get(k)]
            if not listed or not r[col]:
                print(f"t={r['t']}: {col} or its sensors unreadable")
                return 1
            worst = max(worst, abs(float(r[col]) - max(listed)))
    print(f"largest gap between app readout and hottest listed key: {worst:.2f} C")
    return 0 if worst <= 1.0 else 1


if __name__ == "__main__":
    if len(sys.argv) == 3:
        sys.exit(survey(sys.argv[1], sys.argv[2]))
    if len(sys.argv) == 5 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3].split(","), sys.argv[4].split(",")))
    print(__doc__)
    sys.exit(2)
```

- [ ] **Step 4: Write `tools/run-sensor-survey.sh`**

```bash
#!/bin/bash
# Gate 1: a CPU run and a GPU run, each 10 s idle, 60 s load, 30 s cooldown, sampled at 1 Hz.
# Usage: bash tools/run-sensor-survey.sh OUTDIR
set -euo pipefail
cd "$(dirname "$0")/.."
out="$1"; mkdir -p "$out"
swiftc -O tools/sensor-survey/main.swift Shared/SMC.swift -o "$out/sensor-survey"
swiftc -O tools/gpu-load/main.swift -o "$out/gpu-load"
"$out/sensor-survey" list > "$out/idle-list.txt"

echo "CPU run (100 s)…"
"$out/sensor-survey" sample 100 "$out/cpu.csv" & sampler=$!
sleep 10
pids=(); for _ in $(seq "$(sysctl -n hw.ncpu)"); do yes > /dev/null & pids+=($!); done
sleep 60; kill "${pids[@]}"
wait "$sampler"

echo "Cooling down 60 s…"; sleep 60

echo "GPU run (100 s)…"
"$out/sensor-survey" sample 100 "$out/gpu.csv" & sampler=$!
sleep 10; "$out/gpu-load" 60; wait "$sampler"

python3 tools/analyze-survey.py "$out/cpu.csv" "$out/gpu.csv" | tee "$out/analysis.txt"
```

- [ ] **Step 5: Run the survey**

```bash
bash tools/run-sensor-survey.sh "$SCRATCH/survey"
```

(`$SCRATCH` = the session scratchpad directory.) Expected: about 5 minutes; ends with `CPU keys: [...]` and `GPU keys: [...]`, both non-empty, exit 0. If either list is empty, **stop**: Gate 1 fails. Report the analysis table to the user instead of guessing keys.

- [ ] **Step 6: Freeze the lists in `Shared/SMC.swift`**

Replace the `Sensors` enum with the measured lists, keeping key order as printed:

```swift
/// Temperature sensors used for the CPU/GPU readouts and the helper's 95 °C override. Measured on the
/// Mac17,8 (M5 Pro) in Gate 1: each key rose at least 10 °C under its own load and fell back after it.
/// See docs/verification/2026-09-23-helper-safety.md.
enum Sensors {
    static let cpu = [/* paste "CPU keys" from analysis.txt as string literals */]
    static let gpu = [/* paste "GPU keys" from analysis.txt as string literals */]
}
```

The comments above mark where the executor pastes output; the committed file must contain only the literal key strings.

- [ ] **Step 7: Check the app readout against the frozen lists under load**

```bash
S="$SCRATCH/survey"
swiftc -O tools/sensor-survey/main.swift Shared/SMC.swift -o "$S/sensor-survey"
"$S/sensor-survey" sample 100 "$S/check-cpu.csv" & p=$!; sleep 10
pids=(); for _ in $(seq "$(sysctl -n hw.ncpu)"); do yes > /dev/null & pids+=($!); done; sleep 60; kill "${pids[@]}"; wait $p
python3 tools/analyze-survey.py check "$S/check-cpu.csv" "<cpu keys comma-separated>" "<gpu keys comma-separated>"
```

Expected: `largest gap … <= 1.00 C`, exit 0.

- [ ] **Step 8: Record Gate 1 in `docs/verification/2026-09-23-helper-safety.md`**

Create the file with this structure, filled from `idle-list.txt`, `analysis.txt` and Step 7's output:

```markdown
# Helper safety verification — Mac17,8 (M5 Pro), macOS 26.6.2

## Gate 1: CPU/GPU safety sensors — PASS|FAIL (date)

Method: `bash tools/run-sensor-survey.sh` (10 s idle, 60 s all-core `yes` / Metal compute load, 30 s cooldown, 1 Hz).
Rule: rise >= 10 °C under its own load and fall back by at least half of that.

| Key | CPU idle | CPU peak | CPU rise | GPU idle | GPU peak | GPU rise | Used for |
|---|---|---|---|---|---|---|---|
(one row per key from analysis.txt with rise >= 3 °C, plus every key from the provisional lists)

Dropped from the provisional lists: (keys and why, e.g. "TG0B: rose 0.4 °C under GPU load")

Readout check under CPU load: largest gap between app readout and hottest listed key = X °C.
```

- [ ] **Step 9: Rebuild and commit**

```bash
bash build.sh && git add -A && git commit -m "Gate 1: use only the CPU/GPU sensors that follow load on the M5 Pro

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Pure safety rules and protocol types

**Files:**
- Create: `Shared/Safety.swift`, `Shared/Protocol.swift`, `tests/main.swift`, `tests/SafetyTests.swift`, `tests/ProtocolTests.swift`, `tests/run.sh`

**Interfaces:**
- Produces:
  - `enum Hold: Equatable { case max; case rpm(Int) }` with `description: String` (`"max"`, `"set 3000"`)
  - `struct FanLimits: Equatable { let min: Int; let max: Int }`
  - `struct HelperState: Equatable { var hold: Hold?; var lastBeat: Date; var overriding: Bool; var unreadableCount: Int; mutating func release() }`
  - `enum TickAction: Equatable { case none, releaseToAuto, forceMax, reapplyHold }`
  - `enum SafetyRules` with `heartbeatTimeout = 15`, `overrideAt: Float = 95`, `clearBelow: Float = 90`, `unreadableLimit = 3`, `static func checkSet(_ rpm: Int, fans: [FanLimits]) -> String?`, `static func tick(_ state: inout HelperState, now: Date, temp: Float?, fansManual: Bool) -> TickAction`
  - `enum HelperProtocol` (`version = 1`, `socketPath`, `maxFrame = 1024`, `label`)
  - `struct HelperRequest: Codable, Equatable { enum Command: String, Codable { case max, set, auto, heartbeat, state }; var cmd: Command; var rpm: Int? }`
  - `struct HelperResponse: Codable, Equatable { var ok: Bool; var version: Int; var hold: String?; var override: Bool; var temp: Float?; var error: String? }`
  - `func unixSocketAddress(_ path: String) -> sockaddr_un?`
  - Test helpers in `tests/main.swift`: `check(_ condition: Bool, _ message: String)`.

- [ ] **Step 1: Write the test harness `tests/main.swift`**

```swift
import Foundation

// Plain-assert test runner (the Command Line Tools ship no XCTest). Run with: bash tests/run.sh
var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

runSafetyTests()
runProtocolTests()
runHelperCoreTests()

print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Write `tests/run.sh`**

```bash
#!/bin/bash
# Builds and runs the unit tests: the pure safety rules, the protocol and the helper state machine.
set -euo pipefail
cd "$(dirname "$0")/.."
bin="$(mktemp -d)/tests"
swiftc Shared/Safety.swift Shared/Protocol.swift Helper/HelperCore.swift tests/*.swift -o "$bin"
"$bin"
```

- [ ] **Step 3: Write `tests/SafetyTests.swift`**

```swift
import Foundation

private let fans = [FanLimits(min: 1350, max: 5349), FanLimits(min: 1350, max: 5777)]
private let t0 = Date(timeIntervalSince1970: 0)

private func holding(_ hold: Hold, beat: Date = t0) -> HelperState {
    HelperState(hold: hold, lastBeat: beat)
}

func runSafetyTests() {
    // checkSet: range is max of mins to min of maxes
    check(SafetyRules.checkSet(1350, fans: fans) == nil, "1350 is every fan's minimum")
    check(SafetyRules.checkSet(5349, fans: fans) == nil, "5349 is the lower fan maximum")
    check(SafetyRules.checkSet(1349, fans: fans) != nil, "below the minimum is refused")
    check(SafetyRules.checkSet(5350, fans: fans) != nil, "above the lower fan maximum is refused")
    check(SafetyRules.checkSet(3000, fans: []) != nil, "no fans means refuse")

    // Automatic: nothing to do, whatever the temperature
    var auto = HelperState(lastBeat: t0)
    check(SafetyRules.tick(&auto, now: t0.addingTimeInterval(100), temp: 120, fansManual: false) == .none, "no hold, no action")

    // Heartbeat timeout
    var s = holding(.rpm(3000))
    check(SafetyRules.tick(&s, now: t0.addingTimeInterval(15), temp: 60, fansManual: true) == .none, "15 s exactly is still alive")
    check(SafetyRules.tick(&s, now: t0.addingTimeInterval(15.1), temp: 60, fansManual: true) == .releaseToAuto, "over 15 s releases")
    check(s.hold == nil && !s.overriding, "release clears the hold")

    // Override engages at 95, holds between 90 and 95, restores below 90
    s = holding(.rpm(3000))
    check(SafetyRules.tick(&s, now: t0, temp: 94.9, fansManual: true) == .none, "94.9 does not engage")
    check(SafetyRules.tick(&s, now: t0, temp: 95, fansManual: true) == .forceMax, "95 engages")
    check(s.overriding, "override flag set")
    check(SafetyRules.tick(&s, now: t0, temp: 96, fansManual: true) == .none, "stays engaged, no repeat write")
    check(SafetyRules.tick(&s, now: t0, temp: 90, fansManual: true) == .none, "90 is not below 90")
    check(SafetyRules.tick(&s, now: t0, temp: 89.9, fansManual: true) == .reapplyHold, "below 90 restores")
    check(!s.overriding && s.hold == .rpm(3000), "hold kept after restore")

    // A max hold is never overridden and never released for unreadable sensors
    s = holding(.max)
    check(SafetyRules.tick(&s, now: t0, temp: 99, fansManual: true) == .none, "max hold needs no override")
    for _ in 0..<5 { _ = SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true) }
    check(s.hold == .max, "unreadable sensors don't release a max hold")

    // Unreadable sensors: three checks in a row release a below-max hold
    s = holding(.rpm(3000))
    check(SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true) == .none, "1st unreadable")
    check(SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true) == .none, "2nd unreadable")
    check(SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true) == .releaseToAuto, "3rd unreadable releases")
    s = holding(.rpm(3000))
    _ = SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true)
    _ = SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true)
    _ = SafetyRules.tick(&s, now: t0, temp: 60, fansManual: true)
    check(SafetyRules.tick(&s, now: t0, temp: nil, fansManual: true) == .none, "a good reading resets the count")

    // Mode drift
    s = holding(.rpm(3000))
    check(SafetyRules.tick(&s, now: t0, temp: 60, fansManual: false) == .reapplyHold, "drift re-applies the hold")
    s = holding(.rpm(3000))
    _ = SafetyRules.tick(&s, now: t0, temp: 96, fansManual: true)
    check(SafetyRules.tick(&s, now: t0, temp: 96, fansManual: false) == .forceMax, "drift during override forces max again")
    s = holding(.rpm(3000))
    check(SafetyRules.tick(&s, now: t0.addingTimeInterval(20), temp: 60, fansManual: false) == .releaseToAuto,
          "drift with a stale heartbeat releases instead of re-applying")

    check(Hold.max.description == "max" && Hold.rpm(3000).description == "set 3000", "hold descriptions")
}
```

- [ ] **Step 4: Write `tests/ProtocolTests.swift`**

```swift
import Foundation

func runProtocolTests() {
    let decoder = JSONDecoder()
    let set = try? decoder.decode(HelperRequest.self, from: Data(#"{"cmd":"set","rpm":3000}"#.utf8))
    check(set == HelperRequest(cmd: .set, rpm: 3000), "set request decodes")
    check((try? decoder.decode(HelperRequest.self, from: Data(#"{"cmd":"reboot"}"#.utf8))) == nil, "unknown command is rejected")
    check((try? decoder.decode(HelperRequest.self, from: Data("garbage".utf8))) == nil, "garbage is rejected")

    let encoded = String(data: try! JSONEncoder().encode(HelperRequest(cmd: .heartbeat)), encoding: .utf8)!
    check(!encoded.contains("rpm"), "nil rpm is left out")

    let response = HelperResponse(ok: true, hold: "set 3000")
    let roundTrip = try? decoder.decode(HelperResponse.self, from: JSONEncoder().encode(response))
    check(roundTrip == response && roundTrip?.version == HelperProtocol.version, "response round-trips with version")

    check(unixSocketAddress("/var/run/fanbutton.sock") != nil, "socket path fits")
    check(unixSocketAddress(String(repeating: "x", count: 200)) == nil, "overlong socket path is refused")
}
```

- [ ] **Step 5: Add a stub so the harness links, then run to see failures**

Create `Helper/HelperCore.swift` containing only:

```swift
import Foundation
```

and `tests/HelperCoreTests.swift` containing only:

```swift
func runHelperCoreTests() {}
```

Run: `bash tests/run.sh`
Expected: compile errors — `cannot find 'SafetyRules' in scope`, `cannot find type 'HelperRequest'`.

- [ ] **Step 6: Write `Shared/Safety.swift`**

```swift
import Foundation

/// A manual fan command the helper keeps in force.
enum Hold: Equatable, CustomStringConvertible {
    case max
    case rpm(Int)

    var description: String {
        switch self {
        case .max: return "max"
        case .rpm(let rpm): return "set \(rpm)"
        }
    }
}

/// One fan's supported speed range, in rpm.
struct FanLimits: Equatable {
    let min: Int
    let max: Int
}

/// Everything the safety rules decide on. No hold means macOS runs the fans.
struct HelperState: Equatable {
    var hold: Hold? = nil
    var lastBeat: Date
    /// True while the 95 °C override holds the fans at max over a slower hold.
    var overriding = false
    /// Safety-sensor checks in a row that returned nothing.
    var unreadableCount = 0

    mutating func release() {
        hold = nil
        overriding = false
        unreadableCount = 0
    }
}

enum TickAction: Equatable {
    case none
    /// Hand the fans back to macOS.
    case releaseToAuto
    /// Drive every fan at its maximum, keeping the hold for later.
    case forceMax
    /// Write the current hold to the fans again.
    case reapplyHold
}

/// The helper's safety decisions. Pure: the clock and temperature come in as arguments.
enum SafetyRules {
    static let heartbeatTimeout: TimeInterval = 15
    static let overrideAt: Float = 95
    static let clearBelow: Float = 90
    static let unreadableLimit = 3

    /// Nil when every fan can run at `rpm`, otherwise why not.
    static func checkSet(_ rpm: Int, fans: [FanLimits]) -> String? {
        guard let low = fans.map(\.min).max(), let high = fans.map(\.max).min() else { return "No fans found." }
        guard rpm >= low, rpm <= high else { return "\(rpm) rpm is outside what every fan supports (\(low)–\(high) rpm)." }
        return nil
    }

    /// Runs every 2 s. `temp` is the hottest verified CPU/GPU sensor (nil if unreadable);
    /// `fansManual` is whether every fan still reports manual mode.
    static func tick(_ state: inout HelperState, now: Date, temp: Float?, fansManual: Bool) -> TickAction {
        guard let hold = state.hold else { return .none }
        if now.timeIntervalSince(state.lastBeat) > heartbeatTimeout {
            state.release()
            return .releaseToAuto
        }
        if hold != .max {
            if let temp {
                state.unreadableCount = 0
                if !state.overriding && temp >= overrideAt {
                    state.overriding = true
                    return .forceMax
                }
                if state.overriding && temp < clearBelow {
                    state.overriding = false
                    return .reapplyHold
                }
            } else {
                state.unreadableCount += 1
                if state.unreadableCount >= unreadableLimit {
                    state.release()
                    return .releaseToAuto
                }
            }
        }
        if !fansManual { return state.overriding ? .forceMax : .reapplyHold }
        return .none
    }
}
```

- [ ] **Step 7: Write `Shared/Protocol.swift`**

```swift
import Foundation

/// The app ⇄ helper wire format: one JSON line each way per connection.
enum HelperProtocol {
    static let version = 1
    static let label = "local.fanbutton.helper"
    static let socketPath = "/var/run/fanbutton.sock"
    static let maxFrame = 1024
}

struct HelperRequest: Codable, Equatable {
    enum Command: String, Codable {
        case max, set, auto, heartbeat, state
    }

    var cmd: Command
    var rpm: Int? = nil
}

struct HelperResponse: Codable, Equatable {
    var ok: Bool
    var version: Int = HelperProtocol.version
    /// "max", "set 3000", or nil for Automatic.
    var hold: String? = nil
    var override: Bool = false
    /// The helper's own safety-sensor reading; filled in for `state`.
    var temp: Float? = nil
    var error: String? = nil
}

/// A `sockaddr_un` for `path`, or nil when the path is too long for one.
func unixSocketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}
```

- [ ] **Step 8: Run the tests**

Run: `bash tests/run.sh`
Expected: `All N checks passed` (N ≈ 40), exit 0.

- [ ] **Step 9: Commit**

```bash
git add Shared/Safety.swift Shared/Protocol.swift Helper/HelperCore.swift tests && git commit -m "Add the helper's pure safety rules and wire protocol, with tests

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Helper state machine

**Files:**
- Modify: `Helper/HelperCore.swift` (replace stub), `tests/HelperCoreTests.swift` (replace stub)

**Interfaces:**
- Consumes: `Hold`, `FanLimits`, `HelperState`, `SafetyRules`, `TickAction`, `HelperRequest`, `HelperResponse` (Task 3).
- Produces:
  - `protocol FanHardware: AnyObject { func limits() -> [FanLimits]?; func setManual(_ targets: [Int]) throws; func setAuto(); func allManual() -> Bool?; func safetyTemp() -> Float? }`
  - `final class HelperCore { init(hardware: FanHardware, now: @escaping () -> Date); private(set) var state: HelperState; func handle(_ request: HelperRequest) -> HelperResponse; func tick(); func shutdown() }`

- [ ] **Step 1: Write the failing tests in `tests/HelperCoreTests.swift`**

```swift
import Foundation

private struct WriteFailed: Error {}

/// In-memory fans that record what the helper did to them.
private final class RecordingFans: FanHardware {
    var fanLimits: [FanLimits]? = [FanLimits(min: 1350, max: 5349), FanLimits(min: 1350, max: 5777)]
    var manual = false
    var targets: [Int] = []
    var temp: Float? = 60
    var failWrites = false
    var autoCalls = 0

    func limits() -> [FanLimits]? { fanLimits }
    func setManual(_ targets: [Int]) throws {
        if failWrites { throw WriteFailed() }
        manual = true
        self.targets = targets
    }
    func setAuto() { manual = false; targets = []; autoCalls += 1 }
    func allManual() -> Bool? { manual }
    func safetyTemp() -> Float? { temp }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 0)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func makeCore() -> (HelperCore, RecordingFans, Clock) {
    let fans = RecordingFans(), clock = Clock()
    return (HelperCore(hardware: fans, now: { clock.now }), fans, clock)
}

func runHelperCoreTests() {
    var (core, fans, clock) = makeCore()
    check(fans.autoCalls == 1 && !fans.manual, "start releases the fans to macOS")

    var r = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    check(r.ok && r.hold == "set 3000" && fans.targets == [3000, 3000] && fans.manual, "set drives both fans")

    r = core.handle(HelperRequest(cmd: .set, rpm: 1000))
    check(!r.ok && r.error != nil && fans.targets == [3000, 3000], "out-of-range set is refused and changes nothing")
    r = core.handle(HelperRequest(cmd: .set))
    check(!r.ok, "set without rpm is refused")

    r = core.handle(HelperRequest(cmd: .max))
    check(r.ok && r.hold == "max" && fans.targets == [5349, 5777], "max uses each fan's own maximum")

    r = core.handle(HelperRequest(cmd: .auto))
    check(r.ok && r.hold == nil && !fans.manual, "auto releases")

    // Heartbeat watchdog
    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    clock.advance(14); core.tick()
    check(fans.manual, "still manual at 14 s")
    clock.advance(2); core.tick()
    check(!fans.manual && core.state.hold == nil, "released after 16 s without a heartbeat")

    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    for _ in 0..<12 { clock.advance(5); _ = core.handle(HelperRequest(cmd: .heartbeat)); core.tick() }
    check(fans.manual && fans.targets == [3000, 3000], "heartbeats every 5 s keep the hold for a minute")

    // Thermal override
    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    fans.temp = 95; core.tick()
    check(fans.targets == [5349, 5777] && core.state.overriding, "95 °C forces max")
    r = core.handle(HelperRequest(cmd: .set, rpm: 3500))
    check(r.ok && r.hold == "set 3500" && r.override && fans.targets == [5349, 5777], "set during override is recorded, not applied")
    fans.temp = 92; core.tick()
    check(fans.targets == [5349, 5777], "92 °C keeps max")
    fans.temp = 89; core.tick()
    check(fans.targets == [3500, 3500] && !core.state.overriding, "below 90 °C restores the recorded hold")

    // Unreadable sensors
    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    fans.temp = nil; core.tick(); core.tick()
    check(fans.manual, "two unreadable checks keep the hold")
    core.tick()
    check(!fans.manual && core.state.hold == nil, "three unreadable checks release")

    // Mode drift
    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    fans.manual = false; fans.targets = []; core.tick()
    check(fans.manual && fans.targets == [3000, 3000], "drift re-applies the hold")

    // Write failures fall back to Automatic
    (core, fans, clock) = makeCore()
    fans.failWrites = true
    let callsBefore = fans.autoCalls
    r = core.handle(HelperRequest(cmd: .set, rpm: 3000))
    check(!r.ok && core.state.hold == nil && fans.autoCalls == callsBefore + 1, "failed write releases and reports")

    // Fans unreadable when a command arrives
    (core, fans, clock) = makeCore()
    fans.fanLimits = nil
    check(!core.handle(HelperRequest(cmd: .max)).ok, "max with unreadable fans is refused")

    // state reports the helper's own temperature
    (core, fans, clock) = makeCore()
    fans.temp = 71
    check(core.handle(HelperRequest(cmd: .state)).temp == 71, "state includes the safety temperature")

    // Shutdown
    (core, fans, clock) = makeCore()
    _ = core.handle(HelperRequest(cmd: .max))
    core.shutdown()
    check(!fans.manual && core.state.hold == nil, "shutdown releases")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: compile errors — `cannot find type 'FanHardware' in scope`, `cannot find 'HelperCore' in scope`.

- [ ] **Step 3: Write `Helper/HelperCore.swift`**

```swift
import Foundation

/// What the helper needs from the fan controller. `SMCFans` is the real one.
protocol FanHardware: AnyObject {
    /// Each fan's speed range, or nil if the fans can't be read.
    func limits() -> [FanLimits]?
    /// Put every fan in manual mode and set `targets[i]` rpm on fan i.
    func setManual(_ targets: [Int]) throws
    /// Hand every fan back to macOS. Best effort; never throws.
    func setAuto()
    /// True when every fan reports manual mode; nil if the modes can't be read.
    func allManual() -> Bool?
    /// Hottest verified CPU/GPU sensor, or nil if none can be read.
    func safetyTemp() -> Float?
}

/// The helper's state machine. Not thread-safe: call it from one serial queue.
final class HelperCore {
    private(set) var state: HelperState
    private let hardware: FanHardware
    private let now: () -> Date

    /// Starts by handing the fans back to macOS, so a restarted helper never inherits a stale manual speed.
    init(hardware: FanHardware, now: @escaping () -> Date) {
        self.hardware = hardware
        self.now = now
        state = HelperState(lastBeat: now())
        hardware.setAuto()
    }

    func handle(_ request: HelperRequest) -> HelperResponse {
        switch request.cmd {
        case .heartbeat:
            state.lastBeat = now()
        case .state:
            var response = current()
            response.temp = hardware.safetyTemp()
            return response
        case .auto:
            release()
        case .max:
            state.lastBeat = now()
            return hold(.max)
        case .set:
            state.lastBeat = now()
            guard let rpm = request.rpm else { return failure("set needs an rpm.") }
            guard let limits = hardware.limits() else { return failure("Can't read the fans.") }
            if let problem = SafetyRules.checkSet(rpm, fans: limits) { return failure(problem) }
            return hold(.rpm(rpm))
        }
        return current()
    }

    /// Runs every 2 s: heartbeat watchdog, 95 °C override, unreadable sensors, mode drift.
    func tick() {
        guard state.hold != nil else { return }
        let action = SafetyRules.tick(&state, now: now(), temp: hardware.safetyTemp(),
                                      fansManual: hardware.allManual() ?? false)
        switch action {
        case .none: break
        case .releaseToAuto: hardware.setAuto()
        case .forceMax: write(.max)
        case .reapplyHold: if let hold = state.hold { write(hold) }
        }
    }

    func shutdown() { release() }

    private func hold(_ hold: Hold) -> HelperResponse {
        state.hold = hold
        state.unreadableCount = 0
        if hold == .max { state.overriding = false }
        // During the override the fans stay at max; the new hold applies when it clears.
        if state.overriding { return current() }
        if let problem = write(hold) { return failure(problem) }
        return current()
    }

    /// Drives the fans to `hold`. On failure the fans go back to macOS and the hold is dropped.
    @discardableResult
    private func write(_ hold: Hold) -> String? {
        guard let limits = hardware.limits(), !limits.isEmpty else {
            release()
            return "Can't read the fans."
        }
        let targets: [Int]
        switch hold {
        case .max: targets = limits.map(\.max)
        case .rpm(let rpm): targets = Array(repeating: rpm, count: limits.count)
        }
        do {
            try hardware.setManual(targets)
            return nil
        } catch {
            release()
            return error.localizedDescription
        }
    }

    private func release() {
        state.release()
        hardware.setAuto()
    }

    private func current() -> HelperResponse {
        HelperResponse(ok: true, hold: state.hold?.description, override: state.overriding)
    }

    private func failure(_ message: String) -> HelperResponse {
        var response = current()
        response.ok = false
        response.error = message
        return response
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/run.sh`
Expected: `All N checks passed` (N ≈ 62), exit 0.

- [ ] **Step 5: Commit**

```bash
git add Helper/HelperCore.swift tests/HelperCoreTests.swift && git commit -m "Add the helper state machine: watchdog, override, drift and write-failure handling

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Helper executable, command-line client and end-to-end test

**Files:**
- Create: `Helper/SMCFans.swift`, `Helper/FakeFans.swift`, `Helper/main.swift`, `App/HelperClient.swift`, `tools/helperctl/main.swift`, `tests/helper-integration.sh`

**Interfaces:**
- Consumes: `FanHardware`, `HelperCore` (Task 4); `HelperProtocol`, `HelperRequest`, `HelperResponse`, `unixSocketAddress` (Task 3); `SMCConnection`, `Sensors`, `smcBytes` (Tasks 1–2).
- Produces:
  - Helper CLI: `fanbutton-helper [--owner-uid N] [--socket PATH] [--fake-hardware DIR]`
  - `enum HelperClientError: LocalizedError, Equatable { case notInstalled, io(String), badResponse }`
  - `enum HelperClient { static var socketPath: String; static func send(_ request: HelperRequest, timeout: TimeInterval = 12) throws -> HelperResponse }` (honours env `FANBUTTON_SOCKET`)
  - `helperctl state|heartbeat|auto|max|set N` — prints the response JSON, exit 0 when `ok`, 1 when not, 2 on connection errors.

- [ ] **Step 1: Write the failing integration test `tests/helper-integration.sh`**

```bash
#!/bin/bash
# Runs the real helper binary against FakeFans (no root needed) and checks every safety rule end to end.
# Takes about 75 s because the heartbeat timeout is real time.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT

swiftc Helper/*.swift Shared/*.swift -o "$work/helper"
swiftc tools/helperctl/main.swift App/HelperClient.swift Shared/Protocol.swift -o "$work/helperctl"
export FANBUTTON_SOCKET="$work/sock"

ctl() { "$work/helperctl" "$@"; }
fans() {
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(("manual" if all(s["manual"]) else "auto") + " " + ",".join(map(str, s["targets"])))' "$work/fans.json"
}
expect() {
    local got; got="$(fans)"
    if [ "$got" != "$1" ]; then echo "FAIL: $2 (expected '$1', got '$got')"; exit 1; fi
    echo "ok: $2"
}
start() {
    "$work/helper" --fake-hardware "$work" --socket "$work/sock" "$@" & pid=$!
    for _ in $(seq 50); do [ -S "$work/sock" ] && return; sleep 0.1; done
    echo "FAIL: helper did not start"; exit 1
}
send_raw() {
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode()); s.shutdown(socket.SHUT_WR); print(s.recv(4096).decode())' "$work/sock" "$1"
}

echo '{"manual":[true,true],"targets":[4000,4000]}' > "$work/fans.json"
start
expect "auto 0,0" "start releases fans left in manual"

ctl set 3000 > /dev/null
expect "manual 3000,3000" "set 3000 drives both fans"
if ctl set 1000 > /dev/null; then echo "FAIL: set 1000 accepted"; exit 1; fi
expect "manual 3000,3000" "set below the fan minimum is refused"
ctl max > /dev/null
expect "manual 5349,5777" "max uses each fan's own maximum"
ctl auto > /dev/null
expect "auto 0,0" "auto releases"

send_raw 'garbage' | grep -q 'malformed' || { echo "FAIL: malformed request not rejected"; exit 1; }
echo "ok: malformed request rejected"
send_raw "$(python3 -c 'print("x" * 2000)')" | grep -q 'too large' || { echo "FAIL: oversized request not rejected"; exit 1; }
echo "ok: oversized request rejected"

ctl set 3000 > /dev/null; sleep 18
expect "auto 0,0" "no heartbeat for 15 s releases"

ctl set 3000 > /dev/null
for _ in 1 2 3 4 5; do sleep 4; ctl heartbeat > /dev/null; done
expect "manual 3000,3000" "heartbeats every 4 s keep the hold for 20 s"

echo 96 > "$work/temp"; sleep 3
expect "manual 5349,5777" "96 °C forces max"
ctl set 3500 | grep -q '"override":true' || { echo "FAIL: override not reported"; exit 1; }
echo "ok: helper reports the override"
expect "manual 5349,5777" "set during the override is not applied"
echo 85 > "$work/temp"; sleep 3
expect "manual 3500,3500" "below 90 °C restores the recorded hold"

echo none > "$work/temp"; sleep 8
expect "auto 0,0" "three unreadable sensor checks release"
rm "$work/temp"

ctl set 3000 > /dev/null; touch "$work/drift"; sleep 3
[ ! -e "$work/drift" ] || { echo "FAIL: drift was never read"; exit 1; }
expect "manual 3000,3000" "mode drift re-applies the hold"

kill -TERM "$pid"; wait "$pid" || true; pid=""
expect "auto 0,0" "SIGTERM releases"
[ ! -e "$work/sock" ] || { echo "FAIL: socket left behind"; exit 1; }
echo "ok: SIGTERM removes the socket"

start; ctl set 3000 > /dev/null
kill -9 "$pid"; wait "$pid" 2>/dev/null || true; pid=""
expect "manual 3000,3000" "kill -9 leaves the fans (launchd restarts the helper in production)"
start
expect "auto 0,0" "a restarted helper releases the fans"
kill -TERM "$pid"; wait "$pid" || true; pid=""

"$work/helper" --fake-hardware "$work" --socket "$work/sock-other" --owner-uid 12345 & pid=$!
for _ in $(seq 50); do [ -S "$work/sock-other" ] && break; sleep 0.1; done
if FANBUTTON_SOCKET="$work/sock-other" "$work/helperctl" state > /dev/null 2>&1; then
    echo "FAIL: a caller that isn't the owner was served"; exit 1
fi
echo "ok: callers other than the owner uid are refused"

echo "All helper integration checks passed"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/helper-integration.sh`
Expected: FAIL at compile — `error opening input file 'tools/helperctl/main.swift'` or missing `SMCFans`.

- [ ] **Step 3: Write `Helper/SMCFans.swift`**

```swift
import Foundation

struct FanWriteError: LocalizedError {
    let errorDescription: String?
}

/// The real fan controller, over the SMC. Every write needs root.
final class SMCFans: FanHardware {
    private let smc: SMCConnection

    init(smc: SMCConnection) { self.smc = smc }

    func limits() -> [FanLimits]? {
        smc.fans().map { $0.map { FanLimits(min: Int($0.min.rounded()), max: Int($0.max.rounded())) } }
    }

    func setManual(_ targets: [Int]) throws {
        for (fan, rpm) in targets.enumerated() {
            // The SMC can refuse the mode switch for a moment after a change; retry for up to 10 s.
            let deadline = Date().addingTimeInterval(10)
            while !smc.write("F\(fan)md", [1]) {
                guard Date() < deadline else { throw FanWriteError(errorDescription: "Fan \(fan + 1) wouldn't switch to manual.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard smc.write("F\(fan)Tg", smcBytes(Float(rpm))) else {
                throw FanWriteError(errorDescription: "Fan \(fan + 1) refused \(rpm) rpm.")
            }
        }
    }

    func setAuto() {
        let count = smc.fans()?.count ?? 2
        for fan in 0..<count {
            _ = smc.write("F\(fan)md", [0])
            _ = smc.write("F\(fan)Tg", smcBytes(0))
        }
    }

    func allManual() -> Bool? { smc.fans()?.allSatisfy(\.manual) }

    func safetyTemp() -> Float? {
        [smc.peak(Sensors.cpu), smc.peak(Sensors.gpu)].compactMap { $0 }.max()
    }
}
```

- [ ] **Step 4: Write `Helper/FakeFans.swift`**

```swift
import Foundation

/// Stand-in fans for testing the helper without root (`--fake-hardware DIR`).
/// State lives in DIR/fans.json. Tests write DIR/temp (a number, or "none" for unreadable)
/// and create DIR/drift to simulate macOS resetting the fans, for example after sleep.
final class FakeFans: FanHardware {
    private struct Snapshot: Codable {
        var manual: [Bool]
        var targets: [Int]
    }

    private let directory: URL
    private let fanLimits = [FanLimits(min: 1350, max: 5349), FanLimits(min: 1350, max: 5777)]
    private var snapshot = Snapshot(manual: [false, false], targets: [0, 0])
    private var file: URL { directory.appendingPathComponent("fans.json") }

    init(directory: String) {
        self.directory = URL(fileURLWithPath: directory)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        }
    }

    func limits() -> [FanLimits]? { fanLimits }

    func setManual(_ targets: [Int]) throws {
        snapshot = Snapshot(manual: targets.map { _ in true }, targets: targets)
        save()
    }

    func setAuto() {
        snapshot = Snapshot(manual: [false, false], targets: [0, 0])
        save()
    }

    func allManual() -> Bool? {
        let drift = directory.appendingPathComponent("drift")
        if FileManager.default.fileExists(atPath: drift.path) {
            try? FileManager.default.removeItem(at: drift)
            snapshot.manual = [false, false]
            save()
        }
        return snapshot.manual.allSatisfy { $0 }
    }

    func safetyTemp() -> Float? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("temp"), encoding: .utf8) else { return 60 }
        return Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func save() {
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}
```

- [ ] **Step 5: Write `Helper/main.swift`**

```swift
import Foundation

// fanbutton-helper: FanButton's root fan controller, run by launchd as local.fanbutton.helper.
// Usage: fanbutton-helper [--owner-uid N] [--socket PATH] [--fake-hardware DIR]

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fanbutton-helper: \(message)\n".utf8))
    exit(1)
}

let socketPath = argument("--socket") ?? HelperProtocol.socketPath

let ownerUID: uid_t
if let value = argument("--owner-uid") {
    guard let uid = uid_t(value) else { fail("--owner-uid must be a number") }
    ownerUID = uid
} else if getuid() != 0 {
    ownerUID = getuid()
} else {
    fail("--owner-uid is required when running as root")
}

let hardware: FanHardware
if let directory = argument("--fake-hardware") {
    hardware = FakeFans(directory: directory)
} else {
    guard let smc = SMCConnection() else { fail("can't open the SMC") }
    hardware = SMCFans(smc: smc)
}

// Every call into the core runs on this queue.
let queue = DispatchQueue(label: "local.fanbutton.helper.core")
let core = queue.sync { HelperCore(hardware: hardware, now: Date.init) }

signal(SIGPIPE, SIG_IGN)

// Socket: created with a 077 umask so it is never world-accessible, then owned by the user.
unlink(socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0, var address = unixSocketAddress(socketPath) else { fail("can't create the socket") }
let oldMask = umask(0o077)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
umask(oldMask)
guard bound == 0 else { fail("bind \(socketPath): \(String(cString: strerror(errno)))") }
guard chmod(socketPath, 0o600) == 0 else { fail("chmod \(socketPath) failed") }
if getuid() == 0, chown(socketPath, ownerUID, 0) != 0 { fail("chown \(socketPath) failed") }
guard listen(listener, 8) == 0 else { fail("listen failed") }

func respond(_ client: Int32, _ response: HelperResponse) {
    var out = (try? JSONEncoder().encode(response)) ?? Data()
    out.append(0x0A)
    _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
}

func serve(_ client: Int32) {
    defer { close(client) }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == ownerUID || uid == 0 else { return }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var frame = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while !frame.contains(0x0A), frame.count <= HelperProtocol.maxFrame {
        let n = read(client, &buffer, buffer.count)
        if n <= 0 { break }
        frame.append(buffer, count: n)
    }
    guard frame.count <= HelperProtocol.maxFrame else {
        return respond(client, HelperResponse(ok: false, error: "request too large"))
    }
    guard let line = frame.split(separator: 0x0A).first,
          let request = try? JSONDecoder().decode(HelperRequest.self, from: Data(line)) else {
        return respond(client, HelperResponse(ok: false, error: "malformed request"))
    }
    respond(client, queue.sync { core.handle(request) })
}

Thread {
    while true {
        let client = accept(listener, nil, nil)
        if client >= 0 { serve(client) }
    }
}.start()

let ticker = DispatchSource.makeTimerSource(queue: queue)
ticker.schedule(deadline: .now() + 2, repeating: 2)
ticker.setEventHandler { core.tick() }
ticker.resume()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler {
        core.shutdown()
        unlink(socketPath)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
```

- [ ] **Step 6: Write `App/HelperClient.swift`**

```swift
import Foundation

enum HelperClientError: LocalizedError, Equatable {
    case notInstalled
    case io(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The fan helper isn't installed. Use Install fan helper in the panel."
        case .io(let detail): return "Couldn't reach the fan helper: \(detail)"
        case .badResponse: return "The fan helper sent back something unexpected."
        }
    }
}

/// Talks to fanbutton-helper over its Unix socket. Calls block; keep them off the main thread,
/// except the short `auto` sent while quitting.
enum HelperClient {
    /// FANBUTTON_SOCKET points the app and helperctl at a test helper.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["FANBUTTON_SOCKET"] ?? HelperProtocol.socketPath
    }

    static func send(_ request: HelperRequest, timeout: TimeInterval = 12) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperClientError.io("socket() failed") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        guard var address = unixSocketAddress(socketPath) else { throw HelperClientError.io("socket path too long") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw HelperClientError.notInstalled }
            throw HelperClientError.io(String(cString: strerror(errno)))
        }

        var frame = try JSONEncoder().encode(request)
        frame.append(0x0A)
        let written = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == frame.count else { throw HelperClientError.io("write failed") }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 4096 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        guard let line = data.split(separator: 0x0A).first,
              let response = try? JSONDecoder().decode(HelperResponse.self, from: Data(line)) else {
            throw HelperClientError.badResponse
        }
        return response
    }
}
```

- [ ] **Step 7: Write `tools/helperctl/main.swift`**

```swift
import Foundation

// Command-line client for fanbutton-helper. Honours FANBUTTON_SOCKET.
// Usage: helperctl state | heartbeat | auto | max | set RPM
// Prints the helper's JSON reply. Exit 0 = ok, 1 = refused, 2 = couldn't talk to the helper.
let args = Array(CommandLine.arguments.dropFirst())
let request: HelperRequest
switch (args.first, args.count) {
case ("set", 2):
    guard let rpm = Int(args[1]) else { print("RPM must be a number"); exit(2) }
    request = HelperRequest(cmd: .set, rpm: rpm)
case (let name?, 1):
    guard let command = HelperRequest.Command(rawValue: name), command != .set else {
        print("usage: helperctl state|heartbeat|auto|max|set RPM"); exit(2)
    }
    request = HelperRequest(cmd: command)
default:
    print("usage: helperctl state|heartbeat|auto|max|set RPM"); exit(2)
}

do {
    let response = try HelperClient.send(request)
    print(String(data: try JSONEncoder().encode(response), encoding: .utf8)!)
    exit(response.ok ? 0 : 1)
} catch {
    print(error.localizedDescription)
    exit(2)
}
```

- [ ] **Step 8: Run the unit tests and the integration test**

Run: `bash tests/run.sh && bash tests/helper-integration.sh`
Expected: `All N checks passed`, then every line `ok: …`, ending `All helper integration checks passed`, exit 0.

- [ ] **Step 9: Commit**

```bash
git add Helper App/HelperClient.swift tools/helperctl tests/helper-integration.sh && git commit -m "Add fanbutton-helper: socket server, SMC fans, fake fans and end-to-end test

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: App uses the helper, with install, update and uninstall

**Files:**
- Create: `App/HelperInstaller.swift`, `Resources/install-helper.sh`, `Resources/uninstall-helper.sh`, `tools/render-views/main.swift`
- Replace: `App/FanModel.swift`
- Modify: `App/Views.swift` (`PanelView`), `App/FanButton.swift` (quit), `build.sh`
- Delete: `App/ThermalForge.swift`

**Interfaces:**
- Consumes: `HelperClient`, `HelperClientError`, `HelperRequest`, `HelperProtocol` (Tasks 3, 5); `ThermalStatus.read()` (Task 1).
- Produces: `enum HelperStatus { case unknown, missing, outdated, ready }`; `FanModel.helper`, `installHelper()`, `uninstallHelper()`, `releaseFans()`; `HelperInstaller.install() throws`, `HelperInstaller.uninstall() throws`.

- [ ] **Step 1: Write `Resources/install-helper.sh`**

```bash
#!/bin/bash
# Installs FanButton's fan helper as a root launchd daemon. Run as root by HelperInstaller:
#   install-helper.sh HELPER_BINARY OWNER_UID
set -euo pipefail
src="$1"; uid="$2"
[[ "$uid" =~ ^[0-9]+$ ]] || { echo "owner uid must be a number" >&2; exit 1; }
[ -x "$src" ] || { echo "helper binary not found: $src" >&2; exit 1; }

label=local.fanbutton.helper
dest="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"

launchctl bootout "system/$label" 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools
# Root runs this copy, never the app bundle, which the user can modify.
install -o root -g wheel -m 755 "$src" "$dest"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$dest</string><string>--owner-uid</string><string>$uid</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>/var/log/fanbutton-helper.log</string>
</dict></plist>
PLIST
chown root:wheel "$plist"
chmod 644 "$plist"
launchctl bootstrap system "$plist"
```

- [ ] **Step 2: Write `Resources/uninstall-helper.sh`**

```bash
#!/bin/bash
# Removes FanButton's fan helper. Stopping it hands the fans back to macOS. Run as root by HelperInstaller.
set -euo pipefail
label=local.fanbutton.helper
launchctl bootout "system/$label" 2>/dev/null || true
rm -f "/Library/PrivilegedHelperTools/$label" "/Library/LaunchDaemons/$label.plist" /var/run/fanbutton.sock
```

- [ ] **Step 3: Write `App/HelperInstaller.swift`**

```swift
import AppKit

/// Installs and removes fanbutton-helper through the standard macOS administrator prompt.
enum HelperInstaller {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func install() throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "fanbutton-helper")?.path else {
            throw Failure(errorDescription: "The helper is missing from FanButton.app. Rebuild with build.sh.")
        }
        try runAsAdmin("install-helper", [helper, String(getuid())])
    }

    static func uninstall() throws {
        try runAsAdmin("uninstall-helper", [])
    }

    /// Runs a bundled script as root. Returns quietly if the user cancels the password prompt.
    private static func runAsAdmin(_ script: String, _ arguments: [String]) throws {
        guard let path = Bundle.main.path(forResource: script, ofType: "sh") else {
            throw Failure(errorDescription: "\(script).sh is missing from FanButton.app. Rebuild with build.sh.")
        }
        let command = (["/bin/bash", path] + arguments).map(shellQuoted).joined(separator: " ")
        let source = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return }
        throw Failure(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "The helper script failed.")
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Replace `App/FanModel.swift`**

```swift
import Foundation

/// Whether fanbutton-helper is there to take commands.
enum HelperStatus: Equatable {
    case unknown, missing, outdated, ready
}

/// Live fan readings shared by the menu-bar panel and the desktop widget.
final class FanModel: ObservableObject {
    @Published private(set) var status: ThermalStatus?
    /// Why the last button press failed; kept until the next press.
    @Published private(set) var actionError: String?
    /// Why the latest reading failed; cleared by the next good one.
    @Published private(set) var readError: String?
    @Published private(set) var busy = false
    @Published private(set) var helper: HelperStatus = .unknown
    @Published var target: Double = 0

    private var timer: Timer?
    private var heartbeat: Timer?
    private var viewers = 0
    private var refreshing = false
    /// The fastest fan speed macOS picked on its own at the last reading taken in automatic mode.
    private var autoRpm: Int?

    init() {
        // The helper hands the fans back to macOS when these stop for 15 s, so they run for the app's whole life.
        beat()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.beat() }
    }

    var error: String? { actionError ?? readError }

    var isManual: Bool { status?.fans.contains { $0.manual } ?? false }

    /// Slider bottom: never below the speed macOS chose itself, so a manual setting can only speed fans up.
    var floor: Int {
        guard let fans = status?.fans, !fans.isEmpty else { return 0 }
        let hardwareMin = fans.map(\.minRpm).max() ?? 0
        return max(autoRpm ?? fans.map(\.actualRpm).max() ?? 0, hardwareMin)
    }

    /// Slider top: a set drives every fan, so stop at the slowest fan's maximum.
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

    func boost() { perform(HelperRequest(cmd: .max)) }
    func automatic() { perform(HelperRequest(cmd: .auto)) }
    func apply() { perform(HelperRequest(cmd: .set, rpm: Int(target))) }

    func installHelper() { runInstaller(HelperInstaller.install) }
    func uninstallHelper() { runInstaller(HelperInstaller.uninstall) }

    /// Hands the fans back to macOS before the app exits. Blocks for at most 2 s.
    func releaseFans() {
        _ = try? HelperClient.send(HelperRequest(cmd: .auto), timeout: 2)
    }

    private func runInstaller(_ action: () throws -> Void) {
        actionError = nil
        do { try action() } catch { actionError = error.localizedDescription }
        beat()
    }

    private func beat() {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try HelperClient.send(HelperRequest(cmd: .heartbeat), timeout: 3) }
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    self.helper = response.version == HelperProtocol.version ? .ready : .outdated
                case .failure(let error as HelperClientError) where error == .notInstalled:
                    self.helper = .missing
                case .failure:
                    // Busy or slow (a mode switch can take seconds): keep the last known status.
                    if self.helper == .unknown { self.helper = .missing }
                }
            }
        }
    }

    private func perform(_ request: HelperRequest) {
        busy = true
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                let response = try HelperClient.send(request)
                failure = response.ok ? nil : (response.error ?? "The fan helper refused the command.")
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
            let result = Result { try ThermalStatus.read() }
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
```

- [ ] **Step 5: Replace `PanelView` in `App/Views.swift`**

Replace the whole `struct PanelView: View { … }` (keep `speedControl` as it is today inside it) with:

```swift
/// What the menu-bar icon opens.
struct PanelView: View {
    @ObservedObject var model: FanModel
    var onPopOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadingsView(model: model)
            Divider()
            switch model.helper {
            case .ready:
                speedControl
                HStack {
                    Button("Boost fans", action: model.boost)
                    Button("Automatic (macOS)", action: model.automatic)
                }
                .disabled(model.busy || model.status == nil)
            case .missing, .outdated:
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.helper == .missing
                         ? "Fan control needs FanButton's helper, which runs as administrator. You'll be asked for your password once."
                         : "The fan helper is from an older FanButton. Update it to keep controlling the fans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.helper == .missing ? "Install fan helper" : "Update fan helper", action: model.installHelper)
                }
            case .unknown:
                Text("Checking the fan helper…").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Pop out as widget", action: onPopOut)
                Spacer()
                if model.helper == .ready || model.helper == .outdated {
                    Menu("More") {
                        Button("Reinstall fan helper", action: model.installHelper)
                        Button("Uninstall fan helper", action: model.uninstallHelper)
                    }
                    .fixedSize()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    // speedControl: unchanged from the current file
}
```

(Copy the existing `@ViewBuilder private var speedControl: some View { … }` body in place of the last comment, unchanged.)

- [ ] **Step 6: Release the fans on Quit in `App/FanButton.swift`**

After `func applicationDidFinishLaunching(_ notification: Notification) { … }` add:

```swift
    /// Quit hands the fans straight back to macOS instead of waiting for the helper's 15 s timeout.
    func applicationWillTerminate(_ notification: Notification) {
        model.releaseFans()
    }
```

- [ ] **Step 7: Delete ThermalForge and update `build.sh`**

```bash
git rm App/ThermalForge.swift
```

In `build.sh`, after the app `swiftc` line add:

```bash
swiftc -O Helper/*.swift Shared/*.swift -o FanButton.app/Contents/MacOS/fanbutton-helper
cp Resources/install-helper.sh Resources/uninstall-helper.sh FanButton.app/Contents/Resources/
```

- [ ] **Step 8: Write the view renderer `tools/render-views/main.swift`**

```swift
import AppKit
import SwiftUI

// Renders the panel and widget offscreen to PNGs (the terminal can't screenshot the menu bar).
// Usage: FANBUTTON_SOCKET=… render-views OUTDIR
let out = CommandLine.arguments[1]
NSApplication.shared.setActivationPolicy(.accessory)

func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func snap<V: View>(_ view: V, _ name: String, dark: Bool = false) {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.backgroundColor = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    wait(0.3)
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

let model = FanModel()
model.startWatching()
wait(2)
print("helper=\(model.helper) fans=\(model.status?.fans.map { "\($0.actualRpm)/\($0.manual)" } ?? []) cpu=\(model.status?.cpu ?? -1) gpu=\(model.status?.gpu ?? -1) error=\(model.error ?? "nil")")
snap(PanelView(model: model, onPopOut: {}), "panel")
snap(PanelView(model: model, onPopOut: {}), "panel-dark", dark: true)
snap(WidgetView(model: model, onClose: {}), "widget")
```

- [ ] **Step 9: Build and render with no helper, then with the fake helper**

```bash
bash build.sh
S="$SCRATCH/render"; mkdir -p "$S/none" "$S/fake"
swiftc App/FanModel.swift App/Views.swift App/Readings.swift App/HelperClient.swift App/HelperInstaller.swift Shared/*.swift tools/render-views/main.swift -o "$S/render"
FANBUTTON_SOCKET="$S/none.sock" "$S/render" "$S/none"
swiftc Helper/*.swift Shared/*.swift -o "$S/helper"
"$S/helper" --fake-hardware "$S/fake" --socket "$S/fake.sock" & hp=$!; sleep 1
FANBUTTON_SOCKET="$S/fake.sock" "$S/render" "$S/fake"; kill $hp
```

Expected: first run prints `helper=missing` and `panel.png` shows the "Install fan helper" button with Boost/Automatic hidden. Second run prints `helper=ready` and `panel.png` shows the slider, Boost, Automatic and the More menu. Open both PNGs with the Read tool and look at them.

- [ ] **Step 10: Run all tests**

Run: `bash tests/run.sh && bash tests/helper-integration.sh`
Expected: both pass.

- [ ] **Step 11: Commit**

```bash
git add -A && git commit -m "Control the fans through fanbutton-helper; drop ThermalForge from the app

The panel installs, updates and uninstalls the helper through the macOS
administrator prompt, sends a heartbeat every 5 s, and hands the fans back
to macOS on Quit.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Install on the Mac and pass Gates 2, 3 and 4 (with the user)

**Files:**
- Modify: `docs/verification/2026-09-23-helper-safety.md`

**Interfaces:**
- Consumes: the built `/Applications/FanButton.app`, `tools/helperctl`, `tools/fan-probe`.

Steps marked **(user)** need the user's password or a `sudo` command; ask for them explicitly and wait.

- [ ] **Step 1: Build tools and stop anything else driving the fans**

```bash
S="$SCRATCH/gates"; mkdir -p "$S"
swiftc -O tools/helperctl/main.swift App/HelperClient.swift Shared/Protocol.swift -o "$S/helperctl"
swiftc -O tools/fan-probe/main.swift Shared/SMC.swift -o "$S/fan-probe"
thermalforge auto; pgrep -lf ThermalForge.app || echo "ThermalForge app not running"
```

Expected: `Fans reset to Apple defaults`, and no ThermalForge app running (ask the user to quit it if it is).

- [ ] **Step 2 (user): Install the helper**

Relaunch `/Applications/FanButton.app`, ask the user to open the panel, click **Install fan helper** and enter their password. Then:

```bash
launchctl print system/local.fanbutton.helper | grep -E 'state|pid'; ls -l /var/run/fanbutton.sock /Library/PrivilegedHelperTools/local.fanbutton.helper; "$S/helperctl" state
```

Expected: `state = running`, a pid, socket `srw-------` owned by the user, helper binary `-rwxr-xr-x root wheel`, and `helperctl state` prints `{"ok":true,…,"temp":…}`.

- [ ] **Step 3: Gate 4 on hardware — the helper reads the Gate 1 sensors**

```bash
"$S/helperctl" state; "$S/fan-probe"
```

Expected: `temp` from the helper is within 1 °C of `max(cpu, gpu)` from the probe. Record both numbers.

- [ ] **Step 4: Gate 2 — helper crash while holding 3,000 rpm**

```bash
"$S/helperctl" set 3000; sleep 2; "$S/fan-probe"
old=$(launchctl print system/local.fanbutton.helper | awk '/pid =/{print $3}'); echo "helper pid $old"
"$S/fan-probe" watch 90 > "$S/gate2-set.log" &
```

Expected before the kill: `F0md=1 F0Tg=3000 F1md=1 F1Tg=3000`. Then **(user)** ask the user to run in Terminal, within 60 s: `sudo kill -9 <pid>`. After the watch finishes:

```bash
new=$(launchctl print system/local.fanbutton.helper | awk '/pid =/{print $3}'); echo "old $old new $new"
grep -n 'F0md=0' "$S/gate2-set.log" | head -1; head -3 "$S/gate2-set.log"; tail -3 "$S/gate2-set.log"
```

Pass: new pid ≠ old pid; the first `F0md=0 … F1md=0` line appears within 10 s of the kill (the kill time is the last line still showing `F0md=1` before the helper's pid changed — use the timestamps in the log). Record the time.

- [ ] **Step 5: Gate 2 — helper crash while holding max**

Repeat Step 4 with `"$S/helperctl" max` (expect `F0Tg=5349 F1Tg=5777` before the kill) and log to `gate2-max.log`. Same pass rule.

- [ ] **Step 6: Gate 3 — FanButton crash**

With FanButton running and the helper ready:

```bash
"$S/helperctl" set 3000; sleep 1; "$S/fan-probe" watch 30 > "$S/gate3-crash.log" & sleep 1
pkill -9 -f MacOS/FanButton; wait
```

FanButton's last heartbeat was at most 5 s before the kill, so the 15 s clock starts then. Pass: `F0md=0 … F1md=0` appears within 20 s of the kill (the kill happens about 1 s into the log). Record the time.

- [ ] **Step 7: Gate 3 — Quit**

Relaunch FanButton; ask the user to press **Apply** at 3,000 rpm, then start `"$S/fan-probe" watch 15 > "$S/gate3-quit.log" &` and ask them to choose **Quit** straight away. Pass: `F0md=0` appears within 3 s of the Quit. Record the time.

- [ ] **Step 8: Record Gates 2–4 in the verification doc**

Append to `docs/verification/2026-09-23-helper-safety.md`:

```markdown
## Gate 2: helper crash — PASS|FAIL (date)

| Hold | Before kill | Old → new pid | Time to Automatic |
|---|---|---|---|
| set 3000 | F0md=1 F0Tg=3000 F1md=1 F1Tg=3000 | … → … | … s |
| max | F0md=1 F0Tg=5349 F1md=1 F1Tg=5777 | … → … | … s |

## Gate 3: app crash and Quit — PASS|FAIL (date)

| Case | Time to Automatic | Limit |
|---|---|---|
| kill -9 FanButton | … s after the last heartbeat | 20 s |
| Quit | … s | 3 s |

## Gate 4: thermal override — PASS|FAIL (date)

- Decision logic: `bash tests/run.sh` (engage at 95.0, no engage at 94.9, hold at 90.0, restore at 89.9).
- Whole helper with fake temperatures: `bash tests/helper-integration.sh` (96 °C → max, set recorded during override, 85 °C → restore).
- On hardware: helper `temp` = … °C, probe max(cpu, gpu) = … °C.
```

Fill every `…` from the logs. If any gate fails, mark it FAIL, stop, and report to the user before changing code.

- [ ] **Step 9: Commit**

```bash
git add docs/verification && git commit -m "Record helper safety gates 2-4 on the M5 Pro

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Remove ThermalForge (Gate 5) and update the README

**Files:**
- Modify: `README.md`, `docs/verification/2026-09-23-helper-safety.md`, `docs/superpowers/specs/2026-09-23-own-fan-helper-design.md` (status line)

- [ ] **Step 1: Confirm Gates 1–4 all say PASS**

```bash
grep -E '^## Gate [1-4]' docs/verification/2026-09-23-helper-safety.md
```

Expected: four lines, each containing `PASS`. If not, stop.

- [ ] **Step 2 (user): Uninstall ThermalForge**

Ask the user to run in Terminal:

```bash
cd ~/Developer/ThermalForge && ./uninstall.sh
```

(`uninstall.sh` is ThermalForge's own script from the clone used to install it; it asks for their password.)

- [ ] **Step 3: Gate 5 checks**

```bash
S="$SCRATCH/gates"   # helperctl and fan-probe from Task 7 Step 1
command -v thermalforge || echo "thermalforge gone"
ls /Library/LaunchDaemons | grep -i thermalforge || echo "no ThermalForge daemon"
launchctl print system/local.fanbutton.helper | grep -E 'state = running'
"$S/helperctl" set 3000 && sleep 2 && "$S/fan-probe" && "$S/helperctl" auto && sleep 2 && "$S/fan-probe"
```

Expected: `thermalforge gone`, `no ThermalForge daemon`, `state = running`, then `F0Tg=3000 F1Tg=3000` followed by `F0md=0 F1md=0`.

- [ ] **Step 4: Record Gate 5** in the verification doc (`## Gate 5: ThermalForge removal — PASS (date)` with the command output), and change the spec's `Status:` line to `implemented and verified on Mac17,8 (see docs/verification/2026-09-23-helper-safety.md)`.

- [ ] **Step 5: Rewrite the README's setup and testing sections**

Replace the text from `The app drives ThermalForge's` through the end of the file with:

```markdown
FanButton reads the fans and temperatures itself and changes fan speed through its own small helper, which runs as administrator. The slider never goes below the speed macOS last picked on its own, so a manual speed only ever makes the fans faster than Apple's automatic setting.

The helper hands the fans back to macOS whenever FanButton isn't watching: when you choose Quit, when FanButton stops checking in for 15 seconds, when the helper itself restarts, and when it is uninstalled. While you hold a manual speed below max it forces full speed at 95 °C and returns to your setting below 90 °C. The CPU and GPU sensors it watches were measured on an M5 Pro; see `docs/verification/2026-09-23-helper-safety.md`.

## On your Mac

1. Install Xcode Command Line Tools if needed: `xcode-select --install`
2. In Terminal, go into this `FanButton` folder and run `bash build.sh`. It builds the app and copies it into your Applications folder.
3. Open **FanButton** from Spotlight (⌘ Space, type "FanButton"), Launchpad or Applications, then click the fan icon in the menu bar.
4. Click **Install fan helper** and enter your password. This happens once; after a rebuild, use **More → Reinstall fan helper**.

FanButton lives only in the menu bar, so it has no Dock icon while it runs. After you choose **Quit**, open it again the same way from Spotlight or Applications. Opening it while it's already running pops the panel open. To start it with your Mac, add it under System Settings → General → Login Items.

Readings refresh every 2 seconds, and only while the panel or the widget is open. **More → Uninstall fan helper** removes the helper and hands the fans back to macOS.

This has been tested only on a 16-inch MacBook Pro M5 Pro (`Mac17,8`). Other Macs use different fan and sensor keys.

## Tests

- `bash tests/run.sh` — safety rules, protocol and helper state machine.
- `bash tests/helper-integration.sh` — the real helper binary against fake fans, no password needed (about 75 s).

The SMC code in `Shared/SMC.swift` is adapted from [ThermalForge](https://github.com/ProducerGuy/ThermalForge) (MIT).
```

- [ ] **Step 6: Final build, tests and push**

```bash
bash build.sh && bash tests/run.sh && bash tests/helper-integration.sh && git add -A && git commit -m "Remove ThermalForge; document FanButton's own helper

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" && git push
```

Expected: all pass, push succeeds.

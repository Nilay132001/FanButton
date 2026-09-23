# FanButton's own fan helper (drop ThermalForge)

Date: 2026-09-23
Status: approved design, not yet implemented

## Goal

FanButton controls the fans without ThermalForge. The app reads temperatures and fan speeds itself, and a small root helper that ships with FanButton does the fan writes. Once the helper is verified on the target Mac, ThermalForge gets uninstalled.

Target machine: MacBook Pro M5 Pro, `Mac17,8`, macOS 26.6.2. A read-only probe on this Mac found:

- `FNum` = 2 fans.
- No `Ftst` key, so the M1–M4 unlock step doesn't apply.
- Fan mode is the lowercase key `F0md` / `F1md` (ui8, 0 = auto, 1 = manual). The uppercase `F%dMd` keys don't exist.
- `F%dAc`, `F%dTg`, `F%dMn` and `F%dMx` are little-endian floats. Min is 1,350 on both fans; max is 5,349 on fan 0 and 5,777 on fan 1.
- All of these read without root. Only writes need root.

## Pieces

```
FanButton.app (runs as the user)            fanbutton-helper (runs as root, launchd)
├─ Shared/SMC.swift   reads temps + fans    ├─ Shared/SMC.swift   also writes
├─ HelperClient       max/set/auto/beat ───►├─ /var/run/fanbutton.sock (owner uid, 0600)
├─ HelperInstaller    admin prompt          ├─ watchdog, thermal override, mode check
└─ FanModel / Views   as today              └─ resets to auto on start and on SIGTERM
```

- **Reading** runs inside the app every 2 s while the panel or the widget is open, as today. It never goes through the helper, so readings keep working when the helper is missing.
- **Writing** is only done by the helper, and only for three commands: `max`, `set <rpm>` and `auto`.
- The slider floor (never below the speed macOS last picked itself) stays enforced in the app.
- The SMC access code is adapted from ThermalForge's `SMCConnection.swift` and `SMCKeys.swift` (MIT, credited in the file header). The helper's server, watchdog and override are new code.
- Layout:
  - `Shared/SMC.swift`, `Shared/Protocol.swift`: used by both halves.
  - `Helper/main.swift`: the helper.
  - `App/*.swift`: the app. `ThermalForge.swift` is replaced by `HelperClient.swift` and `HelperInstaller.swift`.
  - `build.sh`: builds both and puts the helper binary and its install script inside the app bundle.

## Protocol

- One JSON line per connection, capped at 1 KB. Anything larger or malformed is rejected.
- Requests: `{"cmd":"max"}`, `{"cmd":"set","rpm":3000}`, `{"cmd":"auto"}`, `{"cmd":"heartbeat"}`, `{"cmd":"state"}`.
- Responses: `{"ok":true,"version":1,"hold":"set 3000","override":false}`, or `{"ok":false,"error":"..."}`.
- The helper checks the caller's uid on every connection with `getpeereid`. Only the owner uid (given at install) and root are accepted.

## Safety rules

The helper is always either **Automatic** or **Holding** a command (`max` or `set <rpm>`). It remembers when the app last checked in.

| Event | Helper behaviour |
|---|---|
| `max` / `set` | Put each fan in manual (`F%dmd` = 1, retried for up to 10 s), then write each fan's target (`F%dTg`). `set` is refused unless `max(fan mins) ≤ rpm ≤ min(fan maxes)`. `max` writes each fan's own `F%dMx`. |
| `auto` | Write `F%dmd` = 0 and `F%dTg` = 0 on every fan and clear the hold. |
| Heartbeat | The app sends one every 5 s for its whole lifetime, on a timer separate from the readings. |
| App quits | The app sends `auto` in `applicationWillTerminate`. |
| App crashes or hangs | No heartbeat for 15 s → Automatic. |
| Temperature ≥ 95 °C while holding below max | Checked every 2 s. Force every fan to max. Below 90 °C, re-apply the hold. A `set` that arrives during the override is recorded, not applied. |
| Temperature unreadable | If no verified safety sensor can be read for 3 checks in a row while holding below max → Automatic. |
| Mode drift (sleep/wake, anything else) | Every 2 s, compare the fan modes with the hold. If they drifted: re-apply the hold when the app is still checking in, otherwise go to Automatic. |
| Helper starts | Always writes Automatic first. With launchd `KeepAlive`, a crashed helper comes back and releases the fans. |
| Helper gets SIGTERM (uninstall, shutdown) | Writes Automatic, then exits. |

The watchdog, override and speed-check decisions live in pure functions with an injected clock and temperature, so they can be tested without hardware.

## Install and uninstall

- The panel shows **Install fan helper** when the socket is missing, and **Update fan helper** when the helper reports an older protocol version.
- Install runs the bundled `install-helper.sh <uid>` through `do shell script … with administrator privileges`, which shows the standard macOS password prompt. The script:
  1. Copies the helper to `/Library/PrivilegedHelperTools/local.fanbutton.helper` (root:wheel, 755). It runs from that copy, never from the app bundle, because the user can modify the bundle.
  2. Writes `/Library/LaunchDaemons/local.fanbutton.helper.plist` (root:wheel, 644) with `RunAtLoad`, `KeepAlive` and the owner uid in `ProgramArguments`.
  3. Runs `launchctl bootout` for any old copy, then `launchctl bootstrap system`.
- **Uninstall helper** runs `launchctl bootout` (the helper resets to Automatic on SIGTERM) and removes both files.

## Verification gates

The safety rules count as complete only after every gate below passes on the `Mac17,8`. Each result, with the commands used and the numbers observed, is recorded in `docs/verification/2026-09-23-helper-safety.md`.

### Gate 1: CPU/GPU safety sensors on this M5 Pro

Earlier readings suggest the `TC`/`Tp`/`TG`/`Tg` prefixes include sensors that are not the CPU or GPU die: `TG0B` read 34.5 °C while `Tg0j` read 64.7 °C. The override must not depend on a sensor that sits near room temperature.

1. List every `T*` key on this Mac by walking the SMC key index (read-only), and record idle values.
2. **CPU load:** run a load on every CPU core for 60 s, sampling every key at 1 Hz. Keys that rise clearly with the load and fall after it are CPU candidates.
3. **GPU load:** run a Metal compute load for 60 s, sampled the same way. Keys that rise clearly are GPU candidates.
4. Freeze the verified CPU and GPU key lists in `Shared/SMC.swift`. The helper's 95 °C override and the app's CPU/GPU readouts both use exactly these lists. No prefix matching.
5. **Pass:** each list has at least one key that follows its own load, and the app's CPU/GPU numbers match the hottest key in each list during the load runs.

### Gate 2: helper crash

1. With the helper installed, press Apply at 3,000 rpm. Confirm with the read-only probe: `F0md` = `F1md` = 1 and `F0Tg` = `F1Tg` = 3,000.
2. `sudo kill -9` the helper process.
3. **Pass:** launchd starts a new helper process (new PID). Within 10 s of the kill, the probe reads `F0md` = `F1md` = 0 and the fans follow macOS again. Record the time it took.
4. Repeat with a hold of `max` (expect `F0Tg`/`F1Tg` at each fan's own max in step 1).

### Gate 3: app crash and Quit

1. Hold `set 3000`, then `kill -9` FanButton. **Pass:** the fans are back on Automatic within 20 s (15 s timeout plus up to one 2 s check, with margin).
2. Hold `set 3000`, then choose **Quit**. **Pass:** the fans are back on Automatic within 3 s.

### Gate 4: thermal override

The real chip isn't pushed to 95 °C on purpose. The override is tested against the helper's decision function with injected temperatures (engage at 95, hold between 90 and 95, restore below 90), and by running the full helper with a fake temperature source. The only on-hardware check is that the override reads the Gate 1 sensors.

### Gate 5: ThermalForge removal

Only after Gates 1–4 pass, the user runs ThermalForge's uninstaller. Afterwards: `thermalforge` is gone, FanButton still reads and controls the fans, and `launchctl print system/local.fanbutton.helper` shows the helper running.

## Out of scope

- Fan curves and profiles. The app keeps today's controls: slider, Boost, Automatic.
- Per-fan speed control.
- Code signing with an Apple Developer ID and `SMAppService`.

# FanButton

A menu-bar fan control for an M5 Pro MacBook Pro. Click the fan icon to see live CPU and GPU temperatures and each fan's speed, set a fan speed with a slider, or pick **Boost fans** or **Automatic (macOS)**. **Pop out as widget** puts a small floating window with the temperatures and fan speeds on your desktop. Drag it anywhere; it stays on top, shows on every Space, and comes back where you left it the next time FanButton starts.

The app drives ThermalForge's `status`, `set`, `max` and `auto` commands. The slider never goes below the speed macOS last picked on its own, so a manual speed only ever makes the fans faster than Apple's automatic setting. ThermalForge still applies its own limits on top: it forces full speed at 95°C and resets to Apple defaults within 15 seconds if its app crashes.

## On your Mac

1. Install Xcode Command Line Tools if needed: `xcode-select --install`
2. Install ThermalForge following its [official instructions](https://github.com/ProducerGuy/ThermalForge#install). Its installation uses an administrator password to set up the fan-control service. The project's compatibility list reports both 14-inch and 16-inch M5 Pro MacBook Pros; this app has not been tested on your Mac.
3. In Terminal, go into this `FanButton` folder and run `bash build.sh`.
4. Open `FanButton.app` and click the fan icon in the menu bar.

Run `thermalforge status` to confirm the controller sees your fans. If a button reports an error, the panel shows ThermalForge's exact message; send that along. Keep ThermalForge's own menu-bar app in **Default** mode or closed so its profile doesn't change the speed after you press Automatic.

Readings refresh every 2 seconds, and only while the panel or the widget is open.

Quit only closes FanButton; choose **Automatic (macOS)** first when you want to release manual control.

## Testing without ThermalForge

Set `THERMALFORGE_PATH` to any executable that answers `status`, `set <rpm>`, `max` and `auto` like ThermalForge does, then start the app binary directly:

```bash
THERMALFORGE_PATH=/path/to/fake-thermalforge FanButton.app/Contents/MacOS/FanButton
```

# FanButton

Two menu-bar buttons for an M5 Pro MacBook Pro: **Boost fans** and **Automatic (macOS)**. The app calls ThermalForge's `max` and `auto` commands. It never requests a fan speed below Apple's automatic setting.

## On your Mac

1. Install Xcode Command Line Tools if needed: `xcode-select --install`
2. Install ThermalForge following its [official instructions](https://github.com/ProducerGuy/ThermalForge#install). Its installation uses an administrator password to set up the fan-control service. The project's compatibility list reports both 14-inch and 16-inch M5 Pro MacBook Pros; this app has not been tested on your Mac.
3. In Terminal, go into this `FanButton` folder and run `bash build.sh`.
4. Open `FanButton.app`. Click the fan icon in the menu bar to select Boost or Automatic.

Run `thermalforge status` to confirm the controller sees your fans. If either button reports an error, send the exact error message. Keep ThermalForge's own menu-bar app in **Default** mode or closed so its profile doesn't change the speed after you press Automatic.

Quit only closes FanButton; choose **Automatic (macOS)** first when you want to release manual control.

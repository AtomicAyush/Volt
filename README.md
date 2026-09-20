# Volt

A battery menu bar app for macOS. Custom low-battery alerts at any level you choose,
battery health and lifecycle tracking, accessory batteries, and per-app energy use.

macOS only warns you at 10% and 5%, will not let you change those levels, and shows
nothing about the health of the pack. Volt fills that in.

![Panel](docs/panel.png)

## What it does

**Alerts you can actually configure.** Any number of low-battery levels, each with its
own sound and an optional repeat. Alerts are edge-triggered — they fire when the charge
crosses a level, not for as long as it stays there — and rearm when you plug in.

**Charging lifecycle.** Optional alerts for charger connected, charger pulled, reaching
80%, full charge, and the pack running hot.

**Health.** Capacity against design capacity, cycle count, condition, temperature, live
watts / volts / amps, and raw mAh. Where macOS reports its own "Maximum Capacity"
figure, that is shown in preference to the computed one.

**Other devices.** AirPods report left, right and case separately. Magic Mouse, Magic
Keyboard and Magic Trackpad come from the IO registry. iPhone and iPad battery is read
over Bluetooth, with no cable — see below.

**Energy use.** Which apps are draining the battery, using the same Energy Impact figure
Activity Monitor shows, with 24h / 7d / 30d history kept on disk and a callout when an
app climbs well above its own baseline.

![Alerts](docs/alerts.png)

## Install

```bash
xcodebuild -project Volt.xcodeproj -scheme Volt -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/Volt-*/Build/Products/Release/Volt.app /Applications/
open /Applications/Volt.app
```

Or open `Volt.xcodeproj` in Xcode and run. Volt lives in the menu bar and has no Dock
icon or window of its own. Left-click the icon for the panel, right-click for a menu
with **Test Alert**. Turn on **Open Volt at login** in Settings › General.

## Menu bar icon

Four styles — battery, battery with percentage inside, percentage only, and ring.

In the numbered style the shell is filled solid and the colour alone carries the level,
stepping green → lime → amber → orange → red as the charge falls. The digits are drawn
black or white by the fill's luminance, so they stay readable at every level and against
any wallpaper.

![Menu bar icons](docs/menubar.png)

## What it does not do

**Volt never changes how your Mac charges.** There is no charge limiting and nothing is
written to the SMC or the charging controller. The 80% alert tells you to unplug; it
does not unplug for you.

Some things macOS simply does not expose:

- **Apple Watch battery.** Not published to the Mac at all, by any route.
- **iPhone / iPad health and cycle count.** `system_profiler` reports nothing for these
  devices, and the health figures live behind `MobileDevice.framework`, which needs the
  device plugged in and trusted at least once.

Also not built: desktop widgets, and auto-dismissing macOS's own low-battery popups.

## iPhone and iPad

The live percentage comes from Bluetooth. An iPhone or iPad connected to the Mac
exposes the standard GATT **Battery Service** (`0x180F`) with the **Battery Level**
characteristic (`0x2A19`) — a public Bluetooth profile, nothing Apple-specific — so an
ordinary `CBCentralManager` can read it. The device needs to be paired with the Mac and
in range; no cable and no pairing record are required.

This is deliberately separate from the `MobileDevice.framework` path, which is used only
for health, cycle count and lifetime stats and does need a cable.

macOS asks for Bluetooth permission the first time Volt scans. If the prompt does not
appear, allow Volt under System Settings › Privacy & Security › Bluetooth.

## How it reads the battery

| Data | Source |
| --- | --- |
| Charge, health, cycles, temperature, current | `AppleSmartBattery` in the IO registry |
| Change notifications | `IOPSNotificationCreateRunLoopSource` |
| Condition, Apple's Maximum Capacity | `system_profiler SPPowerDataType`, every 15 min |
| AirPods and Bluetooth accessories | `system_profiler SPBluetoothDataType` |
| Magic Mouse / Keyboard / Trackpad | `ioreg -k BatteryPercent` |
| Per-app energy | `top -stats pid,cpu,power,command` |
| iPhone / iPad level | CoreBluetooth GATT `0x180F` / `0x2A19` |
| iPhone / iPad health (cable) | `MobileDevice.framework`, resolved with `dlsym` |

Nothing leaves the machine. Preferences and energy history live in
`~/Library/Application Support/Volt/`.

## Troubleshooting

Create `~/.volt-debug` and restart Volt to have it append what it finds — Bluetooth
state, discovered devices and their levels — to `~/.volt-debug.log`. Delete the marker
file to turn it off again.

## Notes

Alerts are shown as Volt's own on-screen HUD rather than through Notification Center,
because an ad-hoc signed build cannot reliably obtain notification authorization.
Notification Center delivery is available as an option in Settings.

Requires macOS 14 or later. Built and tested on macOS 26 with Xcode 27.

# Troubleshooting

## The remote cannot find the Mac

Keep Pinshift running and the Mac awake. Both devices must be on the same LAN. Allow Local Network access in system settings; then use the companion's Mac connection button and Reconnect. Guest Wi-Fi client isolation or a VPN can block Bonjour. Scan the QR code again if pairing was reset. A manual pairing-code field is also available.

The Mac companion connection and Xcode's connection to the target phone are separate: successful pairing with Pinshift does not establish iPhone developer trust.

## No iPhone or location cannot start

Connect the unlocked phone by USB first, accept the Trust prompt on the phone, enable Developer Mode, and let Xcode prepare the device. For wireless operation, confirm that Xcode can reach that same phone over the network. Check `xcrun devicectl list devices` and `xcrun devicectl device simulate location --help`. Update/select a compatible full Xcode if the location command is missing.

If multiple iPhones are connected, explicitly choose the target in Pinshift. A disappeared target is never silently replaced with another phone.

## Waiting to restore GPS

Reconnect and unlock the original target iPhone. Keep the Mac awake. The worker retains the restore request until the native clear succeeds. A restored status means CoreDevice acknowledged its clear command; an individual app may need time or reopening to request a fresh location.

## Remove Pinshift

First use **Stop & restore GPS** while the target iPhone is reachable and verify **Real GPS**. Quit the Mac app. Then unload its worker:

```sh
launchctl bootout "gui/$(id -u)/at.strics.pinshift.keeper"
```

The command may report that the worker is already unloaded. Move `/Applications/Pinshift.app` to Trash. Remove the LaunchAgent and `~/Library/Application Support/Pinshift` only after restoring GPS. Remove the optional log `~/Library/Logs/Pinshift.log`. The companion can be deleted normally from the iPhone. Pairing keys can be removed with Keychain Access under service `at.strics.pinshift`.

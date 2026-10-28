# Installing Trackglass for Mac

The normal path is the website's download button, which opens the newest GitHub release. This page covers the manual path and what to do when something is in the way.

## Manual install

1. Open https://github.com/simo-hue/TrackGlass/releases/latest and download `Trackglass-for-Mac-<version>.dmg`. The DMG is signed with a Developer ID certificate and notarized by Apple; Gatekeeper opens it without warnings.
2. Open the DMG and drag **Trackglass for Mac** to **Applications**. Eject the DMG.
3. Launch Trackglass from Applications. It lives in the menu bar (no Dock icon). The Welcome window asks for **Accessibility**: click *Open System Settings*, turn Trackglass on, and the Welcome window updates by itself.
4. If macOS asks about **Local Network** access, allow it — the phone finds the Mac through Bonjour on your network.
5. Choose **Pair a device…** in the menu bar icon and pair the phone (QR code, or *Use a code instead*).

Updates arrive in-app (Sparkle); *Check for Updates…* is in the menu bar menu and in Settings → General.

## Starting at login

Settings → General → *Start at login* registers Trackglass as a login item. If macOS reports that approval is required (typical for a copy that is not in Applications), allow it in System Settings → General → Login Items.

## Troubleshooting

- **"Accessibility permission required" never goes away.** Remove Trackglass from System Settings → Privacy & Security → Accessibility with the minus button and add it again from Applications. A build moved after being granted loses the grant.
- **The phone does not see the Mac.** Both devices must be on the same network. On the Mac check System Settings → Privacy & Security → Local Network and that Trackglass is allowed; on the phone the same setting exists under Settings → Trackglass. Guest networks and some corporate networks block Bonjour — a personal hotspot from the phone works as a fallback.
- **"Mac is being used by …"** Only one phone can control a Mac at a time; disconnect the other device (or forget it in Settings → Devices on the Mac).
- **"Pair again".** The Mac forgot the phone (Settings → Devices → Forget) or vice versa. Pair again from the menu bar icon.
- **Gestures feel reduced.** The menu bar menu shows *Reduced gesture mode* when a macOS update changed a private interface the Mac companion relies on; the affected gestures fall back to keyboard shortcuts until an update restores them.

## Uninstall

Quit Trackglass from its menu, delete it from Applications, and remove `~/Library/Application Support/Trackglass` (recordings) if present. Paired phones are stored in the data-protection Keychain under the service `app.trackglass.pairing` (not the login keychain, so Keychain Access does not list them); forget them from Settings → Devices before uninstalling, or reinstall and forget them there.

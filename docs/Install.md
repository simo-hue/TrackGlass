# Installing Trackglass for Mac

The normal path is the website's download button, which opens the newest GitHub release. This page covers the manual path and what to do when something is in the way.

## Manual install

1. Open https://github.com/simo-hue/TrackGlass/releases/latest and download `Trackglass-for-Mac-<version>.dmg`. The DMG is signed by the developer (Developer ID) and notarized by Apple; Gatekeeper opens it without warnings.
2. Open the DMG and drag **Trackglass for Mac** to **Applications**. Eject the DMG.
3. Launch **Trackglass for Mac** from Applications. It lives in the menu bar, at the top right (no Dock icon). On a MacBook with a notch, a crowded menu bar can hide the icon behind the notch; quit or hide a few other menu bar apps to reveal it. The Welcome window asks for **Accessibility**: click *Open System Settings*, turn Trackglass for Mac on, and the Welcome window updates by itself.
4. On macOS 15 or later, macOS asks for **Local Network** access: allow it. The phone finds the Mac through Bonjour on your network, and without this permission it cannot.
5. Choose **Pair a device…** in the menu bar icon. On the phone (on the same Wi‑Fi network, with Local Network access allowed when iOS asks), tap *Scan Mac QR code*, or *Use a code instead* and type the 6-digit code. If you scan the code with the Camera app instead, Trackglass opens and asks you to confirm.
6. On the Mac, click **Allow** to accept the pairing request.

Updates arrive in-app (Sparkle): once a day the app reads the update feed from raw.githubusercontent.com and downloads new versions from github.com; nothing about you is sent. *Check for Updates…* is in the menu bar menu and in Settings → General.

## Starting at login

Settings → General → *Start at login* registers Trackglass as a login item. If macOS reports that approval is required (typical for a copy that is not in Applications), allow it in System Settings → General → Login Items.

## Troubleshooting

- **"Accessibility permission required" never goes away.** Remove Trackglass from System Settings → Privacy & Security → Accessibility with the minus button and add it again from Applications. A build moved after being granted loses the grant.
- **The phone does not see the Mac.** Both devices must be on the same Wi‑Fi network. On the Mac check System Settings → Privacy & Security → Local Network and that Trackglass for Mac is allowed (macOS 15 or later); on the phone check Settings → Privacy & Security → Local Network (also shown under Settings → Trackglass). Guest networks and some corporate networks block traffic between devices; a personal hotspot from the phone may work instead.
- **"Mac is being used by …"** Only one phone can control a Mac at a time; disconnect the other device (or forget it in Settings → Devices on the Mac).
- **"Pair again".** The Mac forgot the phone (Settings → Devices → Forget) or vice versa. Pair again from the menu bar icon.
- **Gestures feel reduced.** The *Reduced gesture mode* list in the menu bar menu (and in Settings → Advanced) says which gestures use a fallback. On macOS 27, or after a macOS update changes the system-gesture interface the Mac companion relies on, Spaces, Mission Control, App Exposé and Show Desktop use keyboard shortcuts: they switch when you lift your fingers instead of following them live, and Launchpad / Apps has no fallback. Force click always opens Look Up, and Notification Center opens through Accessibility.

## Uninstall

Quit Trackglass from its menu, delete it from Applications, and remove `~/Library/Application Support/Trackglass` (recordings) if present. Paired phones are stored in the data-protection Keychain under the service `app.trackglass.pairing` (not the login keychain, so Keychain Access does not list them); forget them from Settings → Devices before uninstalling, or reinstall and forget them there.

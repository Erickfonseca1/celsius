# Celsius

Control your LG air conditioner from the Mac menu bar. Click the icon, change the temperature, mode or
fan speed, and you're done. No phone needed.

<!-- screenshot here -->

## What you can do

- Turn the air conditioner on and off
- Change the mode (cool, fan, etc.)
- Set the temperature
- Change the fan speed and the air swing
- Turn Eco mode on and off
- Set a sleep timer (turns off after a few hours)
- Open the app automatically when you log in

## What you need

- A Mac with **macOS 15 or later**
- An **LG air conditioner** that already works in the **LG ThinQ** phone app
- An **LG account in Brazil** (the app is set up for that region)

## Install

1. Go to the [**Releases** page](https://github.com/gbvillarinho/celsius/releases/latest).
2. Download **Celsius.zip**.
3. Double-click the file to unzip it, then drag **Celsius** into your **Applications** folder.
4. Open **Celsius** from Applications. The Celsius icon appears in the menu bar.

### If macOS says it can't open the app

The first time, macOS may warn that it can't verify the app. This is normal for apps that don't come from
the App Store. To open it anyway:

1. Right-click (or Control-click) **Celsius** in Applications and choose **Open**.
2. Click **Open** in the window that appears.

If that option doesn't show up, open **System Settings → Privacy & Security**, scroll down, and click
**Open Anyway** next to Celsius.

You only need to do this once.

## Connect your air conditioner

Celsius needs a free **access token** from LG so it can talk to your air conditioner. It takes about a minute.

### 1. Get your token

1. Open [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) and sign in with your LG account.
2. Create a new token (a "Personal Access Token").
3. Copy it. It starts with `thinqpat_`.

### 2. Paste it into Celsius

1. Click the Celsius icon in the menu bar. The first time, it opens on the **Settings** screen.
2. Paste the token into the field and click **Connect**.
3. Your air conditioner shows up and you can control it.

Your token stays safe in the Mac's Keychain, on this Mac only. It is never saved in a file or sent
anywhere except to LG.

## Questions

**"LG rejected this token."**
The token is wrong or expired. Create a new one on the LG page and paste it again in Settings.

**Nothing changes right after I press a button.**
LG's servers take a few seconds to confirm a change. Celsius shows the new value right away and checks it
a moment later.

**Does it work in other countries?**
Not yet. It is set up for Brazil.

**Does it work with any LG air conditioner?**
It was built and tested with one model. Others should work, but some controls may be missing or different.

**How do I disconnect or switch accounts?**
Open **Settings** in the app and sign out, then paste a new token.

---

## For developers

Celsius is a Swift Package (no Xcode project). You only need the Command Line Tools
(`xcode-select --install`) and Swift 6.2 or later.

Build and install from source:

```sh
git clone https://github.com/gbvillarinho/celsius.git
cd celsius
scripts/build-app.sh --install    # build, ad-hoc sign, copy to /Applications and launch
```

Use `scripts/build-app.sh` without `--install` to only build `build/Celsius.app`. To install with the
token already in the Keychain: `CELSIUS_PAT=thinqpat_your_token scripts/build-app.sh --install`.

Build and test:

```sh
swift build                           # debug build
scripts/test.sh                       # all tests
scripts/test.sh --filter StoreTests   # one suite
```

Always run tests through `scripts/test.sh`. With only Command Line Tools installed, Swift Testing lives
outside the default search paths, and the script adds the flags it needs.

Environment variables for running from the terminal:

| Variable | Effect |
| --- | --- |
| `CELSIUS_PAT=<token>` | use this token instead of the Keychain |
| `CELSIUS_OPEN_ON_LAUNCH=1` | open the popover on launch |
| `CELSIUS_LIVE_SNAPSHOT=<file.png>` | render the popover with live data once it loads |

To check UI changes without running the app, render the popover in fixed states (no network):

```sh
$(swift build --show-bin-path)/Celsius --snapshot <dir>
```

Layout:

- `Sources/CelsiusCore`: API client, models, settings/Keychain and the observable store (tested)
- `Sources/Celsius`: the AppKit + SwiftUI app (status item, popover and views)
- `Tests/CelsiusCoreTests`: Swift Testing suites; fixtures are real responses from the unit, with the device ID replaced

The app uses LG's official [ThinQ Connect API](https://connect-pat.lgthinq.com) with a Personal Access
Token. The region is fixed to Brazil (`x-country: BR`, host `api-aic.lgthinq.com`); for another country,
adjust `ThinQClient`. See [CLAUDE.md](CLAUDE.md) for architecture details and conventions.

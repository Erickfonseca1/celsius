# Celsius

A macOS menu bar app that controls an LG ThinQ air conditioner. It uses the official
[LG ThinQ Connect API](https://connect-pat.lgthinq.com) with a Personal Access Token (PAT).
Click the menu bar icon and a popover opens with the controls, styled after macOS Control Center.

## Features

- Power on and off
- Switch the operating mode (cool, fan, etc., depending on your model)
- Set the target temperature (−/+ buttons or slider), with a configurable range
- Change the fan speed and toggle swing
- Toggle Eco mode
- Set a sleep timer (turns the unit off after N hours)
- Shows the current state, refreshing faster while the popover is open
- Launch at login and half-degree steps as options

The controls shown depend on what your model allows writing, according to the device profile.

## Requirements

- macOS 15 or later
- Command Line Tools (`xcode-select --install`). Xcode is not needed
- Swift 6.2 or later
- An LG air conditioner already registered in the LG ThinQ phone app
- An LG account in the **Brazil** region (see Limitations)

## Install

```sh
git clone https://github.com/gbvillarinho/celsius.git
cd celsius
scripts/build-app.sh --install
```

This builds a release binary, assembles and ad-hoc signs `Celsius.app`, copies it to `/Applications` and
launches it. To build without installing, run `scripts/build-app.sh`. The app ends up in `build/Celsius.app`.

Because the app is only signed locally, macOS may complain the first time you open it. If so,
right-click the app, choose **Open** and confirm.

## Setup

### 1. Create a token

1. Go to [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) and sign in with your LG account.
2. Create a new Personal Access Token and copy it (it starts with `thinqpat_`).

### 2. Paste it into the app

1. Open Celsius. With no token, the popover opens on **Settings**.
2. Paste the token into the field and click **Connect**.
3. The app finds your air conditioner and shows the controls.

The token is stored only in the macOS login keychain (service `com.gabrielvillarinho.celsius`), readable
only on this Mac while it is unlocked. It is never written to a file and is only sent to LG's API.

### Install with the token (optional)

```sh
CELSIUS_PAT=thinqpat_your_token scripts/build-app.sh --install
```

The script saves the token in the keychain during installation.

### If LG rejects the token

The app shows "LG rejected this token". Create a new token on the portal and paste it again in Settings.

## Development

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
| `CELSIUS_PAT=<token>` | use this token instead of the keychain |
| `CELSIUS_OPEN_ON_LAUNCH=1` | open the popover on launch |
| `CELSIUS_LIVE_SNAPSHOT=<file.png>` | render the popover with live data once it loads |

To check UI changes without running the app, render the popover in fixed states (no network):

```sh
$(swift build --show-bin-path)/Celsius --snapshot <dir>
```

See [CLAUDE.md](CLAUDE.md) for architecture details and conventions.

## Project layout

- `Sources/CelsiusCore`: API client, models, settings/keychain and the observable store (tested)
- `Sources/Celsius`: the AppKit + SwiftUI app (status item, popover and views)
- `Tests/CelsiusCoreTests`: Swift Testing suites; fixtures are real responses from the unit, with the device ID replaced

## Limitations

- The region is fixed to Brazil (`x-country: BR`, host `api-aic.lgthinq.com`). For another country, adjust `ThinQClient`.
- Built and tested against a single air conditioner. Other models may expose different properties.
- LG's cloud takes a few seconds to reflect a command. The app shows the new value right away and confirms it on the next poll.

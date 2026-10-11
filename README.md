# Celsius

Menu bar app for macOS that controls an LG ThinQ air conditioner through the official
[LG ThinQ Connect API](https://connect-pat.lgthinq.com), using a Personal Access Token.

Builds with Swift Package Manager only (Command Line Tools are enough, no Xcode needed).

```sh
scripts/build-app.sh             # build build/Celsius.app
scripts/build-app.sh --install   # copy to /Applications and open (saves $CELSIUS_PAT in the keychain if set)
scripts/test.sh                  # run the tests
```

On first launch without a token the popover opens on Settings; paste the token there.
The token lives in the login keychain (service `com.gabrielvillarinho.celsius`).

## Development

- `CELSIUS_PAT=<token>`: use this token instead of the keychain.
- `CELSIUS_OPEN_ON_LAUNCH=1`: open the popover on launch.
- `Celsius --snapshot <dir>`: render the popover in fixed states (and airflow frames) to PNGs.
- `CELSIUS_LIVE_SNAPSHOT=<file.png>`: render the popover with live data once it loads.

The country is fixed to Brazil (`x-country: BR`, `api-aic.lgthinq.com`), see `ThinQClient`.
Test fixtures in `Tests/CelsiusCoreTests/Fixtures` are real responses from the unit (device id replaced).

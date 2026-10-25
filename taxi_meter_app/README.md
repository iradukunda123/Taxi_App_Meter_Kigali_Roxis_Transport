# Taxi Meter — Rwanda Edition

A live GPS taxi meter for drivers operating in Rwanda (map defaults to Kigali).
The map is rendered with **`flutter_map`** — a free, open-source, Leaflet-style
map widget using OpenStreetMap tiles. No Google Maps API key, no billing
account, no map SDK setup at all.

Branded for Robert — green, yellow and white throughout, with his photo set
as the driver avatar.

Tracks distance, elapsed time and speed in real time, and calculates the fare as:

```
Total Fare = Base Fare + (Distance in km × Rate/km) + (Waiting minutes × Waiting Rate/min)
```

## What's in this folder

```
taxi_meter_app/
├── pubspec.yaml                          # dependencies + assets declaration
├── analysis_options.yaml                 # standard Flutter lints
├── lib/
│   └── main.dart                         # the entire app (clean-architecture layers, one file)
├── assets/
│   └── driver_profile.png                # Robert's photo — replace with a different one any time
├── android/
│   ├── build.gradle
│   ├── settings.gradle
│   ├── gradle.properties
│   └── app/
│       ├── build.gradle
│       └── src/main/
│           ├── AndroidManifest.xml       # location + internet permissions (no API key needed)
│           ├── kotlin/.../MainActivity.kt
│           └── res/...
├── ios/
│   ├── Podfile
│   └── Runner/
│       ├── Info.plist                    # location permission strings
│       └── AppDelegate.swift             # plain FlutterAppDelegate — no map SDK setup
└── .gitignore
```

This bundle intentionally does **not** include the Gradle wrapper binary
(`gradlew`, `gradle-wrapper.jar`) or the Xcode project file (`Runner.xcodeproj`)
— those are large, machine-generated files that the Flutter CLI creates for
you, and hand-authoring them tends to produce broken projects. The steps
below have `flutter create` generate them, then drop this bundle's files on
top.

## Setup — from zero to running app

**1. Install the Flutter SDK** (if you haven't already):
https://docs.flutter.dev/get-started/install

**2. Generate a fresh Flutter project shell** (this creates the Gradle
wrapper, Xcode project, and all other native boilerplate):

```bash
flutter create --org com.example taxi_meter_app_shell
```

**3. Copy this bundle's files over the generated shell**, replacing the
matching files/folders (`pubspec.yaml`, `lib/`, `assets/`,
`android/app/src/main/AndroidManifest.xml`,
`android/app/build.gradle`, `android/build.gradle`,
`android/settings.gradle`, `android/gradle.properties`,
`android/app/src/main/kotlin/.../MainActivity.kt`,
`ios/Podfile`, `ios/Runner/Info.plist`, `ios/Runner/AppDelegate.swift`):

```bash
# from the folder containing both taxi_meter_app/ and taxi_meter_app_shell/
cp -r taxi_meter_app/pubspec.yaml       taxi_meter_app_shell/
cp -r taxi_meter_app/analysis_options.yaml taxi_meter_app_shell/
cp -r taxi_meter_app/lib                taxi_meter_app_shell/
cp -r taxi_meter_app/assets             taxi_meter_app_shell/
cp -r taxi_meter_app/android/app/src/main/AndroidManifest.xml \
      taxi_meter_app_shell/android/app/src/main/AndroidManifest.xml
cp -r taxi_meter_app/android/app/build.gradle \
      taxi_meter_app_shell/android/app/build.gradle
cp -r taxi_meter_app/android/build.gradle          taxi_meter_app_shell/android/build.gradle
cp -r taxi_meter_app/android/settings.gradle       taxi_meter_app_shell/android/settings.gradle
cp -r taxi_meter_app/android/gradle.properties     taxi_meter_app_shell/android/gradle.properties
cp -r taxi_meter_app/android/app/src/main/kotlin/. \
      taxi_meter_app_shell/android/app/src/main/kotlin/
cp -r taxi_meter_app/ios/Podfile                   taxi_meter_app_shell/ios/Podfile
cp -r taxi_meter_app/ios/Runner/Info.plist         taxi_meter_app_shell/ios/Runner/Info.plist
cp -r taxi_meter_app/ios/Runner/AppDelegate.swift  taxi_meter_app_shell/ios/Runner/AppDelegate.swift

cd taxi_meter_app_shell
```

> If `flutter create` used a package name other than `com.example.taxi_meter_app`,
> update the `namespace`/`applicationId` in `android/app/build.gradle` and the
> package folder under `android/app/src/main/kotlin/` to match, or re-run step 2
> with `--org com.example` exactly as shown so the paths line up.

**4. Driver photo** (optional): `assets/driver_profile.png` already has
Robert's photo in it. Overwrite it with a different file any time — if the
file is ever missing, the app falls back to a generated taxi-icon avatar.

**5. Install dependencies and run:**

```bash
flutter pub get
flutter run
```

There's no API key step — `flutter_map` fetches OpenStreetMap tiles directly
over HTTPS, no account or credentials required.

## About the map tiles

By default this app points at the public OpenStreetMap tile server
(`https://tile.openstreetmap.org`), which is great for development but is
rate-limited and its [usage policy](https://operations.osmfoundation.org/policies/tiles/)
disallows heavy production traffic. Before shipping to real drivers, switch
the `urlTemplate` inside the `TileLayer(...)` in `lib/main.dart` to:
- a free-tier hosted provider (e.g. MapTiler, Stadia Maps, Thunderforest), or
- your own self-hosted tile server.

No other code changes are needed — just the URL. Whichever tiles you use,
keep the on-map attribution widget visible and update its text to match that
provider's required attribution.

## Fare calibration

Tap the tune icon in the app bar (or the drawer) to set:
- **Base fare** (RWF) — charged once per ride
- **Rate per km** (RWF/km)
- **Waiting rate** (RWF/min) — applied whenever the meter is in "waiting" mode

## Notes

- Minimum Android SDK is 23 (required by `geolocator`); iOS deployment target
  is 13.0.
- Distance is accumulated only while a ride is "running"; switching to
  "waiting" mode freezes distance-based charging and starts the per-minute
  waiting rate instead.
- The app still needs location permission (for GPS tracking) and internet
  access (to download map tiles) — both are already declared in the Android
  manifest and iOS `Info.plist` included here.

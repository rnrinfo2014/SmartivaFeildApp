# Smartiva FieldOps — Android test build

This stage produces an **internal debug APK**, version **0.5.1-test (3)**, package **com.smartiva.smartiva_fieldops.test**, launcher label **Smartiva FieldOps Test**. It includes ARM64 and ARMv7 phone libraries. Minimum supported OS follows Flutter 3.47.7: **Android 7.0 / API 24**. Target/compile SDK: Android 16 / API 36. The test package installs separately from the future production package and keeps its own SQLite database and secure settings.

Your initial test phone is a Moto Edge 60 Fusion running Android 17 (ARM64). Its OS is above the minimum supported version; actual behavior on Android 17 still needs the physical-phone checks below. Older ARM32/ARM64 phones can install this build from Android 7.0 onward.

## Install on a phone

1. Copy/download `smartiva-fieldops-0.5.1-test.apk` to the phone.
2. Open the file from Files/downloads. Allow **Install unknown apps** for that file manager/browser if Android asks, then install.
3. Open **Smartiva FieldOps Test**. Microphone permission is requested only when recording starts.
4. If Android reports an incompatible app, record the phone model, Android version and exact error. This APK is for ARM phones, not x86 emulators. Company device-management policy may also block sideloading.

This is debug-signed for pilot testing. It is not a Play Store/production release. Keep the generated test signing key for compatible updates; APKs rebuilt with a different key cannot update this installation. **Do not uninstall or clear app storage to fix an update error until unsynced site data/recordings have been handled**—Android removes local app data on uninstall. No company release signing key is included in the project.

## First test — no backend required

Use a test site, then perform these checks:

| Action | Expected result |
|---|---|
| Enable airplane mode; open app; tap **New site**, name it `Yogasree Test` | Site opens and is stored locally |
| Open **Guided AI entry**; submit `Ground floor-la 64 channel NVR irukku, 27 Dahua and 15 CP Plus cameras` | Technician message and pending job are saved; AI processing waits for a configured reachable backend |
| Close/reopen the app | Site, submitted message and pending job remain |
| Tap **Continuous voice briefing**; allow microphone; speak for 15–30 seconds, then **STOP & SAVE** | A voice note and pending processing/upload work are saved locally |
| Deny microphone permission and try again | App explains the permission problem without losing prior notes |
| Start recording, then background the app | Recording stops/saves; the app does not promise background processing |
| Open home **Sync & review** | Pending inventory/audio counts are visible; no configuration means work stays local |

Offline AI responses are not generated on the phone. Voice files and entered text remain local until the respective online workers succeed. There is no playback UI in this build; actual audio content is checked through transcription/backend archival during the connected test.

## Connect AI and PostgreSQL sync

An APK alone does not supply a hosted backend. The administrator must set up PostgreSQL and persistent audio storage, initialize the schema, issue a **device token**, and configure Gemini/Groq keys using [backend/SYNC.md](../backend/SYNC.md). A token is entered on the phone; it is never compiled into the APK. Groq is required for voice transcription even when Gemini handles extraction.

In **API connection**, enter the reachable API origin and device token, then save **while online** so identity validation can complete. Use a hostname/IP your phone can reach; `localhost` on a phone refers to the phone itself. HTTPS works for normal deployment. This debug build additionally permits HTTP to private/local development IP addresses, e.g. `http://192.168.1.50:8000`. The backend must listen on that LAN interface and the firewall must allow the port. Release connection settings require HTTPS.

Open **Sync & review → Sync now**. Site creation syncs before site-authorized AI jobs. Wait for the AI reply, inspect the extracted floors/assets/cameras and calculated question, then explicitly confirm the inventory. For the 64/42 example, 22 free channels should be reported only when the underlying counts are consistent; individual camera rows must not be invented from brand counts. Ask follow-up questions to correct data before confirmation.

Disconnect the internet, save another note, then reconnect and keep the app foregrounded. Automatic attempts occur at launch/resume, connectivity changes and every 15 seconds. Check pending/failed/conflict rows. Foreground retries back off; auth/validation errors require attention. Shared internal AI service tokens do not authorize sync. A bound database cannot be switched to a different server/device account.

## Local NVR/Wi-Fi test

1. Connect the phone to the authorized site's Wi-Fi/LAN. The Wi-Fi may have no internet; discovery and local NVR import still work. If Android switches away from that Wi-Fi, disable mobile data temporarily while keeping Wi-Fi enabled.
2. Open a site → **Auto-scan network**, then scan. Confirm the NVR's address/model/serial against the physical device. No replies can result from Wi-Fi client isolation, VLAN boundaries, firmware differences or local network restrictions.
3. If broadcast discovery has no replies, use **Enter NVR IP** with its known address.
4. For a Dahua/CP Plus NVR, enter authorized device credentials. Check model/serial and configured remote cameras. Verify a dual-NIC camera subnet against the NVR's own inventory; the phone need not contact the isolated cameras directly.
5. Review the snapshot before importing. Confirm channel numbering only if the firmware's slot convention is known. A configured camera list is not evidence that cameras are currently online.
6. Re-scan and import again: existing identities should be reused. Missing scan results must not delete documented inventory.

Hikvision SADP and ONVIF are discovery paths; the authenticated CGI inventory bridge in this build is for supported Dahua/CP Plus responses. Actual vendor/firmware behavior requires these physical tests.

## Two-technician sync and conflicts

Provision a separate device token for each phone and grant both technicians the same test site. Keep both apps online once to pull its inventory, then work offline. Make different confirmed changes to the same existing record; reconnect the first phone and then the second. The second device should show a conflict instead of silently overwriting the first edit. Open **Review**, compare the snapshots, and explicitly choose **Keep device edits** or **Use server copy**. Resolution snapshots are retained locally. If a server record was removed, automatic restoration is blocked.

Do not create identically named sites independently and expect them to merge: identity uses UUIDs. Chat histories, raw scans and unreviewed proposals remain local; reviewed canonical inventory, sanitized observations and archived voice metadata sync. The optional download endpoint can retrieve an authorized archive, but the app does not automatically download recordings to other phones.

## Report test results

Record: APK version, phone model, Android version, workflow, expected/actual behavior, network state and a screenshot of any displayed error. For NVR failures also record vendor, model and firmware version. Do not send passwords, device tokens, private transcripts or customer camera imagery in an ordinary bug report.

## Rebuild

Use Flutter 3.47.7/Dart 3.13.5, a **full Java JDK 21** (17+ supported by the project), Android SDK platforms 35/36, build-tools 36.0.0, NDK 28.2.13676358 and CMake 3.22.1. Configure the local Android SDK path through Flutter/local.properties. Check `javac -version` as well as `java -version`: a runtime without the Java compiler cannot build Android Java tasks. Point Flutter at the full JDK with `flutter config --jdk-dir /path/to/jdk`. Then:

```sh
cd mobile
flutter analyze
flutter test
FLUTTER_BIN=/path/to/flutter ./scripts/build_android_test.sh
```

The script builds both phone ARM architectures and writes the APK/checksum under `mobile/dist/`. Proxy/CA settings are environment-specific and are not committed to the application. Release deployment, company signing, Play Store delivery and physical-phone acceptance require their own approval stage.


## Build validation

The internal APK was built successfully and checked with Android build-tools:

- Package/version/label: `com.smartiva.smartiva_fieldops.test`, `0.5.1-test (3)`, **Smartiva FieldOps Test**.
- Minimum API 24 / target API 36; exactly `armeabi-v7a` and `arm64-v8a`, with a Flutter engine for each ABI.
- APK signature verified, ZIP CRC verified, and 16 KB ZIP alignment verified. The APK is debuggable for internal testing and has no `testOnly` flag requiring ADB-only installation.
- Bundled initial SQLite schema matches the reviewed source; test fixtures are not packaged.
- Flutter analysis passed; 63 tests passed, including the Android database startup and diagnostic retry regressions. The separately configured live PostgreSQL integration test was skipped.
- No phone/emulator was attached to the development environment. The user confirmed 0.5.1 opens on the Moto and that the site, text and recorded voice note persist after reopening. Connected AI/sync and physical network-discovery acceptance remain pending.

`dist/build-manifest.json` records the APK SHA-256, signing-certificate fingerprint and toolchain versions; `dist/*.sha256` is the portable download checksum. The pinned recorder plugin still uses KGP compatibility with Flutter 3.47.7; reassess plugin support before upgrading the Flutter toolchain.

## Android startup hotfix — 0.5.1-test

The previous phone build could fail during database configuration: `PRAGMA busy_timeout=5000` returns a result row, which Android's `SQLiteDatabase.execSQL` rejects. Configuration now uses `rawQuery`; the schema and saved data are unchanged. An Android platform-channel contract regression test reproduces the old failure and checks opening, saving offline notes, closing and reopening with the fix. This regression test uses desktop SQLite behind the platform channel; it does not replace testing on the phone.

Install this update over the existing **Smartiva FieldOps Test** app, using the same application ID and signing key. Do not uninstall or clear storage. The build number increases from 2 to 3. Startup errors now show the failing step and a safe diagnostic code without showing SQL or private site data; Retry closes partially opened resources before trying again.

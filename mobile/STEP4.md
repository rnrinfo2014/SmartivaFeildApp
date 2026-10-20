# Step 4 — network discovery and NVR inventory

Implemented source flow: **Site → Auto-scan network → device or manual IP → NVR login → Fetch camera inventory → offline review → Confirm & import on device**. This step uses local Wi-Fi and SQLite; it does not require Gemini, Groq, the FastAPI server or internet access.

## Device support

| Family | Discovery implemented | Inventory bridge |
| --- | --- | --- |
| Dahua / compatible CP Plus | DHIP UDP broadcast to 37810 | Digest-auth CGI system info and RemoteDevice config |
| Hikvision | SADP multicast + broadcast on 37020 | Not implemented; Hikvision ISAPI is a separate adapter |
| ONVIF | WS-Discovery multicast to 239.255.255.250:3702 | Discovery only; no ONVIF-auth inventory queries |

These implementations are verified with synthetic protocol fixtures, mocked HTTP and real local SQLite. **No physical NVR/camera or phone network has been tested in this workspace.** OEM CP Plus firmware varies; DHIP discovery and CGI support must be checked for each model/firmware. The app does not claim universal compatibility or live camera health from a configuration read.

## UDP behavior

- Lists IPv4 LAN interfaces, preferring typical Wi-Fi names and excluding common cellular/VPN interfaces. Select the site Wi-Fi interface if more than one is shown. Does not enumerate every host or guess passwords.
- A scan runs for five seconds, retransmits at one-second intervals, and is cancellable. The selected interface supplies the source IPv4 address. DHIP uses a 32-byte little-endian binary header plus `DHDiscover.search` JSON. SADP uses XML inquiry on multicast and limited broadcast. ONVIF uses a SOAP WS-Discovery `NetworkVideoTransmitter` probe.
- Receives replies on the scan source socket and the relevant fixed ports. Android acquires a Wi-Fi multicast lock for the scan and releases it on completion/cancellation. iOS declares local-network usage and the multicast entitlement. Multicast is link-local (TTL 1).
- Replies are bounded (datagram size, 2,048 packets, 256 distinct source addresses), malformed payloads are ignored, and XML DOCTYPE/entity declarations are rejected. Devices merge by datagram source IP, combining protocol observations. Advertised IPs/XAddrs cannot redirect the app's subsequent login to another host; service paths, credentials and queries from advertised URLs are discarded.
- Scans never alter NVR settings, camera IPs, passwords or activation state. The app stores sanitized discovery observations in `network_scans` after completion or cancellation. Saved device results remain accessible offline; their freshness is not guaranteed until rescanned.
- No replies is not proof that no devices exist. Guest-Wi-Fi client isolation, VLANs, firewall rules, multicast filtering, local-network permission, active VPNs or vendor discovery settings can prevent replies. Use **Enter NVR IP** when discovery is unavailable. DHCP/route/interface behavior still needs real phone testing.

## Dahua/CP Plus bridge

The bridge reads only:

```text
GET /cgi-bin/magicBox.cgi?action=getSystemInfo
GET /cgi-bin/configManager.cgi?action=getConfig&name=RemoteDevice
```

The app makes requests to the selected NVR, not to individual camera IPs. Thus an NVR reachable on LAN1 can report configured camera endpoints behind LAN2 even when that camera subnet is unreachable from the phone. This does not provide camera-subnet routing, prove topology or identify the physical NVR NIC label.

Digest authentication supports MD5, MD5-sess, SHA-256 and SHA-256-sess, `qop=auth` or legacy no-qop challenges. It never falls back to Basic, never follows redirects, advances nonce counts and permits one stale-nonce refresh. A rejected login stops rather than looping through credentials. Each CGI request has a 30-second deadline and a 2 MiB response bound. TLS certificate validation stays enabled; enter the correct HTTP/HTTPS web port, not Dahua's proprietary service port (commonly 37777).

The ASCII key-value `table.RemoteDevice[index].field=value` format is supported. Other JSON/RPC/ISAPI formats fail visibly without modifying inventory. A valid explicit empty table is supported. Duplicate channel mappings, duplicate camera identities across remote entries and inconsistent fields are rejected for manual investigation.

Only allowlisted inventory fields are retained. Raw CGI may contain camera passwords/usernames; those fields are discarded and the raw body is never persisted or logged. Remembered recorder logins use `flutter_secure_storage`, scoped by site and origin, and are optional. Password fields are obscured and cleared when the target changes or fetching finishes. **Forget saved login** removes the secure entry and its local references. Secure references are excluded from outbox payloads, AI context and discovery evidence.

## Channel and status semantics

A remote table index is not universally the same thing as the NVR channel. Explicit vendor `LocalChannel` is normalized from zero-based to one-based. If it is missing, the camera's channel stays null. The review checkbox can explicitly apply `slot + 1` for missing channel numbers after a technician verifies that convention on the recorder. Reported channel capacity is used only when supplied by system info; model digits are never interpreted as channel count.

`Enable=true` means configured, not online. Imported cameras start with `status=unknown`; existing known status is preserved. Disabled/unidentified remote entries are excluded with a warning. A failed/empty discovery or NVR read never deletes or marks unseen cameras offline. Counts describe the returned remote configuration, not necessarily every analog/integrated/multichannel input on a recorder. Complex multi-input remote sources need manual mapping rather than an inferred camera count.

## Offline persistence, matching and AI concurrency

Device database version **2** migrates the existing version-1 database in place. It adds `network_scans`, `nvr_snapshots`, `discovery_bindings` and local AI context revisions. The historical v1 SQL asset is retained unchanged.

A successful NVR fetch is saved immediately as a sanitized snapshot before optional secure-login storage. Close/reopen the app and review/import that snapshot without connecting to the NVR again. A reviewed import, camera bindings, observation, updated AI context and canonical outbox mutations commit in one SQLite transaction. Reimporting the same snapshot is idempotent.

- Recorders match by serial within the site or explicit technician selection. IP alone is not sufficient to merge a recorder with unknown serial. Conflicting serials, wrong-site/non-recorder selections and duplicate identity matches fail without partial writes.
- Cameras match by serial/MAC, then a previous recorder remote-slot binding, then a technician-verified channel mapping. Strong identity conflicts, ambiguous slot replacements, weak-identity address changes and automatic moves to another recorder are blocked. The current UI does not implement replacement retirement or cross-recorder moves; correct those records through the appropriate inventory workflow before retrying.
- Existing camera zone, switch, megapixel, install year and known status are preserved. Only supplied device fields are updated. A matching management NIC is reused by IP; otherwise an explicitly unverified management-address record is created, without guessing LAN1/LAN2 or modifying known NIC links. A query cannot discover the physical switch cable mapping.
- Import refreshes the full local inventory context with stable proposal refs. An older in-flight AI reply is requeued against the new context instead of replacing discovery results. An already completed but unreviewed AI story must be reviewed first, so the import cannot discard it. The NVR snapshot remains stored while the technician resolves that step.
- Unknown/null AI fields no longer erase documented local facts, and `status=unknown` does not overwrite a known camera status. Explicit clearing/removal is a separate future inventory-edit operation.

Reviewed records are queued in the existing `sync_outbox`, but **PostgreSQL push/pull and archival audio upload remain Step 5**. Step 4 does not dispatch those inventory mutations to a server.

## Native configuration and build limits

Android declares INTERNET, ACCESS_NETWORK_STATE, RECORD_AUDIO, ACCESS_WIFI_STATE and CHANGE_WIFI_MULTICAST_STATE. `MainActivity.kt` implements the bounded multicast-lock channel and releases it on activity destruction. No location/SSID permission is requested merely to list interfaces. Android local-network permission behavior on newer target SDKs still needs checking during the physical-device pilot.

Legacy recorders often serve CGI only over local HTTP. The native Android/iOS project therefore allows cleartext transport for that path; the Dart NVR bridge accepts only a literal unicast IPv4 target. Release API settings still enforce HTTPS. This is an intentional native-policy exception for the legacy-device adapter, not a TLS certificate bypass. Use trusted site Wi-Fi or configure a trusted NVR HTTPS certificate.

For iOS, `com.apple.developer.networking.multicast=true` is included in Runner entitlements. The Apple developer team must obtain the multicast entitlement and use a provisioning profile that includes it before device signing. Local Network access must also be granted on the phone. No blanket claim of iOS multicast support can be made without that provisioning and a device test.

At completion of Step 4, this cloud workspace had no Android SDK/emulator or macOS/Xcode, and no native build had been generated. The later Android test build compiles Kotlin and produces a verified APK; see [ANDROID_TESTING.md](ANDROID_TESTING.md). Native secure-storage behavior, multicast-lock behavior, real Wi-Fi/CGI exchange and iOS compilation still require device/platform validation.

## Verification and hardware pilot

```sh
cd mobile
flutter analyze
flutter test
```

Automated coverage includes DHIP/SADP/ONVIF serialization and parsing, source-host handling, malformed/oversize packets, cancellation, deduplication/bounds, the RFC 2617 Digest response vector, nonce count/stale behavior, auth rejection, redirects, response limits/deadlines, CGI secret exclusion, isolated-subnet inventory, SQLite migration, repeat import, identity conflicts, topology preservation and stale AI response handling. Test fixtures are synthetic, not captured proof of hardware compatibility.

Once an Android debug build is available, use a read-only NVR account where firmware permits and test on the site Wi-Fi:

1. Compare discovered serial/model/address against the recorder's own web UI. If no replies, try manual IP and confirm the web port.
2. Fetch the two CGI endpoints. Compare camera count and each remote IP/serial/channel to the NVR channel page. Share only sanitized model/firmware and parser error details for unsupported cases; do not share raw CGI bodies containing credentials.
3. In a dual-NIC setup, confirm the phone cannot access the camera subnet directly but the app can list those configured cameras through the NVR. Verify this is configuration inventory, not a live-health test.
4. Turn mobile data/internet off while retaining site Wi-Fi. Fetch and save a snapshot, close/reopen the app, then review/import it. No AI key is needed.
5. Fetch/import again and confirm camera UUID/count is stable, existing switch/floor assignments remain, and omitted cameras are retained. Test wrong credentials once and confirm the app stops cleanly rather than repeatedly trying the account.

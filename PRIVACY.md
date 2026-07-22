# Privacy Policy

**App:** Hybridge — an unofficial, independent companion app for Fossil hybrid watches
**Effective date:** 22 July 2026

Hybridge is not affiliated with, endorsed by, or connected to Fossil Group, Inc.
or the makers of the official Fossil app.

## Summary

Hybridge is built to keep your data on your device. The app has **no backend
server of its own**, performs **no analytics or advertising tracking**, and
contains **no third-party tracking SDKs**. Your watch data, health metrics,
settings and personal details are stored locally on your iPhone and are shared
only with services you explicitly use, as described below.

## Data stored on your device

The following data is created or stored **locally on your iPhone** and is never
sent to the developer:

- **Fitness and health data** — steps, heart rate, blood oxygen (SpO₂), sleep,
  and activity synced from your watch. This is held in an encrypted on-device
  archive (protected by iOS file encryption and excluded from iCloud/iTunes
  backups). The copy on the watch is deleted only after it has been safely
  merged into this archive.
- **Body metrics** — age, gender, height and weight, if you enter them. These
  are stored on the phone and written to the watch so it can estimate calories.
- **Watch information** — the watches you register, their firmware version,
  battery level, alarms, watchfaces, and your preferences (step goal, vibration
  strength, units, quiet hours, button assignments).
- **Contact names** (Q hybrid models only) — if you configure per-contact
  notification behaviour, contact names you choose are stored on the phone and
  written to the watch's notification filter. This matching happens entirely on
  the device.
- **Watch authentication key** (Hybrid HR models) — the 16-byte key used to talk
  to your watch is stored in the iOS Keychain.

Forgetting a watch removes that watch's authentication key and watch-scoped
settings, but intentionally keeps already-synced fitness history. The Fitness
screen provides a separate **Delete local fitness history** action. Removing
the Home Assistant integration deletes its saved address, selected entities and
Keychain token. Deleting the app removes its sandbox files and settings; iOS may
retain Keychain items across reinstall or encrypted-device-backup restoration,
so remove watches and the Home Assistant integration first if those credentials
must also be erased. Data already exported to Apple Health is managed in Health.
Copies already written to a watch remain on that watch until replaced or reset.

## Apple Health

If you choose to export fitness data, Hybridge writes it to **Apple Health
(HealthKit)** on your device. Data in Apple Health is governed by Apple's own
privacy protections and your Health permissions. Hybridge only writes the
categories you authorise and does not read your broader Health history.
You can revoke access at any time in **Settings → Health → Data Access &
Devices**.

## Bluetooth

Hybridge communicates with your watch over Bluetooth Low Energy. This connection
is directly between your iPhone and your watch; no watch data passes through any
server operated by the developer. iOS system notifications (SMS, calls, etc.)
reach the watch through Apple's standard ANCS/AMS Bluetooth services once the
watch is paired — Hybridge is not involved in delivering those notifications.

## Location

Hybridge uses location only with your permission (**When In Use**) and only for:

- **Workout GPS** — recording distance for a workout you start on the watch, and
  the in-app "Workout GPS" demo. The blue status indicator is shown whenever
  location is active.
- **Weather** — determining your current location to fetch local weather (see
  below).

Location is used to support these features and is not sold or sent to the
developer. For weather during background reconnects, the most recent precise
latitude and longitude are retained in the app's local settings until replaced
by a newer location or the app is deleted. Workout route points are held only
for the active workout; only the resulting distance is retained with workout
history.

## Weather (Apple WeatherKit)

If you enable the weather complication, Hybridge requests weather using **Apple
WeatherKit**. To do this, your approximate location is sent to Apple to return
local conditions. This data is handled under
**Apple's WeatherKit privacy terms** (https://www.apple.com/legal/privacy/) and
Apple's weather data attribution requirements. Weather data is cached briefly on
the device to display on your watch and is not retained by the developer.

## App icon lookup (Apple / iTunes Search)

When you configure which apps may send notifications to your watch, Hybridge may
query the public **Apple iTunes Search API** (`itunes.apple.com`) to find an
app's name and icon. Only the search term (an app name or bundle identifier) is
sent. No personal or health data is included in these requests, and they are
handled under Apple's privacy terms.

## Home Assistant (optional, self-configured)

If you choose to connect Hybridge to your own **Home Assistant** instance, the
app communicates directly with the server address and credentials **you**
provide. That data goes only to the server you configure, not to the developer.
This feature is off unless you set it up.
HTTPS is required by default. The settings screen offers an explicit advanced
override for local HTTP servers; enabling it means the long-lived token and
Home Assistant responses can be observed or modified by someone with access to
that network.

## Calendar and commute routing

If calendar sync is enabled, upcoming event titles, times and notes are read
from EventKit and written directly to the watch. If commute ETA is used, the
destination and current location are processed by Apple's MapKit routing
service. Neither is sent to the developer.

## Data the developer receives

**None.** The developer operates no server and receives no personal data,
health data, usage analytics, crash reports, or identifiers from your use of the
app. If you install Hybridge through the App Store or TestFlight, Apple may
provide the developer with aggregate, non-identifying installation and crash
statistics under Apple's own terms; this is controlled by Apple, not by the app.

## Children

Hybridge is not directed at children and does not knowingly collect any data
from children.

## Changes to this policy

This policy may be updated as the app changes. Material changes will be
reflected by updating the effective date above and the version distributed with
the app.

## Contact

Questions about this policy or your data can be sent to:

**jfoucher@gmail.com**

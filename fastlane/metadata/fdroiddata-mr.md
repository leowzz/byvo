## New app: byvo (`cn.wleo.byvo`)

This MR proposes adding `byvo` to the main F-Droid repository.

### App overview

byvo is a Flutter-based Android voice transcription client.

It records audio, sends it to a compatible backend for transcription, and can insert the resulting text into the currently focused input field using Android accessibility and overlay features.

Upstream repository:
- https://github.com/leowzz/byvo

License:
- Apache-2.0

Source code and metadata:
- Source code is public and up to date in the upstream repository
- Fastlane metadata is included upstream under `fastlane/metadata/android/`

### Build notes

- Android app ID: `cn.wleo.byvo`
- Upstream version currently set to `1.2.3+123` in `pubspec.yaml`
- This is a Flutter/Gradle project built from source
- The project already builds successfully from the command line in upstream

### Backend / network behavior

The Android client depends on a compatible network backend for actual transcription.

Important context:
- The backend is configurable by the user
- A compatible FastAPI backend is included in the same upstream repository under `backend/`
- The app itself does not bundle proprietary Android libraries such as Firebase / Google Play Services
- The backend code and docs currently reference Doubao / Volcengine / Ark services

Because of that, reviewers may want to assess whether an Anti-Feature such as `NonFreeNet` applies. I am not asserting the final label here, only flagging it for review.

### Permissions / sensitive capabilities

The app requests and documents these Android capabilities:
- `INTERNET`
- `CAMERA`
- `RECORD_AUDIO`
- overlay window
- accessibility service

These are used for:
- audio recording
- QR code scanning for backend setup
- backend communication
- quick overlay-triggered recording
- inserting transcribed text into the active input field

### Upstream metadata/assets

Included upstream:
- localized fastlane title / short description / full description
- localized changelog for version code `123`
- icon
- feature graphic
- phone screenshots

### Suggested metadata fields

- SourceCode: `https://github.com/leowzz/byvo`
- IssueTracker: `https://github.com/leowzz/byvo/issues`
- License: `Apache-2.0`
- Categories: `Multimedia`, `Productivity`

### Notes

If needed, I can also prepare a starter `metadata/cn.wleo.byvo.yml` based on the current upstream repo structure and release version.

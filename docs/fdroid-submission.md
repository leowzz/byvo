# F-Droid Submission Notes

This repository contains the upstream metadata needed for F-Droid under `fastlane/metadata/android/`.

## App ID

- `cn.wleo.byvo`

## Current upstream version state

- `pubspec.yaml` currently declares `version: 1.2.3+123`
- Existing Git tags currently go through `v1.1.1`

Before opening the F-Droid submission MR, create a matching upstream release tag for the version you want F-Droid to build. F-Droid metadata works best when tags and Android version codes are monotonic and unambiguous.

## Likely review points

- The Android app is Free Software, but useful operation depends on a network backend.
- This repository includes a self-hostable FastAPI backend, which reduces ambiguity around server compatibility.
- The bundled backend currently references Doubao / Volcengine / Ark services in the backend code and docs. F-Droid reviewers may decide that the app needs an Anti-Feature such as `NonFreeNet`.
- The app requests sensitive Android capabilities:
  - microphone
  - camera
  - overlay window
  - accessibility service

These should be explained clearly in the store listing and submission notes.

## Assets

Included in this repository:

- localized title / short description / full description
- localized changelog for version code `123`
- icon and feature graphic under `fastlane/metadata/android/`
- phone screenshots for `en-US` and `zh-CN`

Still recommended before submission:

- replace generated or provisional store assets if you want more polished listing graphics

## Submission flow

1. Push this repository state to GitHub.
2. Ensure the release tag and `pubspec.yaml` version are aligned.
3. Open a new app request / merge request against `fdroiddata`.
4. In the MR notes, explicitly mention:
   - build command is based on Flutter/Gradle from source
   - backend is configurable by user
   - repository includes the backend implementation
   - reviewers should assess whether `NonFreeNet` applies because of the documented backend service dependencies

## Suggested initial metadata fields for fdroiddata

- SourceCode: `https://github.com/leowzz/byvo`
- IssueTracker: `https://github.com/leowzz/byvo/issues`
- License: `Apache-2.0`
- Categories: likely `Multimedia`, `Productivity`

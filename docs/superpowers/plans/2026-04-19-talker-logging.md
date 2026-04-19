# Talker Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom client debug log window with Talker-based logging and expose a debug-only viewer from the homepage.

**Architecture:** Add a shared Talker instance for app and network logs, remove the custom `DebugLog` file-based plumbing, and route existing UI/debug logging calls through Talker. The homepage gets a debug-only action that opens Talker’s built-in log screen.

**Tech Stack:** Flutter, talker, talker_flutter, talker_dio_logger

---

### Task 1: Add shared Talker setup

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart`
- Create: `lib/app_talker.dart`

- [ ] Add Talker dependencies and create a shared Talker module.
- [ ] Initialize Talker before `runApp`.
- [ ] Remove the old `debugPrint` to custom-window redirection.

### Task 2: Remove custom debug log implementation

**Files:**
- Delete: `lib/debug_log.dart`
- Modify: `lib/main.dart`

- [ ] Remove custom debug log state, overlay log file polling, and related imports/constants that only existed for the debug window.
- [ ] Keep overlay/business logging, but send it to Talker instead.

### Task 3: Replace client log calls and wire HTTP logging

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/transcription/backend_engine.dart`
- Modify: `lib/transcription/realtime_stream_engine.dart`

- [ ] Replace `DebugLog.instance.log`, `logApi`, and debug prints with Talker calls.
- [ ] Use Dio in the backend transcription engine so `talker_dio_logger` can log request/response/error details.
- [ ] Preserve current error handling and user-facing behavior.

### Task 4: Add debug-only viewer entry and verify

**Files:**
- Modify: `lib/main.dart`

- [ ] Add a homepage top-right action that opens Talker’s built-in log screen only in debug/profile-style development mode (`kDebugMode`).
- [ ] Run `flutter pub get`.
- [ ] Run `flutter analyze` or a focused equivalent and one focused Gradle/Flutter verification command if needed.

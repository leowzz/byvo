# Two-Tab Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the drawer-based single-page layout with a warm, minimal two-tab layout for Home and Settings.

**Architecture:** Introduce a bottom-navigation shell in `main.dart`, keep business logic in the existing stateful page, and reorganize the UI into two focused tab views. Settings move from drawer/dialog style to grouped inline sections.

**Tech Stack:** Flutter, Material 3, existing app state and Talker

---

### Task 1: Build shell and visual tokens

**Files:**
- Modify: `lib/main.dart`

- [ ] Add a two-tab scaffold with bottom navigation.
- [ ] Introduce warm-neutral theme values and lighter grouped-section styling.
- [ ] Remove the drawer.

### Task 2: Recompose Home tab

**Files:**
- Modify: `lib/main.dart`

- [ ] Move testing and floating-ball controls into a dedicated Home tab.
- [ ] Add a compact status summary.
- [ ] Keep transcription actions/results usable but visually secondary.

### Task 3: Recompose Settings tab

**Files:**
- Modify: `lib/main.dart`

- [ ] Replace the settings dialog/drawer flow with grouped inline settings sections.
- [ ] Keep QR scan support.
- [ ] Show Talker entry only in debug mode.

### Task 4: Verify

**Files:**
- Modify: `lib/main.dart`

- [ ] Run `dart format lib/main.dart`.
- [ ] Run `flutter analyze`.
- [ ] Run one focused build command.

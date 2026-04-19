# Audio Test Page Realtime Transcription Design

## Goal

Add a realtime transcription card to the top of the existing audio test page so the test page can validate the same continuous-listening WebSocket flow that previously existed on the home page.

## Scope

This change is limited to the Flutter client test page UI and state handling.

In scope:
- add a new realtime transcription card at the top of the test page
- reuse the existing `RealtimeStreamEngine`
- mirror the current home-page realtime behavior: tap to start, keep listening, auto-disconnect on long inactivity
- show realtime text and connection state in the test page
- keep the current file-based "hold to record" test flow unchanged below it

Out of scope:
- backend protocol changes
- overlay behavior changes
- changes to file-upload transcription flow

## Existing Context

The current `AudioTestPage` only supports file-based transcription:
- user holds to record
- app writes a local WAV file
- app uploads it through `BackendTranscriptionEngine`

The codebase already has a separate `RealtimeStreamEngine` that:
- opens a WebSocket connection to `/api/v1/transcribe/stream`
- streams PCM audio from `record.startStream`
- emits incremental text updates
- emits a connection-closed event when the backend closes the stream
- already supports the current idle-timeout-based auto-disconnect behavior

## Recommended Approach

Add a dedicated realtime section to `AudioTestPage` and keep file-based transcription as a separate lower section.

Why this approach:
- lowest implementation risk because it reuses existing realtime logic
- preserves the current test page flow instead of replacing it
- makes it easy to compare realtime and file-based behavior side by side
- avoids mixing two different interaction models into one button

## UX Design

### Layout

The test page order will become:

1. realtime transcription card
2. text insertion verification card
3. existing hold-to-record upload transcription card
4. error/result cards

### Realtime Card

The new top card will include:
- title: `实时转写`
- subtitle explaining that it starts continuous listening and will auto-stop when idle
- one primary start/stop button
- a small status line showing one of:
  - not started
  - connecting
  - listening
  - stopped
  - auto-disconnected due to inactivity
  - error
- an area showing the latest incremental/full realtime text

### Interaction

Start:
- user taps the realtime button
- UI enters connecting state
- engine starts WebSocket streaming
- if connection succeeds, state changes to listening

During listening:
- incoming text updates are rendered live in the realtime result area
- the button becomes a stop button

Stop:
- user taps stop
- engine stops explicitly
- UI returns to stopped state
- last text remains visible

Idle timeout:
- if backend closes the connection because of inactivity, the page should:
  - exit listening state
  - preserve the latest text
  - show an explicit auto-disconnected status message

## State Model

Add dedicated realtime state to `AudioTestPage`.

Suggested state fields:
- realtime engine instance
- whether realtime is starting
- whether realtime is listening
- whether the last stop was automatic due to idle timeout
- current realtime text
- realtime-specific error string

The existing file-based fields should stay separate so the two test flows do not overwrite each other unexpectedly.

## Error Handling

Errors to surface in the test page:
- microphone permission denied
- missing backend URL
- missing API key
- WebSocket authentication failure
- runtime stream errors

Behavior:
- stop listening state on failure
- keep the last successful realtime text if any
- display the newest error message clearly

## Integration Notes

Implementation should reuse existing helpers and settings behavior:
- backend URL and API key loading from current config
- current LLM/effect toggles already used by realtime flow where applicable
- `RealtimeStreamEngine.connectionClosedStream` for idle auto-disconnect handling

The new UI should not alter:
- current hold-to-record gesture logic
- file upload transcription result rendering
- text insertion verification field behavior

## Testing

Manual verification should cover:
- tap start begins realtime listening
- tap stop ends listening cleanly
- incremental text appears while speaking
- idle timeout causes automatic disconnect and status update
- missing API key or backend URL shows clear errors
- file-based transcription still works after realtime flow
- realtime still works after file-based transcription flow

## Files Expected To Change

- `lib/main.dart`

If the realtime card UI becomes too large, extracting a small helper widget inside the same file is acceptable, but no unrelated refactor is required.

# Nano LiveView micro-stutter diagnostics

This probe measures pacing without changing the UDP session, depacketization decisions, watchdog,
decoder recovery, or presentation policy.

## Instrumented boundaries

The same monotonically increasing frame ID follows a completed camera record through:

1. `udp_frame_arrival`: first UDP video datagram for the camera frame counter
2. `access_unit_complete`: complete Annex-B access unit emitted by the depacketizer
3. `decoder_input`: valid compressed sample submitted to the active decoder/display path
4. `decoder_output`: VideoToolbox callback (only present when the explicit VT assist path is active)
5. `display_submit`: sample/image submitted from the main actor to the active display view

The normal identity path uses `AVSampleBufferDisplayLayer`, whose decoder and physical-display
presentation callback are not exposed by public iOS APIs. Consequently `decoder_output` is blank
for that path and `display_submit` means successful layer enqueue, not a fabricated presentation
timestamp.

## Device output

Every five seconds `control-live.log` gets a `pacing:` line for every stage with sample count,
median, p95, p99, maximum, and counts over 50/66/100/150 ms. It also includes incomplete-frame,
duplicate-fragment, reorder, and IDR-wait counters.

The Documents directory contains `live-frame-pacing.csv`. It is available in Files.app under
**On My iPhone → OpenPocketCine** and through USB file sharing on Windows. Each displayed frame has monotonic stage
timestamps, inter-frame intervals, and a `cause` value for classified gaps:

- `A_udp_source_gap`
- `B_access_unit_completion`
- `C_decoder_output`
- `D_display_or_main_thread`
- `E_timestamp_or_pacing`

Dropped records are retained as `dropped_incomplete_avc`; VCL access units intentionally held
while waiting for an IDR are retained as `dropped_while_waiting_for_idr`.

Disconnect and reconnect the camera to start a fresh CSV. Logging is buffered and file writes occur
on a utility queue, never on the UDP, decoder callback, or main presentation path.

## Test procedure

1. Connect Nano and show LiveView with all assists off for at least 60 seconds.
2. Note each visible micro-stutter, then repeat once with the normally used assists enabled.
3. Retrieve `control-live.log` and `live-frame-pacing.csv` from the app Documents container.
4. Compare the gap rows around the observed time. An empty `decoder_output` column in the identity
   run is expected; it is not a lost decoder callback.

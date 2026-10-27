# B5 protected accessory and mount trial protocol

Status: **not run; hardware access blocked in this session**. Owner Aarav; joint M4 captain Yajat. R04–R08, T13–T22, G3/G4/G8 remain open. Software tests are not physical timing or comprehension evidence. Do not activate ordinary guidance.

## Record before every trial

Record source commit, Xcode/OS versions, phone/watch/headphone model and firmware, operator, reviewer, date/timezone, capability profile, capture backend/revision, performance preset, permission/thermal state, geometry v2 and advanced v1, watch protocol v1 parameters, mount mode, measured camera height (if any), required width/clearance and output choices. Keep clocks identified by device. Use consented recordings or an independent synchronized measurement system for physical latency; a WC acknowledgement is not a felt tap. Do not upload raw imagery or participant data to this repository.

Use a protected stationary area, usual mobility aid and a sighted helper/spotter. No unguarded stairs, roads or collision trials. Start at a comfortable system volume with environmental sounds audible. Use existing comfortable supports; no equipment purchase is required. Stop immediately for discomfort, confusion, missing limitation feedback or unexpected output. Human review is required before accepting results.

## Phone and headphone reference (T20/T21)

1. Start with accessories absent, speech/haptics selected as available. Preview every generic cue and all six advanced families. Confirm text remains available when a channel is absent or muted. Verify urgent preemption, limitation retention and one repeated meaning rather than a burst.
2. Use stereo wired or Bluetooth A2DP **headphones**, not a speaker. Explicitly confirm this in setup. Try left/ahead/right in Settings → Mount and accessory setup, stationary. The reference is the phone's forward axis. Turn the head independently: the product must never claim head tracking. Record misunderstood directions and masking of environmental sound; no exact distance is encoded by volume.
3. Start protected Research capture, confirm mount/coverage/usual-aid checks and phone-forward alignment. Verify unsupported/missing pose disables spatial cues. Head-forward and motion-heading are unsupported. Move beyond the provisional 25° rotation limit, rotate the viewport, lose tracking or expire the frame: alignment must clear, current earcon stop, and recheck be required.
4. Disconnect/reconnect headphones, change output routes, enter mono/phone-call/unsupported routes, and trigger an audio interruption. Route change clears spatial alignment; enabled phone speech/haptics must continue. A true interruption pauses the session. No auto-resume or volume increase. Reconfirm explicitly before another spatial cue.
5. Record capture→accepted event→phone/spatial start→actual audible stop distributions and maximum, including system scheduling/load. Verify the 300 ms original scene deadline and 120 ms earcon bound with an external measurement, not just software logs. Short scene speech is expected to be truncated; it must never be lengthened by changing TTL.

## Watch transport and pause (T22)

1. Build/install LumaPath and the embedded LumaPathWatch companion using the same signing team. Pair on supported iPhone/watchOS 10+ hardware. Enable watch Research cues on phone, start Research capture, then explicitly enable Research cues in the foreground watch app. Default watch output is off.
2. Preview obstacle/urgent/limitation/goal/paused locally on watch. All use a single immediate attention tap with visible meaning, not an unvalidated directional haptic language. Record comprehension and comfort. Already issued WatchKit system haptics have no cancellation API: this is an explicit unresolved physical acceptance constraint, not a claim of cancellable live watch output.
3. Inject transport delay, reorder, duplication, wrong nonce/session/generation/epoch, invalid/nonfinite times, overlong TTL and expired packets. Expect rejection, no acknowledgement renewal and no queued playback. Measure actual send/receive/accept/tap timing. Transport uses immediate messages only: no transferUserInfo, file transfer, application-context replay or retries.
4. Turn Bluetooth off, move out of range, suspend/kill either app, switch paired watches, reconnect and relaunch. Pending cue must be discarded. A new watch-initiated probe and bounded ≤200 ms round trip are required. A two-second clock bound is refreshed without replaying old event IDs. Phone alerts must run independently throughout; no server is involved.
5. Tap Pause both. Watch clears its local state immediately, requests phone pause, then shows confirmed only on the matching phone acknowledgement. With phone unreachable, it must say unconfirmed; pause the phone directly. On phone Pause/Help/End/background, verify no queued watch cue and rejection after expiry/reconnect. A delayed cancellation cannot retract an already issued system tap; quantify this and keep G8 closed if the full requirement cannot be met.
6. Saturate event delivery within bounded histories and vary system load. No unbounded queue, wakeup replay or acknowledgement wait may delay phone start. Record missing/late acknowledgements separately from physical taps. WatchOS foreground behavior is the supported Research scope; no background-delivery claim.

## Mount and advanced families (T13–T19)

Follow [A5's protected sensing protocol](../Sensing/A5-protocol.md). Confirm camera visibility and stable forward alignment in handheld and chest-mounted setups. Only the mode is persisted; alignment and measured rig height are session-local. Arbitrary handheld operation has no camera-height calibration. Camera-only fallback cannot confirm a tracked reference.

Use measured, protected overhead/passage/step-up/step-down/stair fixtures and stationary/moving objects. Verify each independent gate stays closed for ordinary use. Record measured width/height, producer uncertainty, prediction residual/velocity uncertainty and withheld predictions, alongside expected category and actual phrase. No unsupported fit/traversal claim. Missing black-surface depth must stay unknown; a camera sweep must not create object motion. Proximity and limitation events must survive missing advanced predictions. Test earlier-notice/width/clearance settings within the producer contract; unsupported saved widths must be rejected explicitly, never clamped silently.

Pair review must sign each category separately, plus reference comprehension, mount comfort, watch expiry/pause limits and accessibility (VoiceOver, Switch Control, large text, contrast, Reduce Motion). Log actual failures and unresolved hardware gaps. No trial rows or pass counts exist yet.

## API references

- [Apple: AVAudioEnvironmentNode](https://developer.apple.com/documentation/avfaudio/avaudioenvironmentnode)
- [Apple: audio port descriptions](https://developer.apple.com/documentation/avfaudio/avaudiosessionportdescription)
- [Apple: immediate WatchConnectivity messages](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:))
- [Apple: WatchKit haptic playback](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:))

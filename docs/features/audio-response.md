# Audio-responsive wallpapers

Scene wallpapers with authored audio effects and web wallpapers with an audio
listener can react to sound playing on the Mac.

## Enabling it

Select the wallpaper, then turn on **General configuration -> Audio response**
in the inspector. The setting is saved per wallpaper and also applies to that
wallpaper's mirrored displays.

Capture runs only while a wallpaper with audio response on is presenting (not
paused, covered or asleep) and actually reads the sound: an audio-processing
material or particle emitter, a spectrum shader input, or a script that
registers audio buffers. A subscribed web page on screen also counts. A scene
that reads no audio, and every video wallpaper, never starts capture, even with
the setting on; the effects that would have used it received silence anyway. A
script that starts reading later starts capture then, after a short warm-up.
Capture stops when the last such wallpaper stops presenting or is removed.
Activation errors are reported rather than silently ignored.

A subscribed web page owns capture independently of renderer scene handles, so
web-only sessions work and scene cleanup does not stop their audio. Both kinds
of wallpaper share one capture tap; pause and the saved Audio response setting
still gate delivery. A web page the user paused withdraws its own request for
audio until it plays again; the shared poller stops once no page still asks for
audio. Enabling media integration alone does not enable audio response.

## Permission

macOS requests system audio recording permission at capture startup. If access
is denied, grant it in **System Settings -> Privacy & Security -> Screen &
System Audio Recording**, then retry the switch.

## What the input is

The input is sound playing in other apps. It is not the microphone, and it is
not the wallpaper's own playback. The wallpaper mute and volume controls stay
independent of audio response. Capture prefers stereo with separately analysed
left and right channels; a mono fallback supplies the same signal to both. See
[web audio response](web-wallpapers.md#audio-response) for the capture and
128-band listener contract.

## What wallpapers receive

Wallpapers are authored against Wallpaper Engine's numbers, so the analysis
follows what its developer and its docs describe and what tones measure on it.
Its exact formula is not published; where this differs, it is an estimate.

- Captured audio is analysed at 48 kHz, 30 spectra a second, each from its own
  33 ms Hann-windowed block. Nothing is decimated without a filter, so treble
  stays in the treble bands.
- The 64 bands are one ~23 Hz FFT bin wide up to about 400 Hz and then widen
  exponentially to about 15 kHz: an octave tone at 42 Hz, 95 Hz, 190 Hz, 380 Hz,
  760 Hz, 1.5 kHz, 3 kHz, 6 kHz and 12 kHz peaks in the band Wallpaper Engine
  shows it in. The 32- and 16-band resolutions cover the same frequencies with
  the energy of the bands they merge.
- A band's value is its level on a 48 dB scale: 0 at -48 dB or below, about 1
  for a full-scale tone, and occasionally a little above 1, as Wallpaper Engine
  documents. Normal music sits mostly between 0.1 and 0.3 with peaks towards 1.
- Every spectrum stands alone. Wallpaper Engine leaves smoothing to the
  wallpaper, so a visualizer that smooths in its script looks as intended and
  one that does not jumps from frame to frame, as it does there.

Web pages still receive values clamped to 0.0–1.0 (see
[web audio response](web-wallpapers.md#audio-response)); scenes receive them
as analysed.

## Supported effect paths

| Path | Notes |
| --- | --- |
| Shader spectrum effects | Authored audio-reactive shaders |
| Web `wallpaperRegisterAudioListener()` | 64 bands per channel, one shared delivery pump capped at 30 Hz |
| SceneScript `engine.registerAudioBuffers()` | 16, 32 and 64 bands |
| Particle emitters | Box and sphere emitters with audio frequency, bounds and exponent settings |

## Non-goals

- Pre-rendered video wallpapers do not gain reactive effects.
- The [lock-screen extension](lock-screen.md) does not capture system audio.

## Verification

Synthetic offscreen checks cover audio-driven shader color and SceneScript
scale. Device-free controller and bridge tests cover web-only capture startup,
permission, shared ownership, suspension and shutdown; offscreen WebKit tests
cover listener delivery. Live capture and desktop behavior require a separately authorized manual
check. See [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).

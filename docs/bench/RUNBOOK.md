# Running the bench

What to do with the dongle on the desk, in the order that stops a run being wasted. Everything
here is R1 and R2 of the front door's `docs/ios-rewrite-plan.md`.

**One dongle, no spare.** Nothing below burns an eFuse or writes a partition table. Reflashing
over USB is fine; back up NVS before anything that clears it.

## Before the dongle is plugged in

1. **Flash.** `main` carries the phone-position-hint change (`fd3059e`). There is no OTA, so
   this is the USB cable.
   ```sh
   cp include/secrets.h.example include/secrets.h   # or your own
   pio run -e cairn -t upload
   ```
   Write down the commit you flashed. The bench record asks for it and the app cannot know it.

2. **Serial log open, and kept.** The dongle's own `TTFF` line is half of R2's evidence and
   there is no second chance at it.
   ```sh
   pio device monitor -b 115200 | tee ~/cairn-bench-$(date +%F).log
   ```

3. **Install the app.** Xcode, the phone on the cable, Run. Check Settings on the phone shows a
   version, a channel and a commit — a build that cannot say what it is cannot be a bench
   record's subject.

4. **Allow location, and allow it as Always.** Without it the phone lends the receiver nothing
   and R2 measures nothing. The Dongle screen says which answer it got.

## Do the link rows before you set up a server

An enrolled phone starts carrying trips the moment the link is ready, and the dongle holds
standby while it works. That is correct behaviour and it is the wrong thing to have running
while you are timing how long pairing takes: the rows measure the link, and an offload on top
of them measures the link plus an upload.

So: the eight rows first, with no server set up. Then enrol and do R3 and R4. If the phone is
already enrolled, Settings → Server → **Forget This Server**, or expect the Dongle screen to
say "uploading n of m" in the middle of a pairing row. Forgetting replaces the phone's signing
key, so setting it up again needs a fresh invitation code — have one ready before you do it.

## The eight rows

Dongle screen → **Bench** → **Bench run**. **Tap the row's name before you run it.** That drops
a marker into the link log, and it is the only way the exported record can say how long *that
row* took. Each row runs **twice**; a row passes when both runs do.

| Row | What to do | Expect |
|---|---|---|
| Fresh pair | `CLEAR bonds` on the prov console; forget Cairn in iOS Settings › Bluetooth | ready under 10 s, no dialog |
| Dongle reboot | power-cycle the dongle while the app says ready | ready again under 5 s |
| App killed | swipe the app away | iOS relaunches it; ready under 10 s |
| Phone stale | forget Cairn in iOS Settings, leave the dongle's bond alone | the firmware drops its bond on `PINKEY_MISSING`; ready after one retry |
| Dongle stale | `CLEAR bonds` on the dongle, leave the phone's bond alone | `needsForget` within 3 attempts, and the message names the fix |
| Wi-Fi slot | make the dongle drop BLE | backoff, then ready when it comes back, with nothing asked of you |
| Locked phone | lock the phone while ready, then reboot the dongle | ready again with the screen off |
| Weak link | dongle 10 m away behind a wall | discovery fails, backoff with the signal shown, **never** `needsForget` |

Each of these has a unit test of the same name in `CairnKitTests/BenchMatrixTests.swift`, run
against a fake dongle built from this firmware's own behaviour. A row that passes there and
fails here is a radio difference, which is the thing worth finding.

## R2, on a drive

The link rows can be done at a desk. R2 cannot.

1. Cold-start the receiver (power-cycle the dongle, ideally after it has been off a while).
2. Drive with the app armed. The Dongle screen's **Receiver** section fills in as it goes.
3. Afterwards, grep the serial log:
   ```sh
   grep TTFF ~/cairn-bench-*.log
   ```
   The line now carries `phone=sent@<s> pacc=<m>` when the phone's hint went, beside
   `wifi=` and `lastfix=`. Put it next to the app's own line from the same start.
4. **Three starts with the phone and three without**, whatever they show. A hint that does not
   help is a result; a hint that was never sent is a bug, and the app says which it was.

## Afterwards

Dongle screen → **Bench** → **Bench Report**. Share it to yourself and commit it here as
`ble-pairing-<date>.md`. The app fills in the date, the app build and commit, the dongle, the
firmware version from `DEVICE_INFO`, the protocol version and capability bits, the write
length, the per-row timings and the whole link log. It leaves `**[ fill in ]**` wherever a
person is the only source: the firmware commit, which car, and the dongle's own `TTFF` line.

**A row is not Proven until that file is committed.** A green CI run proves nothing about a
radio, which is why `docs/bench/` exists at all.

## If it does not pair

The point of this app is that it can tell you why. The Dongle screen's last error carries the
domain and the number the radio gave, not a sentence someone wrote:

| What you see | What it means |
|---|---|
| `ATT 5` / `ATT 15` | iOS offered a key this dongle will not accept. Forget Cairn in Settings › Bluetooth. |
| `CB 14` | iOS says the dongle forgot this phone. The firmware drops its own bond on this and the next try should be clean. |
| `needsForget` with advice | three pairing failures in a row; the advice names the fix. |
| `CairnLinkDomain#1` | the connect did not complete in 15 s — it went back to scanning. |
| `CairnLinkDomain#2` | nothing answered the scan. Check the dongle is powered and not in a Wi-Fi slot. |
| `CairnLinkDomain#3` | the dongle is missing `GNSS_FIX` or `PROTOCOL_VERSION`. |
| `CairnLinkDomain#7` | the link will take fewer than 28 B per write, after three re-measures. |
| a failed subscription | the dongle's notify characteristics would not take a subscribe. Nobody has seen this yet, because the old app never looked. |

Export the log either way. Firmware
[#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been open since
2026-10-10 for want of exactly this, and it closes on the phone pairing — in which case the
Mac's `bluetoothd` was the fault, and the issue should say so — or it gets retitled with this
log attached.

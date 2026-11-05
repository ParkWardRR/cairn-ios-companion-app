# Running the bench

What to do with the dongle on the desk, in the order that stops a run being wasted. Everything
here is R1 and R2 of the front door's `docs/ios-rewrite-plan.md`.

**One dongle, no spare.** Nothing below burns an eFuse or writes a partition table. Reflashing
over USB is fine; back up NVS before anything that clears it.

## What is on the dongle right now

Flashed 2026-11-05 13:40, so the bench record's "firmware commit" blank is already answered:

| | |
|---|---|
| Firmware | `Cairn cairn-v0.1.0 (beta), policy v1, commit 9ed19671321b6c04` |
| Built | 2026-11-05 13:40:12, from a clean tree at `9ed1967` |
| Replaced | `85158b3`, built 2026-10-26 |
| Device id | `8777228e31648b23f6f783d28eee3e26` |
| Storage | key version 1, **assigned**, counter high-water 175 |
| NVS backup | `~/cairn-backups/nvs-20261105-134111.bin` |
| Card | mounts, 15177 MiB total |
| Bond | the existing one survived the flash — the pairing configuration did not change |
| Server | **not enrolled**; uploads are refused with 403 until it is |

Two things seen at that flash, worth knowing if a row behaves oddly:

- The card threw `GO_IDLE_STATE failed` / `crc error` on the first reset and then mounted
  cleanly on every boot after. The project's own check is two consecutive boots both
  reporting `SD mounted`, which it passes — but suspect the contacts before you suspect the
  code.
- A sealed bundle is already waiting (`0000000000JTKS18WK9BG4R9JD`, sealed while recovering an
  interrupted capture). There is something for R3 to carry when you get there.

## Before the dongle is plugged in

1. **Flash** — *already done for `9ed1967`, see above; this is how, when you need it again.*
   There is no OTA, so it is the USB cable. Use the project's own script rather than `pio`
   directly: it backs up NVS first, and a lost storage root makes every sealed bundle on the
   card unreadable.
   ```sh
   scripts/release-firmware.sh beta --flash /dev/cu.usbserial-10
   ```
   It refuses a dirty tree, runs the host suites, backs up NVS to `~/cairn-backups/`, then
   uploads. Write down the commit it prints: the bench record asks for it and the app cannot
   know it.

2. **Serial log open, and kept — opening it reboots the dongle.** The dongle's own `TTFF` line
   is half of R2's evidence and there is no second chance at it.
   ```sh
   pio device monitor -b 115200 | tee ~/cairn-bench-$(date +%F).log
   ```
   **Open it once, before anything else, and never close it.** Opening the port asserts
   DTR/RTS, which is wired to the ESP32's reset, so **every** open power-cycles the dongle.
   Measured on 2026-11-05: four captures, four different boot ids (`bdf996bb`, `66bd6cff`,
   `d5fb5f41`, `ad69410a`), and deasserting DTR/RTS in pyserial *before* `open()` did not
   avoid it. A reopen mid-run therefore resets the device under test: it voids every timing
   row, and it destroys an R2 cold start, which is the one thing R2 exists to measure.

   After a reset the dongle is **not discoverable for about 11 s** — `sensors_ready` at 7.9 s
   then `boot: ble_advertising` at 10.7 s, from the boot banner. That is inside the app's 20 s
   scan window, so a reboot row still passes; it is not inside 5 s, so do not read the "ready
   again under 5 s" row as starting from the reset.

3. **Install the app.** Xcode, the phone on the cable, Run. Check Settings on the phone shows a
   version, a channel and a commit — a build that cannot say what it is cannot be a bench
   record's subject.

4. **Allow location, and allow it as Always.** Without it the phone lends the receiver nothing
   and R2 measures nothing. The Dongle screen says which answer it got.

## The dongle goes off air for up to four minutes, and the desk is the worst place for it

Read this before you conclude anything is broken. A Wi-Fi uplink slot calls
`ble_companion_radio_off()`, which **deinits the whole BLE stack**: the dongle drops the phone
and advertises nothing at all until the slot ends, bounded by `CAIRN_UPLINK_SLOT_MAX_MS` —
**240 s**. To the phone that is a `CBErrorDomain#6` timeout followed by minutes of
`CairnLinkDomain#2 no Cairn dongle answered the scan`, which reads exactly like a dead dongle.

`slot_blocker()` lets a slot start with a phone connected on purpose: the design is to send
`ANNOUNCE_SLOT` first so the phone knows the disconnect is deliberate. **That announce is a
no-op** — the field is not in the released BLE contract, so `uplink_runner.cpp` logs "the
phone is not told", marks it announced and starts the slot anyway.

A slot needs `parked` **and** `bundles_waiting > 0` **and** Wi-Fi configured **and** home
known. A desk at home with a sealed bundle on the card is all four, so slots fire there
repeatedly — while in a car away from home they would not. Measured on 2026-11-05: a
4 min 11 s blackout (13:55:08→13:59:19) and a 3.4 s one, both from slots.

So before timing any row, make one of those four conditions false. Nothing on the
provisioning console does it — there is no Wi-Fi or uplink command — so the levers are a
build with `CAIRN_WIFI_UPLINK` off (the `#else` branch retires the slot without touching the
radio), or no bundle waiting. **Do not clear the bundle to get there**: R3 needs something to
carry, and `0000000000JTKS18WK9BG4R9JD` is it.

The app's own behaviour through a blackout is correct and is bench row 6: it backs off, keeps
retrying, asks the owner nothing, and comes back ready by itself.

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
| Dongle stale | `CLEAR bonds` on the dongle, leave the phone's bond alone | `needsForget` within 3 attempts, and the message names the fix — expect `CB 15`, not `ATT 5` |
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
| `CB 15` | iOS could not encrypt the link with the key it holds. The same fix, and **this is the one the hardware actually produces** for a stale bond — it lands on the connect, before any read. |
| `CB 14` | iOS says the dongle forgot this phone. The firmware drops its own bond on this and the next try should be clean. |
| `needsForget` with advice | three pairing failures in a row; the advice names the fix. |
| `CairnLinkDomain#1` | the connect did not complete in 15 s — it went back to scanning. |
| `CairnLinkDomain#2` | nothing answered the scan. Check the dongle is powered and not in a Wi-Fi slot. |
| `CairnLinkDomain#3` | the dongle is missing `GNSS_FIX` or `PROTOCOL_VERSION`. |
| `CairnLinkDomain#7` | the link will take fewer than 28 B per write, after three re-measures. |
| a failed subscription | the dongle's notify characteristics would not take a subscribe. Not seen on 2026-11-05: all four took one. |

Before you work down that table, check it is not simply a Wi-Fi slot — see the section above.
`CairnLinkDomain#2` for minutes on end, from a dongle that was ready a moment ago, is a slot
far more often than it is a fault, and the app now says so in its advice.

**Pairing itself was proven on 2026-11-05 and is not the suspect.** From the dongle's log:
`companion connected` → `paired: encrypted=1 bonded=1` in **420 ms**, then `ATT MTU 185`. From
the phone's: `securing` → `read PROTOCOL_VERSION 2 B` in **148 ms**, `ready` at **v1 ·
OFFLOAD, DEVICE_INFO, 182 B writes**, all four subscribes accepted, `DEVICE_INFO` 139 B, and a
second clean pair 38 s later at −81 dBm. See `first-link-2026-11-05.md`.

Export the log either way. Firmware
[#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been open since
2026-10-10 for want of exactly this, and it closes on the phone pairing — in which case the
Mac's `bluetoothd` was the fault, and the issue should say so — or it gets retitled with this
log attached.

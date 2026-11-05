# First link on hardware — 2026-11-05

**Not an R1 record.** The eight rows were not run; this is first contact between the rewritten
app and the dongle, written down because it settles what firmware
[#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) has been asking since
2026-10-10 and because it found a different fault worth naming before the bench.

| | |
|---|---|
| App | `0.2.0 (91) · beta · 766fcbe`, built for the device, not the simulator |
| Phone | iPhone 15 Pro, `00008130-0011102C3A30001C` |
| Firmware | `9ed19671321b6c04` (beta), flashed 2026-11-05 13:40 |
| Dongle | device id `8777228e31648b23f6f783d28eee3e26`, on USB at a desk, not in a car |
| Server | not enrolled, so no offload and no upload ran |
| Evidence | phone `Documents/cairn-drive.log`; dongle `~/cairn-bench-2026-11-05.log` |

## Pairing works, and that is new

Every attempt paired, five for five, with no dialog and no owner action — the bond from before
the flash was reused.

From the dongle, one session:

```
15799 [BLE] INFO  companion connected
16219 [BLE] INFO  paired: encrypted=1 bonded=1      ← 420 ms
16552 [OFFLOAD] INFO  ATT MTU 185
```

From the phone, the same session:

```
13:59:23.031 link securing  → securing · reading PROTOCOL_VERSION; iOS pairs here
13:59:23.179 link securing  read PROTOCOL_VERSION 2 B        ← 148 ms
13:59:23.179 link ready     → ready · v1 · OFFLOAD, DEVICE_INFO, 0 B writes, -79 dBm
13:59:23.194 link ready     write length 182 B
13:59:23.389 link ready     subscribed to GNSS_QUALITY
13:59:23.600 link ready     subscribed to COMPANION_STATUS
13:59:23.840 link ready     subscribed to OFFLOAD_CONTROL
13:59:24.152 link ready     subscribed to OFFLOAD_DATA
13:59:24.291 link ready     read DEVICE_INFO 139 B
```

Two things nobody had ever checked:

- **All nine characteristics are discovered**, `0030` and `0031` among them. The old app's filter
  hid those; this one discovers with no filter and sees them.
- **All four notify subscriptions are accepted.** The runbook's "nobody has seen this yet" row is
  answered: the `READ_ENC`-on-notify idiom does secure the CCCD write without refusing it.

So the Mac's `bluetoothd` was the fault in #44, and the issue should say so.

## What is actually broken: the link will not stay up

Pairing is not the problem. Staying connected is. Five sessions, every one ended by the dongle
with **reason 520** — `0x200 + 0x08`, an HCI supervision timeout:

| Session up at | Lasted |
|---|---|
| 15.8 s | 13.1 s |
| 167.3 s | 20.1 s |
| 215.3 s | 3.0 s |
| 219.8 s | 15.6 s |
| 279.3 s | 6.1 s |

Nothing survived 21 s. On the phone the same drops arrive as `CBErrorDomain#6` (timed out),
`CBErrorDomain#15` (failed to encrypt), and once `CBATTErrorDomain#1` (the handle is invalid).
The app's response is correct throughout — it retries, backs off to a 15 s ceiling, reaches
attempt 7, and never asks the owner for anything — but a link with a 20 s ceiling carries no
trips.

**Cause not established**, and interleaving the two logs rules out the obvious one: of the six
`reason 520` disconnects, **only one coincided with a Wi-Fi slot**. Pairing succeeded on every
attempt. So this is its own fault, not a side effect of the slot problem below. Candidates:

1. **Signal.** The run sat at −77..−81 dBm from the phone and −78/−82/−87 from the Mac at desk
   range, which is past where this dongle has been measured to fail elsewhere (it joins an
   access point at −66..−68 and fails at −71..−72). Supervision timeouts are what a marginal link
   produces. Worth ruling out first because it is free: move the dongle off the USB hub into
   clear air. Treat the numbers with some caution though — several raw readings came back as
   `rssi 127`, which is CoreBluetooth's "unavailable" marker, not a measurement.
2. **Connection parameters.** The firmware sets none at all, so the link runs on whatever iOS
   proposes and the device never asks for anything roomier.

What is *not* a candidate any more: stale GATT handles. A link that dies 1.7 s after a successful
pair, repeatedly, is not an attribute-handle problem — and the one `CBATTErrorDomain#1` that
suggested it is better explained by #71.

The firmware sets no connection parameters at all — no `updateConnParams`, no supervision
timeout — so the link runs on whatever iOS proposes. Worth knowing before tuning anything.

## "Failed to encrypt the connection" is not a bond problem, and nearly fooled me

Later in the same session the link stopped getting as far as a read at all:

```
14:15:04.613 link connecting   connected C734EBB4
14:15:05.289 link discovering  disconnected C734EBB4 (reconnecting): CBErrorDomain#6 …
14:15:07.835 link connecting   failed to connect C734EBB4: CBErrorDomain#15 Failed to encrypt
                               the connection, the connection has timed out unexpectedly.
14:15:07.835 link backoff      → backoff · attempt 3, 4 s
```

Read on its own, that is the **Dongle stale** row: iOS cannot encrypt with the key it holds, so
the bond must have gone stale, so the app should reach `needsForget` and say to forget Cairn in
Settings. It was not doing that, so I made it do that — and that was wrong.

**The dongle's own log, through the same window:**

```
713640 [BLE] INFO  paired: encrypted=1 bonded=1
713849 [BLE] INFO  companion connected
716123 [BLE] INFO  companion disconnected (reason 520)
718526 [BLE] INFO  paired: encrypted=1 bonded=1
718856 [BLE] INFO  companion connected
720532 [BLE] INFO  companion disconnected (reason 520)
```

Pairing succeeded on **every** attempt the phone was reporting `#15` on. The bond was in perfect
order. What was failing was the *encryption procedure timing out* — it needs a link that stays up
for a few seconds, and this one was lasting 1.7 s and 2.3 s. `CBErrorDomain#15` here is a second
symptom of the supervision-timeout problem above, not a cause of its own.

So escalating it would have told the owner to delete a working pairing, and the next attempt would
have failed identically. **Both halves of the evidence were needed to see that**; the phone's log
alone points firmly at the wrong answer.

What landed instead:

- **`CB 14`** — iOS saying the peer no longer recognises this phone's keys — is unambiguous, and
  does now count as a pairing failure wherever it arrives, including a disconnect in `discovering`
  rather than only in `securing`. iOS encrypts a bonded link before handing over the service list,
  so a genuine bond failure lands there, not at the version read.
- **`CB 15`** keeps retrying, and its advice now says what it really is: the link did not survive
  long enough to finish securing, that is usually signal, here is the signal, and it is retrying
  by itself — with the forget-the-device instruction offered only as the fallback if it never gets
  through.
- `FakeCentral` gained a `refusesToEncrypt` mode so the matrix can exercise a failure that arrives
  on `connect` at all, which it previously could not, and two rows pin the distinction.

The sharpest lesson of the run is not the fix, it is the near miss. The bench matrix modelled a
stale bond as `refusesRead(ATT 5)`, a shape the radio never produced; the radio's shape looked like
a bond failure and was not. **A fake built from the peripheral's behaviour does not tell you what
the central sees, and the central's error name is not a diagnosis.** A row that passes green
against a fake it shares a mental model with proves less than it looks like it does — and the
plausible-looking fix for a real failure can still be the wrong one.

## Two more things found, neither of them the link

- **The dongle does not come back from a Wi-Fi slot.** This started as "a slot takes it off air
  for up to `CAIRN_UPLINK_SLOT_MAX_MS`, four minutes" — which is what the config allows and is
  **not** what happens. The slots measured were 3.2 to 14.2 s. What produced the 4 min 11 s
  blackout is that after a slot the dongle logs `BLE stack reinited, advertising resumed` and
  then advertises an **empty payload**: a Mac scan dumping the whole advertisement got nothing
  but `kCBAdvDataIsConnectable`, with no local name and no service UUID. Since the app scans
  filtered by the service UUID, a fresh phone can never match it. `ble_companion_radio_on()`
  re-inits the host but never rebuilds the GATT server or the advertising payload, which is
  precisely what `build_gatt_and_advertise()` exists for and is not called on that path.
  Firmware [#71](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/71), and the
  likely root cause of the whole day. A reset fixed it every single time.
- Separately, the `ANNOUNCE_SLOT` meant to warn the phone before a slot is a no-op because the
  field is not in the released contract (firmware
  [#69](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/69)), so even a correct
  3-second slot arrives at the phone as an unexplained drop. The app's advice now leads with
  that rather than telling the owner to re-cable the car.
- And the slots come in **pairs with BLE up for about 60 ms between them** —
  `deinit → reinit → deinit` at 28.336 s / 28.396 s and three more times. Any central that
  connects in that window is killed for nothing.
- **A receipt on the card fails to decode on every boot:**
  `[PRUNE] ERROR receipt does not decode: malformed` and `[OFFLOAD] ERROR receipt for
  0000000000WP23ZA2Z3FB7KSKZ is malformed or does not verify (RECEIPT_MALFORMED)`. The phone was
  never enrolled and sent no offload, so this is the dongle's own stored state, and it is stuck:
  that bundle can never be pruned.

## For whoever runs the rows next

Opening the serial port reboots the dongle — four captures here produced four boot ids. Open the
monitor once, first, and never close it. The runbook now says so, with the 11 s boot-to-advertising
delay that follows a reset.

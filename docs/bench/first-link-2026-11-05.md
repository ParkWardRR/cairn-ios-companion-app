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

**Cause not established.** Two candidates, in order:

1. **Signal.** The whole run sat at **−77 to −81 dBm** at desk range, which is well past where
   this dongle has been measured to fail elsewhere (it joins an access point at −66..−68 and
   fails at −71..−72). Supervision timeouts are what a marginal link produces. The dongle is on
   a USB cable behind a Mac; move it into the open before concluding anything else.
2. **Stale GATT handles.** `ble_companion_radio_on()` rebuilds the GATT server after a Wi-Fi
   slot, which reassigns handles, and the firmware's table has no Service Changed
   characteristic to tell a bonded central to re-read them. `CBATTErrorDomain#1` is what that
   looks like. Seen once, so this is a hypothesis, not a finding.

The firmware sets no connection parameters at all — no `updateConnParams`, no supervision
timeout — so the link runs on whatever iOS proposes. Worth knowing before tuning anything.

## Then the bond went stale, and the app did the wrong thing

Later in the same session the dongle's half of the bond stopped matching, and the link stopped
getting as far as a read at all:

```
14:15:04.613 link connecting   connected C734EBB4
14:15:05.289 link discovering  disconnected C734EBB4 (reconnecting): CBErrorDomain#6 …
14:15:07.835 link connecting   failed to connect C734EBB4: CBErrorDomain#15 Failed to encrypt
                               the connection, the connection has timed out unexpectedly.
14:15:07.835 link backoff      → backoff · attempt 3, 4 s
```

That is the **Dongle stale** row, and the app failed it. It should reach `needsForget` within
three attempts with advice naming Settings › Bluetooth › Forget This Device. Instead it backed off
to its 15 s ceiling and kept going indefinitely, saying nothing useful.

The reason is worth writing down, because the row's unit test passed the whole time:

- The bench matrix modelled a stale bond as `refusesRead(ATT 5)` — the dongle refusing the
  `PROTOCOL_VERSION` read. **The radio never does that.** iOS encrypts a bonded link *before* it
  will hand over the service list, so the failure lands on `connect` as `CBErrorDomain#15`, long
  before there is anything to read.
- `LinkMachine` counted that as an ordinary connect failure, so `pairingFailures` stayed at zero
  and `needsForget` was unreachable by that path.
- `LinkFailure.isEncryptionFailure` had been written for exactly this case — and **nothing in the
  app ever consulted it.**

Fixed: `CB 15` and `CB 14` now count as pairing failures wherever they arrive — on a connect, and
on a disconnect in any state, since on hardware they land in `discovering` as often as in
`securing` — and both earn the advice that names the fix. `FakeCentral` gained a
`refusesToEncrypt` mode so the bench matrix exercises the shape the radio produces, and two rows
pin it.

This is the sharpest lesson of the run: the fake was modelled on the firmware's behaviour, which
was the right instinct, but the failure the *central* sees is not the failure the *peripheral*
logs. A row that passes green against a fake it shares a mental model with proves less than it
looks like it does.

## Two more things found, neither of them the link

- **A Wi-Fi slot takes the dongle off air for up to four minutes**, advertising nothing, and the
  `ANNOUNCE_SLOT` that is supposed to warn the phone is a no-op because the field is not in the
  released contract. One blackout of 4 min 11 s was measured. The phone can only report "no
  Cairn dongle answered the scan", which reads as a dead dongle. Details and the bench
  workaround are in [RUNBOOK.md](RUNBOOK.md); the app's advice now leads with this instead of
  telling the owner to re-cable the car.
- **A receipt on the card fails to decode on every boot:**
  `[PRUNE] ERROR receipt does not decode: malformed` and `[OFFLOAD] ERROR receipt for
  0000000000WP23ZA2Z3FB7KSKZ is malformed or does not verify (RECEIPT_MALFORMED)`. The phone was
  never enrolled and sent no offload, so this is the dongle's own stored state, and it is stuck:
  that bundle can never be pruned.

## For whoever runs the rows next

Opening the serial port reboots the dongle — four captures here produced four boot ids. Open the
monitor once, first, and never close it. The runbook now says so, with the 11 s boot-to-advertising
delay that follows a reset.

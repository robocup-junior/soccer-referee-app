# Module Firmware — BLE Connection Parameters (Supervision Timeout)

> **Audience:** AI agents and developers working on the **robot module firmware**
> (the BLE peripheral), NOT the Flutter app. This document describes a firmware
> change requested after field testing of the RCJ Soccer RefMate app.
>
> **Status:** Requested change — not yet implemented in firmware.
> **Date raised:** 2026-05-30
> **App side:** No app changes required. The app keeps `autoConnect: true`.

---

## 1. Problem observed

During testing on a Google Pixel 10 (Android 16), when a module is physically
unplugged (battery/power lost) and then plugged back in, the **app takes a long
time (up to ~20 seconds) to notice the module disconnected.** In many cases the
phone only registers the disconnect at the moment it next tries to *write*
something to the module.

This is a problem for competition use, where a robot may lose battery contact
mid-match and needs to be detected (and auto-reconnected) quickly.

## 2. Root cause

This is **normal BLE behavior**, not an app bug. A BLE central (the phone) only
learns a peripheral is gone in one of two ways:

1. **Supervision timeout** — the link-layer timer: "if no valid packet is
   exchanged for this whole window, declare the link dead."
2. **A write/operation fails** — the stack discovers the dead link when the app
   tries to use it.

The phone's logs show the supervision timeout is currently negotiated to
**20 seconds**, and this value is **requested by the module firmware** during
connection-parameter negotiation. That 20 s window is the slow-detection cause.

### Evidence from the app (flutter_blue_plus) log

```
onCharacteristicWrite ... status: GATT_ERROR (133)        ← a write hit the dead link
onClientConnectionState() - status=8 connected=false
onConnectionStateChange:disconnected
  status: LINK_SUPERVISION_TIMEOUT                          ← the radio-level timer
...
onConnectionUpdated() - interval=15 latency=0 timeout=2000  ← params (see decoding below)
```

### Decoding the negotiated parameters

| Log field | Raw value | Real value | Meaning |
|---|---|---|---|
| `interval=15` | 15 | 15 × 1.25 ms ≈ **18.75 ms** | Connection interval (one connection event every ~19 ms) |
| `latency=0` | 0 | **0** | Slave (peripheral) latency — peripheral wakes for *every* event |
| `timeout=2000` | 2000 | 2000 × 10 ms = **20 s** | **Supervision timeout** ← this is the value to lower |

> Note: Android may also report intermediate values like `timeout=500` (5 s)
> and `timeout=50` during negotiation/handshake, but the **steady-state**
> connection settles at the firmware-requested `timeout=2000` (20 s).

## 3. Requested firmware change

**Lower the requested BLE supervision timeout from 20 s to ~4 s.**

- **Recommended: 4 seconds.**
- 2 seconds is acceptable if the test/competition RF environment is clean and
  faster detection is desired.
- **Do NOT go below 2 seconds.** See reasoning in §5.

Keep the other parameters as they already are:
- **Slave latency = 0** (already correct — keep it).
- **Connection interval short** (~19–30 ms, already good — keep it short).

## 4. Why this is safe — supervision timeout is NOT "one missed heartbeat"

A common concern: *"If I set the timeout low (e.g. 1 s), in a noisy competition
environment the module will constantly disconnect/reconnect because of missed
heartbeat packets."*

This concern is understandable but the math strongly favors a low timeout,
because of how supervision timeout actually works:

- Supervision timeout fires **only if NO valid packet gets through for the
  entire window** — not if a single packet is missed.
- With a ~19 ms connection interval there are **~30–50 connection events per
  second**, i.e. 30–50 chances per second to exchange one good packet.
- BLE performs **link-layer retransmission** and **frequency hopping across 37
  channels**, so noise on one channel does not kill all events.

To get a *false* disconnect at a 2 s timeout you would need **~70–100
consecutive connection events to all fail back-to-back across hopping
channels.** In practice that only happens when the device is genuinely gone
(unplugged) or fully out of range — which is exactly what we *want* to detect.

### Detection-speed vs false-drop-risk tradeoff

| Supervision timeout | Detect unplug in | False-drop risk in RF noise |
|---|---|---|
| 20 s (current) | up to 20 s ❌ | basically zero |
| **4 s (recommended)** | **~4 s** ✅ | very low |
| 2 s | ~2 s ✅ | low |
| 1 s | ~1 s | starts getting aggressive ⚠️ |

## 5. Why NOT go below 2 s

The deciding factor is **not** missed heartbeats — it's that **reconnect is
slow on the app side.**

The app uses `autoConnect: true` (mandatory for competition: it auto-reconnects
when a robot's battery is restored). With `autoConnect: true`, Android reconnects
using a **low-power, low-duty-cycle background scan**, which is deliberately slow
to save battery. The app log confirms this:

```
autoconnect is true. skipping gatt.close()
```

Because reconnect is slow, a *false* disconnect is expensive — it triggers that
slow reconnect cycle. So we want fast detection of *real* disconnects without a
hair-trigger that causes unnecessary reconnect churn. **4 s (or 2 s)** gives fast
detection while still leaving 100+ connection events of margin before the link
gives up.

## 6. Firmware implementation notes

1. **Keep slave latency = 0.** Latency > 0 lets the peripheral skip connection
   events to save power, which *reduces* the number of heartbeat opportunities —
   the opposite of what we want for fast, reliable detection.

2. **Keep the connection interval short** (~19–30 ms). More events per second =
   more retransmission chances inside the same supervision window = more robust
   at a low timeout.

3. **Respect the BLE spec constraint**, or the central will reject the
   parameters:

   ```
   supervisionTimeout(ms) > (1 + slaveLatency) × connIntervalMax(ms) × 2
   ```

   With slaveLatency = 0 and connIntervalMax ≈ 30 ms, the minimum legal
   supervision timeout is ~60 ms — so both 2 s and 4 s are comfortably valid.

4. The firmware typically requests these via a **Connection Parameter Update
   Request** (L2CAP) shortly after connection, or sets preferred connection
   parameters (the GAP Peripheral Preferred Connection Parameters, "PPCP",
   characteristic) before connecting. Use whichever mechanism the current
   firmware/SDK already uses; only the supervision-timeout value needs to change.

## 7. Acceptance / how to verify after the change

1. Connect a module to the app.
2. In the app/adb logcat, confirm the negotiated params show the new value, e.g.
   `onConnectionUpdated() - ... timeout=400` (400 × 10 ms = 4 s) instead of
   `timeout=2000`.
3. Physically unplug the module. The app should report
   `BluetoothConnectionState.disconnected` within roughly the new timeout
   (~4 s), even when the app is idle and not actively writing.
4. Plug the module back in; confirm `autoConnect` reconnects it.
5. Run a multi-module match (stress/RF check) and confirm modules do **not**
   spuriously disconnect/reconnect during normal play.

---

## Appendix — App-side context (for reference only; do not change app)

- App BLE connect uses `autoConnect: true` (file: `lib/models/module.dart`,
  `bleConnect()`). This is a **critical invariant** — required for automatic
  reconnect during competition. Do not propose changing it.
- The phone-side GATT connection limit is a separate, unrelated issue: the
  Pixel 10 can hold only ~8 simultaneous GATT connections (hardware limit). That
  is handled in the app with a static warning dialog and is **not** related to
  this supervision-timeout change.

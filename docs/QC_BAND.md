# QC Wireless bands (QWatch Pro / Colmi) — experimental

NOOP can also talk to cheap screenless bands and rings made by QC Wireless, the hardware behind
the **QWatch Pro** and **QRing** apps and the **Colmi R0x** rings. Tested against an "H59" band.
macOS only for now.

## Build and run

```bash
./build-mac.sh      # generates the Xcode project, builds NOOP.app, opens it
```

Close any phone app (QWatch Pro, nRF Connect) connected to the band first: it accepts one
connection at a time. Then press Connect in NOOP. The log shows `QC band ready`, then one line per
history pull (`QC: heart rate 0d ago — N samples`, `QC: steps …`, `QC: HRV …`, `QC: SpO2 …`,
`QC: sleep — N nights`).

## What NOOP does with it

On connect: set the band's clock (local time), read battery, turn on its own 5-minute heart-rate,
SpO2 and HRV logging, then pull the last 7 days of history, one request at a time:

| Data | Source on the band | Stored as |
|---|---|---|
| Heart rate (every 5 min) | `0x15` log per day | `hrSample` — feeds strain and the HR charts |
| Live heart rate | `0x69` realtime (Live screen) | `hrSample` + live display |
| Steps | `0x43` per day, 15-min buckets | series `steps` (daily total) |
| HRV (every 30 min, band-computed) | `0x39` per day | series `hrv`; nightly mean → `avgHrv` |
| SpO2 (hourly) | big-data `0x2A` | series `spo2`; nightly mean → `spo2Pct` |
| Sleep (stages) | big-data `0x27` | `sleepSession` + `dailyMetric` (light/deep/REM/awake, efficiency) |
| Resting HR | 10th percentile of HR during sleep | `restingHr` |
| Battery | `0x03` every 30 s | live display |

Band rows are stored under the source id `qc-band`. The dashboard merges them between NOOP's own
computed scores (`my-whoop-noop`) and any WHOOP import (`my-whoop`), filling empty fields from the
layer below. Recovery is scored from the band's overnight HRV and resting HR against your personal
baselines, since the band gives no beat-to-beat R-R intervals. Every 15 minutes, and whenever the
band reports a new heart-rate sample, NOOP re-pulls today's data.

## Identifying one

In nRF Connect the band advertises only `FEE7` and, once connected, exposes:

| Service | UUID | Characteristics |
|---|---|---|
| Command channel | `6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E` | RX `6E400002` (write), TX `6E400003` (notify) |
| Big-data channel | `DE5BF728-D711-4E47-AF26-65E3012A5DC7` | write `…72A`, notify `…729` |
| WeChat steps (ignored) | `FEE7` | `FEA1`, `FEA2`, `FEC9` |

## Packets

Command channel: 16 bytes both ways, `[cmd][14 data bytes][checksum]`, checksum = sum of bytes 0–14,
low 8 bits. Big-data channel: `[BC][type][len u16 LE][2 bytes][len bytes]`, possibly split over
several notifications. Code: `Packages/WhoopProtocol/Sources/WhoopProtocol/QCBand.swift`.

| Cmd | Purpose | Request data | Reply |
|---|---|---|---|
| `0x01` | Set time | BCD `yy MM dd HH mm ss` (local) + language `01` | capability flags |
| `0x03` | Battery | — | `[1]` percent, `[2]` charging |
| `0x15` | Heart-rate log for a day | u32 LE local midnight (band clock) | header `[2]` packets `[3]` min/slot; `01` + u32 + 9 slots; then 13 slots each |
| `0x16` | Heart-rate log config | `02 01 <minutes>` | — |
| `0x2C` / `0x38` | SpO2 / HRV auto-logging | `02 01` = on | — |
| `0x39` | HRV log | u32 LE days ago | header; `01 xx` + 12 slots; then 13 slots (30 min each) |
| `0x43` | Steps for a day | `<daysAgo> 0F 00 5F 01` | `F0` header, then `yy MM dd` BCD, quarter, index, count, kcal u16, steps u16, metres u16 |
| `0x69` / `0x6A` | Start / stop realtime | `<kind> 01` / `<kind> 00 00` (kind 1 = HR, 3 = SpO2) | `69 <kind> <err> <value>` |
| `0x1E` | Keep realtime going | `33` | — |
| `0x73` | Band → app notice | — | `[1]`: `01` new HR, `03` new SpO2, `04` new steps, `0C` battery |
| `BC 27` | Sleep history (big data) | `BC 27 01 00 FF 00 FF` | `[6]` nights; each `daysAgo, bytes, start u16, end u16` + `[stage][minutes]` pairs (2 light, 3 deep, 4 REM, 5 awake) |
| `BC 2A` | SpO2 history (big data) | `BC 2A 01 00 FF 00 FF` | per day `daysAgo` + 24 × `[min][max]` |

Protocol knowledge comes from [tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client)
and Gadgetbridge's Colmi support.

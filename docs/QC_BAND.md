# QC Wireless bands (QWatch Pro / Colmi) — experimental

NOOP can also talk to cheap screenless bands and rings made by QC Wireless, the hardware behind
the **QWatch Pro** and **QRing** apps and the **Colmi R0x** rings. Tested against an "H59" band.
macOS only for now.

## Identifying one

In nRF Connect the band advertises only `FEE7` and, once connected, exposes:

| Service | UUID | Characteristics |
|---|---|---|
| Command channel | `6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E` | RX `6E400002` (write), TX `6E400003` (notify) |
| Big-data channel (sleep, not used yet) | `DE5BF728-D711-4E47-AF26-65E3012A5DC7` | write `…72A`, notify `…729` |
| WeChat steps (ignored) | `FEE7` | `FEA1`, `FEA2`, `FEC9` |

There is **no** standard Heart Rate service (`180D`), so the band never gives beat-to-beat R-R
intervals.

## Packets

Every packet in both directions is 16 bytes: `[cmd][14 data bytes][checksum]`, checksum = sum of
bytes 0–14, low 8 bits. Pure code + tests: `Packages/WhoopProtocol/Sources/WhoopProtocol/QCBand.swift`.

| Cmd | Purpose | Request data | Reply |
|---|---|---|---|
| `0x01` | Set time | BCD `yy MM dd HH mm ss` (UTC) + language `01` | capability flags |
| `0x03` | Battery | — | `[1]` percent, `[2]` charging |
| `0x15` | Heart-rate log for a day | u32 LE UTC midnight | multi-packet, see below |
| `0x16` | Heart-rate log config | `02 01 <minutes>` = enable every N min | — |
| `0x69` / `0x6A` | Start / stop realtime | `<kind> 01` / `<kind> 00 00` (kind 1 = HR, 3 = SpO2) | `69 <kind> <err> <value>` |
| `0x1E` | Keep realtime going | `33` | — |
| `0x73` | Band → app notice | — | `[1]` = what changed (`01` = new HR data) |

Heart-rate log reply: `15 00 <packets> <minutes per slot>`, then `15 01 <u32 LE day start> <9 slots>`,
then `15 nn <13 slots>` until `nn = packets − 1`. Each slot is bpm (0 = no reading). `15 FF` = no data.

## What NOOP does with it

On connect: set the band's clock to UTC, read battery, enable 5-minute heart-rate logging, and pull
yesterday's and today's logs. Every 30 s it polls battery; every 15 min (and whenever the band says it
logged a new sample) it re-pulls today's log. The Live screen's realtime HR uses `0x69`. All samples go
into the same `hrSample` table as WHOOP data.

Not yet: steps, SpO2, sleep (big-data channel). HRV/recovery won't be accurate without R-R intervals.

Protocol knowledge comes from [tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client)
and Gadgetbridge's Colmi support.

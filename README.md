# DevPulse v0.2

A deliberately small Pock widget for system status on the Touch Bar.

```text
[cpu] ⠀⣀⣠⣴⣿  12%   [mem] ⣤⣤⣤⣤⣤  63%   [battery] ⣿⣿⣿⣿⣿  84%
```

Each reading has an SF Symbol icon, a dot-matrix history graph and the current value.
Memory is the exception: instead of history it shows the current value as a RAM stick: 4 chips, each split into a top and bottom half, so 8 sections of 1/8 of RAM.
The bottom halves fill left to right, then the top halves.
The graph has one column per sample (newest on the right). By default it's 5 dots
tall, one lit dot per 20%; dot size, rows and columns can be changed in Preferences. By default that's 10 columns, the last 30 seconds at the 3-second poll.
Each column's colour comes from its own value: white normally, yellow at 70% or more,
red at 90% or more. Battery columns are yellow at 20% or less, red at 10% or less,
and green while plugged in. While charging, the empty dots above the level
fill upward in a diagonal wave. When the Mac is running on the adapter without
charging (for example, held at full), the lit dots switch off and back on at random, in 2×2 blocks and as single dots while their colour slowly cycles
green → blue → green (10 s per cycle). The battery percentage is hidden in this state. Memory dots breathe (dim and brighten) when macOS
reports memory pressure: slowly at warning, quickly at critical. After Pock starts or the Mac wakes, each graph is filled with the first reading: it starts fully
lit and the dots above the reading switch off at random over about a second, instead of growing one column per refresh. A reading that isn't available shows `—`; CPU shows it
for the first 3 seconds while it takes a baseline.

## Requirements

- Touch Bar MacBook Pro
- Pock installed
- Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Build + install

```bash
chmod +x build.sh
./build.sh
```

Then:

1. Open **Pock**
2. Open **Customize Pock...**
3. Drag **DevPulse** onto the Touch Bar

Tap the widget to force an immediate refresh.

## Preferences

Open **Pock → Preferences → Widgets Manager**, select **DevPulse**, and open its
preferences to:

- show or hide CPU, Memory, or Battery
- set the dot size (1.5–5 pt)
- set the rows: 3–8 dots, or **Full height** (as many as fit the Touch Bar for that dot size)
- set the columns, which is the number of samples in the history graph (3–40)
- set the size of the numbers (8–16 pt)
- set the refresh interval (1–10 s)

Changes apply without restarting Pock. A new refresh interval takes effect on the next tick.
They're stored in the `com.st4rdhoom.devpulse` defaults domain
(`defaults delete com.st4rdhoom.devpulse` resets them).

## Design notes

- Polls only while the widget is visible (every 3 s by default)
- All readings come from native APIs; no processes are spawned
  - CPU: `host_statistics(HOST_CPU_LOAD_INFO)`, non-idle ticks between two samples
  - Memory: `host_statistics64(HOST_VM_INFO64)`, "Memory Used" as Activity Monitor
    counts it (app + wired + compressed) over physical RAM
  - Battery: IOKit power sources (`IOPSCopyPowerSourcesInfo`)

## Next versions

- v0.4: Kubernetes context + production warning
- v0.5: tap modes / compact layout

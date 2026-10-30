# Native callback profiling

Build fresh Debug/testable products with `bash Tools/ci-macos.sh Debug`, then use
the product directory printed by that gate:

```sh
python3 Tools/profile-macos-collectors.py \
  --products /path/to/xrg-ci-Debug.RUN/DerivedData/Build/Products/Debug \
  --results /path/to/new-profile-results \
  --iterations 60 --interval 0.25
```

CPU, Memory, Network, Disk and Battery are included by default. Add `--hardware`
to read GPU/VRAM and temperature/fan sources. No hardware controls are written.
NPU async execution, AI/providers and process inspectors are excluded. For a
Rosetta run on Apple silicon, use `--architecture x86_64` and the gate's
`X86DerivedData/Build/Products/Debug` products; it does not validate physical Intel.

The helper copies/signs the framework locally, uses a generated temporary UUID
preference domain and unscheduled timers, and removes that domain after the run.
It does not load or change the installed app's preferences. Results include callback
and whole-cycle count, minimum, median, nearest-rank p95, maximum and total durations
in milliseconds, setup duration, basic source availability, host/helper architecture,
OS/model, and framework/helper-source hashes. Samples are bounded to 1–300 and the
finite delay/graph target to 0.2–10 seconds. Invalid arguments fail before output
creation. Each cycle waits the requested delay before collection; actual starts
also include callback execution time.

The internal module-manager hook measures normal callbacks on the main actor,
including source calls and cached-label work. It reads no timing clock when its
observer is absent. Invalid/reversed timing clocks drop the measurement, while
still invoking the collector. Callback recipients/names are snapshotted before
invocation, preserving mutation and visibility behavior. The hook also supports
fast and five-/thirty-minute dispatches; this helper profiles normal cycles only.

These are Debug measurements of one machine under its current load. Cache/gated
hits are included: Battery and Temperature do not necessarily read hardware on
every callback, and VRAM can reuse the shared GPU sample. Callback counts are not
hardware-read counts. Failed/unavailable sources can also return quickly; consult
`sourceStatus`. Setup is separate, drawing is excluded, and no real menu/event
tracking or whole-app responsiveness benchmark is performed. Background worker
duration cannot be inferred from a short main-thread enqueue callback. Use the
profile to select a source for further tracing; retain cancellation, generation,
source-identity, publication-time and accounting contracts in any worker rewrite.

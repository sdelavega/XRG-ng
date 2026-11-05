# Sensor identity investigation stopping point

Stopped at the user's request on 2026-11-04 to control credit cost and obtain
a different model's perspective. Do not automatically resume investigation.
Branch: `fix/ai-log-same-size-rewrites`. Source checkpoint `863a6ac`; evidence
documentation through `da238bf`, all pushed before this handoff.

## Shipped and validated

- `aa1e973`: Mac17,4 TAOL → Ambient light sensor temperature, from the actual
  AOP `als-temp` → zEAO slot zero → SMC input 99 chain.
- `13a8b8e`: Mac16,11 TfC0–4 → Power management temperature maximum 1–5
  (filtered average), from two captures → maximum → low-pass → sample mean.
- `863a6ac`: Mac17,4 NAND CH0 temp / TN0n HID → Storage composite temperature,
  from NVMe SMART log 2 composite. Other models retain their channel names.

Both hosts passed 660 tests per architecture (arm64 and Rosetta x86_64),
universal build and packaged-app checks. The latest M5 full script initially
failed one unrelated AI accounting timing test; the complete Rosetta suite
and remaining packaged checks passed on retry without source/test changes.
Preserve that distinction. Logs: `dist/storage-composite-name-validation/`.
Native probes checked 58 selected M5 labels and 84 M4 labels plus storage HID.

## Unresolved: do not claim completion

- M5: 26 readable generic fields. Fourteen are actively sampled AON channels:
  six Ta keys from `a0va`, eight Ts keys from `s0va`. Physical publisher → AON
  destination remains missing. Twelve others are TPDD/E/F and nine Tz1* fields.
- M4: 12 readable generic fields: TPDF/TRDF/TTDF and nine Tz1* fields.
- Exact fixed normal typed graphs now contain no configured sampling edge for
  those twelve fields on each platform. Tz extra pointers are diagnostic
  monitor consumers. No runtime rebinding mechanism was identified there.
  M4 F averages receive empty-window zeros; all twelve M5 fields are group one
  and have only zero-fill initialization established, no average flush.
- This does not establish hardware absence, reserved fields or physical sites.
  Do not invent identities or hide readings from zero/default flags alone.

Full ledger: `macos-sensor-identity-status.md`; hashes, addresses, proof scope:
`macos-smc-firmware-investigation.md` and `macos-pmp-bank-investigation.md`.

## Most useful fresh lead

TG Pro 2.104 constructs some strings through obfuscated NSString character
appenders, so raw resource/key scans were insufficient. Native metadata found:

- Built-in converter `convertKeyNameToHumanString:usingSensorArrayForNumbering:useCaching:`
  at arm64 `0x10015310c` (ends before `0x1001547ac`).
- `getValidM1SensorsForPrefix:startIndex:skipCount:stopAt:` at `0x10001f2e0`.
- Large `getIconsFor:uiElements:` at `0x10001f508..0x10011a908` builds strings
  through these appenders. Relevant discovery calls: `0x1000561cc`,
  `0x100057a38`, `0x100059408`; first prefix is `Tp`, start 1, skip 3.
- Example appenders: `tbs4714` at `0x10016ec84` appends T; `tbs8750` at
  `0x10016e888` appends p; `D5` at `0x10016f260` appends 2.

This is an unfinished lead, not a recovered map. Artifacts:
`dist/tgpro-builtin-naming/`; binary under
`dist/sensor-reference-artifacts/tgpro-2.104/TG Pro.app/Contents/MacOS/TG Pro`.
Root's Hopper converter job was interrupted for this stopping point; its output
may be empty/incomplete. No target application was executed or installed.
Do not inspect activation/licensing paths or ship proprietary catalogue data.

## Avoid repeating completed searches

- Official diagnostics exact profiles, repair catalogue, iStat exact-model and
  global recipes supplied no remaining key identities. The TG supplied-text
  loader only splits a user file; it is separate from the built-in lead above.
- Exact DeviceTree equals current live PMP/scoped PTD configuration; no extra
  boot-only map. Production PTD user client rejects calls; ptdR absent in SMC.
- Current LLB and iBoot AV bank-two publisher vectors are empty in that selected
  constructor family. Named PMP ANE0 autonomous destination is a different PTD
  route, not an a0va join. AON consumer packing/Q6 layout is fully verified.
- New SmartIO lead was bounded: live map-range provides MISC only. PMGR_AON
  consumes the unmapped MINI pair, and its traced function reads/logs registers.
  No publication bridge found. See `dist/aon-missing-component-audit/`.
- Native source closures: `dist/m4-pmuf-source/configured-closure/` and
  `dist/m5-unmapped-input-closure/`; AON layout: `dist/aon-consumer-contract/`.

Havana validation checkout is `/tmp/xrg-havana-validation.ljiGW2`, owned by
this task; SSH `sdelavega@Havana`. Original checkout/install were untouched.
Local M5 is Mac17,4/J815/26C5035r; Havana M4 Pro mini is
Mac16,11/J773s/26B123, chosen chip 0x6040 (not arm-io's 0x6041).
Root owned Hopper lifecycle; workers used native static tools. Workers were
interrupted at the user's stop request. Proprietary inputs remain ignored.

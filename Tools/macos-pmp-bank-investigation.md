# PMP bank configuration checkpoint

Investigated 2026-11-04, continuing the
[SMC provider trace](macos-smc-firmware-investigation.md). This resolves the
static configuration and callback target previously left open. It establishes
no new SMC physical labels. Application behavior is unchanged.

## Artifact and constructor links

The input is the decoded 26B123 `t8142pmp` Mach-O, SHA-256
`6c669ae08e0a58db7f0c10795ba2edda23c59196ee08e1636fd6f3938ebc6fa5`.
Its Mach-O segments map file offsets explicitly; the first mapped byte has
file offset `0x1000`, virtual address `0x1000000`. Addresses below belong
only to that image.

The constructor at `0x1010c20` stores its configuration argument at object
offset `0x180` and provider-container pointer `0x1057198` at `0x188`.
Global initialization near `0x1037984..0x1037c8c` supplies these explicit
objects and configurations:

| Component string | Object | Configuration | Bank | Word at configuration + 0x174 + bank*56 |
| --- | --- | --- | ---: | --- |
| `EACC0` | `0x1059f60` | `0x104db00` | 0 | `0x8c` |
| `PACC0` | `0x105a480` | `0x104e0b8` | 0 | `0xa4` |
| `PACC0` | `0x105a480` | `0x104e0b8` | 1 | `0xa6` |
| `PACC0` | `0x105a480` | `0x104e0b8` | 2 | `0xa8` |
| `ANE0` | `0x105aed0` | `0x104eb58` | 0 | `0x2a5` |

Each configuration begins with a pointer to the corresponding component
string. CPU constructors at `0x1037bc8` and `0x1037be4` pass through
`0x1010cec`, which calls the same base constructor. ANE initialization at
`0x1037c8c` later selects its subclass vtable `0x1045bf0`.
These are static initial values, not a capture of initialized runtime objects.
Initialization near `0x1014450..0x101445c` copies existing configuration to a
stack buffer; `0x1014ab8..0x1014ac0` copies the updated buffer back. Thus the
configuration is mutable, and the static values alone cannot prove runtime
state.

## Resolved callback target

The following chain is supported by raw instructions and constant pointers:

1. `0x10237a8` registers callback `0x1023904` with the per-bank selector.
2. The callback follows object+`0x188`, container+`0x10` to object `0x1049c98`.
3. Its vtable is `0x1044d38`; method+`0x28` is `0x1007b30`.
4. That method preserves the selector, selects object `0x1056898`, sets
   argument two to zero and dispatches method+`0x28` again.
5. Initialization at `0x1007a90..0x1007b00` installs vtable `0x103c4e8`
   on this object. Its method+`0x28` is `0x102b000`, which sets argument
   three to one, argument four to zero and tails `0x102b27c`.
6. The final method divides the selector by the configured bank width,
   bounds-checks the bank and remainder, and writes a single-bit mask to a
   register window. Its zero/nonzero enable argument selects register
   offsets `0x14400`/`0x14600`, with bank stride `0x4a00` and word offset
   `(remainder >> 5)*4`. Some paths update bookkeeping instead of a register.

This is a mask/unmask-style control path, consistent with interrupt handling;
that interpretation is derived from the instructions. It is not a temperature
sample store. The selector must not be treated as an SMC PTD output index.
No firmware instructions or register operations were executed for this check.

## Packet paths and next boundary

The firmware separately reads packet data through `0x10222f0`, which takes a
group and index, uses object+`0x260` to obtain the group's start and cached
buffer, and calls `0x101d33c` for an uncached entry. That path reads a
16-byte PTD entry; it is distinct from the callback's bit-mask operation.

Current M5 `pm-ptd-ranges` selects IDs 5, 6 and 7 for packet groups zero,
one and two, respectively. Their named ranges are `PMS-PMGR-PKT`,
`PMS-DPE-PKT` and `PMS-DEVC-PKT`. Range nine, `SOC-DEV-PKT`, is a separate
selection. The previous interval-membership observation for range nine
does not supply the missing device assignment.

The unresolved link is now the origin/layout of the PTD packet data that
contains SMC source starts `0x150` and `0x152`, rather than construction of
the callback selector. A useful next trace must join the actual packet
source or its hardware configuration to those starts. Repeating the callback
trace, matching source letters, or stripping long PMP label suffixes cannot
establish it. `Tz11`'s writer remains a separate unresolved question.

Ignored evidence is retained in `dist/smc-bank-configuration-validation/`
and the prior `dist/havana-smc-artifact-discovery/` LLVM export. The REA
session was closed with snapshot `pmp-bank-configuration.rea.json`.
Independent bounds-checked decoding in ignored
`verify_bank_configuration.py` passed all five named bank records,
constructor/dispatch pointer checks and packet-group range-ID checks;
its result is `bank-configuration-checks.json`.
Constructor evidence is
`ev_59f59f64ff0fa80afddd3054512b30795bb53b561534c4e99b55ea69cb672e91`;
final mask-method evidence is
`ev_1e8e08e23162c2131df2890836062b1eb6a31fda9897f079ab05479fb5251c31`.
Decompiler output has merged procedure boundaries and register-recovery
errors; raw LLVM instructions determine the arguments and offsets above.

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

## Follow-up: packet-address and host-driver boundaries

The PMP packet reader's configured address comes from descriptor `0x1048708`:
base `0x3803c0000`, extent `0x40000`. This follows the constructor's separate
descriptor argument copied to object+`0x1a0`; object+`0x1c8` is not the
provider-container pointer at object+`0x188`. The distinction matters when
tracing `0x10222f0` through its two pointer loads to the packet window.
PMP initialization at `0x101d2c4` maps the descriptor through `0x1013008`.
The final reader at `0x101d33c` loads 16 bytes at `window + index*16`.

The j815 SMC image also contains a descriptor with base `0x3803c0000`, at
`0x8cf88` with its base at +8. Its named Ts/Ta reader instead uses the
separately configured base `0x38c840000` at `0x8f078`. Thus PMP range-index
arithmetic must not be used as a Ts/Ta mapping without establishing the
cross-window source relationship. Different configured addresses alone do
not prove distinct physical sources or an address-space alias.

The current M5 device tree now supplies an independently checked address
bridge. Its `/arm-io/ranges` maps child `0x0` to parent `0x210000000`
over `0x3f0000000` bytes. All four `aon-ptd` child register windows translate
uniquely to the addresses published by its `AppleARMIODevice` provider:
`0x38c840000`, `0x38c850000`, `0x38c858000` and `0x38c860000`, each
`0x4000` bytes long. The calculated Ts00, Ta00 and Ta04 source slots
(`0x38c861500`, `0x38c861520`, `0x38c861522`) fall inside the fourth
published window. This establishes the configured AON address relationship;
it does not identify the sensor producing each slot. It also does not join
the separate PMP packet window to those producers.

Ignored `dist/aon-source-routing-validation/` retains scoped DT properties,
published provider memory metadata and `aon-address-translation-checks.json`.
The checks compare static 26B123 SMC addresses with current 26C5035r device
metadata; they do not establish the executing firmware image's identity.
Only registry properties were read, with no MMIO access.

The selected local restore kernel collection contains additional named
host-driver paths. Standalone analysis copies retain their original VM
coordinates and segment bytes while relocating Mach-O file offsets:

| Fileset entry | Derived SHA-256 |
| --- | --- |
| `AppleH16ANEInterface` | `fb55a3890aa3ae8f03464f12b6c94d9ec2fa4a99e294f70d580ad137bc511ada` |
| `AppleT8142ANEHAL` | `4e1926a702675d9ba188d6f6131c12f343e72b089677cbe2ff7dd17965a41399` |
| `ApplePTD` | `7e9b9a1a4d0ebd806cdf0c587d4d23ff718345bb81e479b6872e74407a2b9cd9` |
| `AGXG17G` | `d9de40da7983bd3519f228da2af8718885ec5ebdb8ba9421eac50a8003cd96ce` |

The collection SHA-256 is
`313fa26bfed80317cd94725640013d08a80a9c629ba0efb1ac13eee359bde3f6`.
Kernel-collection chained fixups remain unmaterialized in the standalone
copies. They support named-function and instruction inspection, with limited
indirect-reference coverage. They were not loaded, and their identity with
executing kernel code has not been established.

`ANEHWDevice::ThermalPTDTimerTimeOut_gated` at
`0xfffffe0009669a48` samples configured thermal registers and conditionally
writes through `ANERegisterControl::write64`. Its setup is variant-dependent
in `ANEHWDeviceConfig::initializeANESoCConfig` at `0xfffffe0009679e78`.
The selected live `/arm-io/ane` metadata has `ane-type = 0x210` and
`pmp-virt-notify = 1`. The corresponding static switch branch selects
`AppleT8142ANEHAL`; offsets from other hardware branches cannot establish
this host's SMC mapping. This pass establishes the named driver path, but
no alias from it to `a0va`, `s0va` or a compact SMC key.

The GPU driver's concrete `populateAONPTDIdentifiers` override at
`0xfffffe0008c08c28` supplies identifier `g0TR`. It does not by itself join
the separate `g0va` bank to a physical sensor location. Two generic
implementations inspected at `0xfffffe0008b7d620` and
`0xfffffe0008c031f4` simply return an unsupported result.

These findings narrow further work to actual source routing or a driver /
firmware path that explicitly identifies an AV source. The earlier generic
PMP callback cannot provide that identity.

Ignored `dist/smc-ptd-driver-validation/` retains the original extraction
script, per-image segment manifests, scoped hardware properties and closed
REA snapshots `ane-driver-ptd.rea.json` / `agx-driver-ptd.rea.json`.
`source-boundary-checks.json` independently checks the configured bases and
live ANE selector. ANE setup evidence is
`ev_0954628a629da02f7733ea2ac2a38628993d8fa35e63d7feb74e203902e87c3e`;
thermal sampling evidence is
`ev_16abb7832f126ee3060b76f568c6ac656716aaa2fd4dec9c2fdafd7052269b2c`.

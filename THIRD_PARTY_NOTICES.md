# XRG-ng third-party notices

The project license is GPL-3.0-or-later; the full text is in LICENSE.
The original project headers permitted GPL version 2 or any later version,
which permits choosing GPL version 3. Existing third-party copyrights and
licenses remain in force for their respective files.

## Apple Public Source License 2.0

The following source files retain APSL 2.0:

- `Data Miners/APSL/SMCInterface.h`, `SMCInterface.m`, and `SMCPacket.h`: Apple Computer, Inc., 2004; native-boundary modifications by Stephen de la Vega, 2026.
- `XRGCore/XRGSMCInterface.swift`: Swift translation of the original SMC interface and CodeExchange decoder; Apple Computer, Inc., 2004, CodeExchange, 2012; modifications by Stephen de la Vega, 2026. This translation remains APSL 2.0.
- `Data Miners/APSL/SMCSensors.h`: CodeExchange, 2012, and Apple Computer, Inc., 2004.
- `XRGCore/SMCSensors.swift`: Swift translation of `SMCSensors.m`, CodeExchange, 2012; modifications by Stephen de la Vega, 2026. The translation remains APSL 2.0.
- `Data Miners/APSL/AppleHIDUsageTables.h` and `IOHIDEventTypes.h`: Apple Computer, Inc., 1999–2003.

The full license is preserved in `Data Miners/APSL/APSL.txt` and included
in macOS app resources as `APSL.txt`. First-party sensor adapters and grouping
code keep their GPL notices; the APSL-derived Swift translation is listed above.

The macOS app currently compiles the SMC implementations into its executable.
The FSF lists APSL 2.0 as incompatible with the GNU GPL. Keeping both license
texts does not resolve that incompatibility: distribution of the combined
executable requires a compatible replacement, suitable permission, or another
resolved licensing arrangement. This project license update does not claim
to resolve that existing issue.

Reference: https://www.gnu.org/licenses/license-list.en.html#apsl2

## Legacy Apple header

`Other Sources/ppp_msg.h` retains its Apple Computer, Inc., 2000 notice
under APSL 1.1. Its original license reference is preserved in the file.
It is a legacy source header, separate from the APSL 2.0 sensor implementation.

## Other contributors

Other authors' source notices and Git authorship remain part of the project
attribution. The project credits in COPYRIGHT do not supersede them.

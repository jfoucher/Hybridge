# Third-party notices

Hybridge itself is MIT-licensed (see [`LICENSE`](LICENSE)). It bundles and
cross-references the third-party material below.

## Bundled fonts (SIL Open Font License 1.1)

The bundled fonts are shipped inside the app (`Resources/fonts/`) and used for
watchface text rendering. The OFL requires the license to travel with the
fonts — that obligation is independent of Hybridge's own MIT license. The full
license text plus both copyright headers is in
[`Resources/fonts/OFL.txt`](Resources/fonts/OFL.txt).

| Font | Copyright | Upstream |
| --- | --- | --- |
| IBM Plex Mono | © 2017 IBM Corp., Reserved Font Name "IBM Plex" | https://github.com/IBM/plex |
| Instrument Serif | © 2022 The Instrument Serif Project Authors | https://github.com/Instrument/instrument-serif |

## Gadgetbridge (AGPL-3.0) — cross-reference only, no code included

Hybridge's BLE protocol is an **independent implementation** of the Fossil
`qhybrid` file protocol. During development it was cross-checked for
correctness against Gadgetbridge's `qhybrid` device support
(https://codeberg.org/Freeyourgadget/Gadgetbridge, Java, AGPL-3.0) and against
byte dumps captured from real hardware.

**No Gadgetbridge source code, assets, or other copyrightable material is
copied into or distributed with this project.** Gadgetbridge served purely as a
reference oracle for observable protocol behavior (frame layouts, CRC keying,
handshake ordering), which is not itself subject to copyright. Because nothing
from Gadgetbridge is included, no AGPL-3.0 obligation attaches to Hybridge. This
acknowledgement is offered in good faith to credit the project whose
reverse-engineering work made this independent implementation possible.

## Bundled watchfaces

The watchfaces in `Resources/bundled_faces/` are author-original faces produced
by this project's own `moon-watch` build pipeline (see that directory's
`README.md`). They are not Fossil's compiled assets.

## `Resources/ring.caf` — find-my-phone alert tone

Author-original. This bundled CoreAudio (`.caf`) tone, used for the
find-my-phone ring, was created by this project's author and carries no
third-party copyright. It ships under Hybridge's MIT license.

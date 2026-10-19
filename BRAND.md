# Name, icon and artwork

Kagami's **source code** is free software under the [GNU Affero General Public License, version 3 or any
later version](LICENSE) (AGPL-3.0-or-later).

The **Kagami name and its brand assets are not covered by that licence.** They stay © 2026 Gino de Graaff
(mostlygino), all rights reserved:

- the name "Kagami" and "鏡" used as the name of this app;
- the app icon (the Kyōhai bronze mirror) in `Resources/AppIcon.icns`, and its alternates in `docs/brand/`;
- the mostlygino seal in `Resources/mostlygino.png`;
- the images in `docs/brand/` and `docs/screenshots/`;
- the DMG and installer artwork that `scripts/make-installer-art.swift` draws (the script itself is AGPL code,
  as are `scripts/make-icon.swift` and `docs/brand/readme_art.py`).

You're welcome to show them when you write about, review or link to Kagami. If you **fork** Kagami and
distribute your fork, give it a different name and icon, so people can tell the two apart: replace
`Resources/AppIcon.icns` and `Resources/mostlygino.png` and change the name in `Info.plist`. The code is yours
to use under the AGPL either way.

## Third-party software

- [Wireshark](https://www.wireshark.org) (`tshark`, `sharkd`, `dftest`, `editcap`), GPL-2.0-or-later. Not in the
  repository or the app: you install it yourself, and Kagami runs it as a separate program.
- [nfdump](https://github.com/phaag/nfdump), BSD licence, optional, also installed separately; Kagami runs it to
  read nfcapd files.

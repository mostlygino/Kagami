# Security

Kagami reads network traffic, runs Wireshark's tools on files you open and, through its MCP server,
lets AI clients read captures. Security reports are welcome and taken seriously.

## Reporting a vulnerability

Please report privately through GitHub: **Security > Report a vulnerability** on this repository
(a private security advisory). Do not open a public issue for a vulnerability.

Include what you found, how to reproduce it, and the Kagami version (Kagami > About Kagami > Copy).
You will get a reply on the advisory; fixes ship as a new signed release.

## What is in scope

- The `kagami` CLI and its MCP server: escaping the write folder (`~/Documents/Kagami` or
  `KAGAMI_MCP_OUTPUT_DIR`), starting a live capture without `KAGAMI_MCP_ALLOW_CAPTURE=1`, crashes or
  hangs from crafted requests.
- The updater: anything that gets an unsigned or wrongly signed build installed, or code from a
  release run before its signature is checked.
- Parsing of capture and flow files: crashes, hangs or memory blow-ups from crafted input.
- Captures left readable by other users (live captures are written 0600 in a 0700 folder).

Bugs in Wireshark's dissectors themselves belong with the [Wireshark project](https://www.wireshark.org/security/).

## Verifying downloads

Every release asset has a detached GPG signature (`.sig`) from the release key
`4C49 B6E8 DC9F 50C8 0A1A 20B8 05BE 68B6 158B 9E08`, which is also in this repository at
`Resources/release-key.asc`, and the release lists SHA-256 sums.

```sh
gpg --import Resources/release-key.asc
gpg --verify Kagami-0.1.0.dmg.sig Kagami-0.1.0.dmg
```

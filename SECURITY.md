# Security policy

## Supported versions

Security fixes are currently applied to the latest commit on `main`. MagicDock is pre-1.0 software;
older commits and local forks are not supported.

## Threat model

MagicDock assumes both Macs are on a trusted local network. It protects control commands with:

- a randomly generated 256-bit secret stored in macOS Keychain;
- HMAC-SHA256 authentication and integrity;
- a signed sender identifier, timestamp, nonce, and payload;
- a two-minute clock window and an in-memory replay cache;
- bounded, length-prefixed network frames.

The pairing secret is never transmitted by MagicDock. Users copy it between their Macs as the
explicit trust step.

The protocol does **not** encrypt traffic. A network observer can see message sizes and the JSON
envelope, including selected Bluetooth device metadata, but cannot create or modify an accepted
command without the shared secret. Do not use MagicDock across an untrusted network.

The app is intentionally not sandboxed because it uses legacy `IOBluetooth` behavior, including an
undocumented selector for removing pairing records. That private dependency is isolated in
`NativeBluetoothManager` and is the primary platform risk.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability
reporting at:

<https://github.com/LouisAyroles/MagicDock/security/advisories/new>

Include the affected commit, macOS version, reproduction steps, and expected impact. You should
receive an acknowledgement within seven days.

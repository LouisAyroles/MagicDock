# Contributing

Thanks for helping improve MagicDock.

## Before opening a pull request

1. Open an issue for behavior changes that affect the Bluetooth handoff or wire protocol.
2. Keep macOS-private API usage isolated behind `BluetoothManaging`.
3. Add or update tests for every state-machine, framing, or authentication change.
4. Run the complete local checks:

   ```sh
   make format
   make lint
   make test
   make app
   ```

5. Never include real Bluetooth addresses, pairing keys, logs containing secrets, or signing
   certificates in a commit.

## Design principles

- The app must remain local-first and usable without an account or backend.
- A failed transfer should attempt to leave the devices usable on the source Mac.
- Network input is untrusted even after discovery; authenticate before decoding commands into
  actions.
- Prefer public Apple APIs. If a private behavior is unavoidable, isolate and document it.
- Keep the core testable without real Bluetooth hardware.

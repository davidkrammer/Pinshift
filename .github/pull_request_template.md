## Summary

Describe the user-visible behavior and why the change is needed.

## Verification

- [ ] Xcode Mac tests and iPhone companion build
- [ ] Python worker tests
- [ ] `git diff --check`
- [ ] Application UI remains English-only
- [ ] No generated app/build files, logs, device IDs, local paths, or pairing data

## Safety impact

Explain any effect on Start, Restore GPS, target-device selection, reconnect,
heartbeat, worker termination, or pending-clear behavior. Write “None” when the
change cannot affect those paths.

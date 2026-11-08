# Sharing evidence with a Mac, behind Face ID

## The constraint that shapes everything

`UIFileSharingEnabled` is read from `Info.plist` **at launch**. You cannot switch it on after
Face ID succeeds, and there is no API that reveals or hides an app's Documents folder at
runtime. So "only when the user authenticates" cannot be implemented by gating the flag.

What can be gated is the **contents**. That is what this does:

| Layer | Location | Visible to a Mac? |
|---|---|---|
| Library of recordings | `Library/Recordings/…` | Never |
| Share window | `Documents/Share/<stamp>/…` | Only while a session is open |

`Documents` is the only thing File Sharing exposes, and outside a window it is empty. The
evidence never moves: the window contains **hard links**, which are additional names for the
same bytes.

## Why hard links

- **Instant**, even for 40 GB. It is an inode operation, not a copy.
- **No extra disk.** The link and the original share one set of bytes.
- **Removal cannot damage the original.** Unlinking a name does not touch the data; the
  recording stays exactly where it was, still hash-chained.
- **Atomic to close.** Deleting the window directory removes thousands of names in one pass.

If a link fails — a full volume, an odd resource fork — the controller falls back to a copy so
the transfer still works. That is the only path where bytes are duplicated.

## The flow

1. The user taps *Unlock for Mac access*.
2. `LocalAuthenticator` runs `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`.
   That policy is **Face ID / Touch ID with the device passcode as fallback**, which is what
   "password or fingerprint" means on iOS. Use
   `.deviceOwnerAuthenticationWithBiometrics` if you want to refuse the passcode path.
3. On success, `SharePlan` builds the file list and the controller links it under
   `Documents/Share/2026-11-08_143212/…`, mirroring the on-device tree so two sessions that
   both contain `hour-00001.mp4` do not collide.
4. A countdown starts (ten minutes by default). The window closes on: expiry, backgrounding,
   the device locking, or the user tapping *Lock now*.
5. On close the directory is removed. The Mac's view of the evidence disappears; the evidence
   does not.

**"If it is registered"** resolves in step 2: `canEvaluatePolicy` returns false when no
passcode is set or biometrics have been wiped by failed attempts. In that case sharing is
refused with an explanation rather than falling open — the failure mode of an access control
must be "closed".

## What the user does on the Mac

1. Unlock the share window on the iPad (Face ID). Leave the app in the foreground — it must not
   lock, because locking closes the window.
2. Connect the iPad by cable, then in Finder select the device ▸ **Files** ▸ *Continuous
   Recorder* ▸ `Share/<stamp>/`.
   Without a cable: Files app ▸ *On My iPad* ▸ *Continuous Recorder* works the same way.
3. Copy what you need. When the window closes, the folder empties.

Locking the device mid-copy **aborts the transfer**. That is the intended behaviour and the
reason the countdown is on screen: set Auto-Lock to *Never*, or keep the app in Guided Access,
for the duration of a large pull.

## Security properties, stated honestly

What this gives you:

- The library is not browsable when no window is open — not in Finder, not in the Files app.
- Opening a window requires the owner's biometric or passcode **every time** (`reusableFor`
  defaults to zero, so there is no grace period).
- A window cannot be left open by accident: it dies on lock, on backgrounding, and on a
  timer, and any window left by a crash is deleted at next launch.
- Every open and close is written to `Library/Recordings/share-access.jsonl`, with the reason
  for closing.

What it does not give you:

- **It is not encryption.** Recordings are plaintext on disk, protected by the iOS Data
  Protection class while the device is locked. Someone with the passcode and a Mac can open a
  window; that is what "device owner" means. If the threat model includes passcode holders,
  you need envelope encryption with a key the device cannot unwrap (see
  `Docs/TAMPER-EVIDENCE.md`).
- **A window exposes the whole library**, not a chosen file. Files past `fileLimit` are
  dropped from the *oldest* end and the count is shown in the UI — silently truncating an
  evidence export would be worse than refusing it.
- **During the window, anyone at the Mac can copy.** Time-boxing limits the exposure; it does
  not eliminate it.
- **No per-file audit.** The log records that a window opened with N files, not which file a
  particular Mac read — iOS gives no such signal.

## Cost

Effectively zero. A window links in a few milliseconds, adds no bytes, and the countdown is a
one-second timer that only runs while the window is open. The Mac pays for the transfer.

## Verifying it

1. With no passcode set on the device, tap *Unlock for Mac access*: you should get the refusal
   message, and `Documents/Share` should not appear.
2. Set a passcode, set up Face ID or Touch ID, retry: the prompt appears with the reason text.
   Cancel it and confirm no directory was created.
3. Authenticate successfully, then connect the Mac. Finder should show
   `Share/<stamp>/<yyyy-MM-dd>/<HHmmss-id>/…`.
4. Lock the iPad. The Finder window should empty within a second — that is
   `protectedDataWillBecomeUnavailableNotification` doing its job.
5. Re-authenticate and let the timer run out. Same result, with
   `"share closed (expired)"` in `share-access.jsonl`.
6. Check the originals are untouched: `Library/Recordings` still holds every file, and
   `ChainVerifier` still passes.

One build detail that bites everyone once: **Face ID requires `NSFaceIDUsageDescription`**.
Without it the app terminates the moment you evaluate the policy. It is already in
`Info.plist`, along with `NSMotionUsageDescription` and the camera and microphone strings.

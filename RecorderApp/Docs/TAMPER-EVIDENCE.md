# Tamper evidence for an on-prem installation

## The one sentence version

You cannot stop someone who physically holds the device from deleting a file. You *can*
make undetected modification, deletion, splicing or silent shutdown infeasible — but only
if the evidence leaves the device faster than an attacker can alter it.

Everything below is arranged around that. The hash chain is the part people ask for; the
off-device anchor is the part that actually works.

## Threat model

| # | Attacker | Can they get the plaintext? | What stops them |
|---|---|---|---|
| T1 | Has the iPad, no passcode | No | iOS Data Protection; Secure Enclave key is non-exportable; envelope encryption for at-rest |
| T2 | Has the passcode, or a jailbreak | Yes | Nothing local. Only the off-device copy and heartbeat matter here |
| T3 | Pulls the NAND / a backup | No | Data Protection class; no iCloud backup; envelope encryption |
| T4 | Edits files in transit to the server | No | TLS + per-link signature + server-side re-hash |
| T5 | Silently stops the recorder, covers the lens, cuts power | — | Heartbeat expiry, coverage ledger, expected-file-count check |
| T6 | Swaps the whole device for another one | — | `bootID` + the public key in the chain; an unfamiliar key is an alarm |

Be clear about T2, because it is where most "tamper-proof" claims fall over: **an attacker
with code execution on the device can ask the app to sign anything.** A Secure Enclave
signature proves "this app on this device produced this", not "no human touched the
device". The defence against T2 is architectural: get the bytes off the box, to storage the
device cannot rewrite.

## Layer 1 — the hash chain (`Sources/Core/TamperChain.swift`)

One link per closed media file:

```
link[n].previousHash = SHA-256(canonical(link[n-1].payload))
link[n].signature    = ECDSA-P256(SHA-256(canonical(link[n].payload)))
```

What that buys you:

- **Edit one byte of any file** → the recomputed SHA-256 no longer matches the signed value.
- **Delete or reorder a middle file** → the next link's `previousHash` no longer matches.
- **Swap a file for another file of the same size** → hash mismatch, same as above.
- **Forge a link** → you need the private key, which lives in the Secure Enclave and cannot
  be extracted, not even by the app that owns it.

What it does not buy you: **truncation**. Delete the last three links and the remaining
chain is internally consistent. `TamperChainTests.testDeletingTheLastLinkIsInvisibleLocally`
asserts this so that nobody "fixes" it by accident — the fix is Layer 3, not more crypto.

## Layer 2 — the signing key

`SecureEnclaveSigner` creates an ECDSA P-256 key with
`kSecAttrTokenIDSecureEnclave` and `.privateKeyUsage`, accessible
`AfterFirstUnlockThisDeviceOnly`. Properties that matter:

- The private key never enters the app's memory and cannot be exported, backed up, or
  restored onto another device.
- Signing requires the device to have been unlocked at least once since boot.
- If the device is wiped, the key is gone and the old chain can no longer be extended —
  which is correct behaviour, but it means **export the public key at enrolment** and keep
  it with the evidence, or you cannot verify later.

`SoftwareSigner` exists for the simulator and for tests. Every link records `signerID`, and
the verifier reports software-signed links as a warning, so a chain signed this way can
never quietly pass as hardware-backed.

## Layer 3 — the off-device anchor (the only real defence)

The chain is generated on the device, so the device's copy is only as good as the device.
Close the loop:

1. **Push each file as soon as it closes.** Hourly segments → hourly upload. To storage with
   object lock enabled (S3 Object Lock in compliance mode, MinIO with locking, or a WORM
   appliance). Compliance mode means not even the account owner can rewrite it before the
   retention date expires — that is what "on-prem tamper-proof" actually means in practice.
2. **Push the chain head** — the highest `(index, hash, signature)` — with every upload, and
   keep every historical head. A head you already hold cannot be un-seen.
3. **Heartbeat every 60 s** to the collector. Include the head hash and the monotonic
   uptime. Missing heartbeats for > 3 minutes is an alarm, not a log line. This is what
   catches "someone unplugged it" and "someone pressed stop".
4. **Verify server-side.** Never trust the device's own verdict. The device can be lied to;
   the collector cannot be, if it re-hashes independently.

Retention and verification are the same job: if the collector holds `(file, hash, signature,
public key)` from an hour ago, local deletion is an incident, not a data loss.

## Layer 4 — encryption at rest

Two separate concerns, often confused:

- **Data Protection class.** Use `.completeUntilFirstUserAuthentication` for the recordings
  directory. `.complete` would make files unreadable while the device is locked, which
  breaks continuous *audio* recording — a trade-off worth understanding before switching.
- **Envelope encryption.** Generate a per-session AES-256-GCM key, encrypt each segment,
  and wrap the session key with a public key whose private half lives on the server. The
  device then holds only ciphertext plus a key it cannot unwrap alone. Steal the iPad and
  you have a bag of noise; the collector can still decrypt after the fact.

For an on-prem box whose main risk is "someone walks off with the iPad", Layer 4 is what
turns theft into an inconvenience.

## Layer 5 — device hardening

| Control | Why |
|---|---|
| Supervised + MDM | Enables the controls below; lets you wipe or locate remotely |
| Single App Mode | The app cannot be exited; the home gesture, notification banners and app switcher are gone |
| Guided Access (no MDM) | Poor man's version: triple-click to lock the app on screen |
| Passcode + "Erase Data" | 10 failed attempts wipes; note this also destroys the chain key |
| **File sharing, if you enable it** | The flag itself cannot be gated — it is read at launch. Keep recordings in `Library/Recordings` and expose them only through the authenticated, time-boxed window in `Docs/SHARING.md`. Otherwise anyone with the device can browse, copy and delete through Files |
| USB Restricted Mode | On by default; do not disable it for a "convenient" charging cable |
| No iCloud backup for the folder | Already set via `isExcludedFromBackup`; a 43 GB/day video stream must never hit iCloud |
| Disable screenshot/screen recording (supervised) | Stops a bystander exfiltrating a live frame |

## Layer 6 — physical

An on-prem device is a physical object. If the threat includes someone with hands on it:

- Locked enclosure, tamper-evident seals on the seams, no exposed ports or cables.
- Ventilation. A sealed box plus continuous video equals thermal shutdown within hours —
  which looks exactly like tampering in the logs, and will waste your investigation time.
- If the device itself is in the threat model, point a second camera at it. Nothing in
  software beats a witness.
- Mains power with a small UPS: an outage is the cheapest way to make an hour of footage
  unreadable (an `AVAssetWriter` file is only playable after `finishWriting`).

## Chain format, precisely

A verifier in any language needs these four rules and nothing else:

1. **Canonical payload** — JSON, keys sorted by code point, compact separators, UTF-8,
   no ASCII escaping, no escaped slashes. In Python:

   ```python
   json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
   ```

   which for a genesis link produces exactly (408 bytes):

   ```json
   {"bootID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","byteSize":1932735283,"durationMilliseconds":3600000,"fileName":"hour-00001.mp4","index":1,"monotonicMilliseconds":4123456,"previousHashHex":"0000000000000000000000000000000000000000000000000000000000000000","recordedAt":"2026-11-07T09:15:03.442Z","relativePath":"hour-00001.mp4","sha256Hex":"9f2c000000000000000000000000000000000000000000000000000000000000"}
   ```

   All timestamps are ISO-8601 UTC with milliseconds. **No floats anywhere** — `3600` and
   `3600.0` are different bytes, which is why durations are integers in milliseconds.

2. **Link hash** — `SHA-256(canonical payload)`, lowercase hex. This becomes the next
   link's `previousHashHex`. Genesis is 64 zeros.

3. **Signature** — ECDSA P-256 over SHA-256 of the canonical payload, DER-encoded, base64
   in the JSON. Produced by `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)`,
   verified with CryptoKit or `cryptography` — they interoperate.

4. **Public key** — X9.63 uncompressed point, 65 bytes, base64. Export it once at enrolment.

A verifier checking a directory should, in this order:

1. parse `chain.jsonl` line by line (a truncated last line means a crash mid-write — that
   link is invalid, the rest still verifies);
2. rebuild each canonical payload and check `index` is 1..n with no gaps;
3. check `previousHashHex` linkage from the genesis hash;
4. verify every signature against the enrolled public key;
5. re-hash every file on disk and compare to `sha256Hex`;
6. check cadence: 24 files per day for hourly segments, ± the configured tolerance;
7. compare against the collector's stored heads — this is the step that detects truncation.

Step 5 is why a chain never verifies on the device that wrote it *after* an edit: the hash
is over the finished container, so re-encoding, trimming or re-muxing the file invalidates
it. That is a feature — it also means you must hash the file **after** `finishWriting`
completes, never before, or you will sign a hash of a file that no longer exists in that
form.

## Deployment checklist

- [ ] Supervised device, MDM profile, Single App Mode
- [ ] Passcode set, Erase Data on, USB Restricted Mode left alone
- [ ] Recordings live in `Library/Recordings`, not `Documents`; sharing goes through the
      authenticated window (`Docs/SHARING.md`), never through a standing folder
- [ ] Public key exported and filed with the retention policy
- [ ] `Signing key tag` recorded — rotating it changes the identity
- [ ] Collector: object lock / WORM bucket, retention ≥ your evidence obligation
- [ ] Collector: independent re-hash on receipt, alert on mismatch
- [ ] Heartbeat alarm at 3 minutes, file-count alarm at 2× segment duration
- [ ] Clock: authenticated NTP; alert when `monotonicMilliseconds` and `recordedAt` disagree
      by more than the boot offset — that is a clock change or a forged timestamp
- [ ] Thermal alarm: `.serious` for more than 10 minutes means the enclosure is wrong
- [ ] Quarterly: restore an archive, verify it end to end, time the exercise

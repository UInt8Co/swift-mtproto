# ``MTProtoCrypto``

The cryptographic primitives MTProto is built on.

## Overview

MTProto composes standard primitives in ways no general-purpose library exposes:
AES in IGE mode, SHA-1/SHA-256 key derivations with fixed byte layouts, and RSA
without a standard padding. This module implements exactly those pieces, over
swift-crypto, as pure functions of their inputs — so each one can be checked
against the published test vectors.

It knows nothing about sessions, transports or schemas: values in, values out.

## The handshake

Creating an auth key (<https://core.telegram.org/mtproto/auth_key>) needs four
pieces: ``PQChallenge`` for the proof of work, ``RSAPrivateKey`` to recover the
client's `p_q_inner_data`, ``HandshakeKDF`` for the key and IV that protect
`server_DH_inner_data`, and ``AESIGE`` to apply them. ``BigUInt`` carries the
Diffie–Hellman exponentiations.

Two RSA layouts exist, and both are supported because clients differ: the "old"
one, where the block is `SHA1(data) ‖ data ‖ random`, and the RSA_PAD scheme
(summer 2021) that wraps the payload in an AES/SHA-256 construction. Try
``RSAPrivateKey/recoverDataFromRSAPad(_:)`` and
``RSAPrivateKey/recoverPlaintextBlock(_:)`` in turn; only the former can report
"not this layout" — it has an integrity check — which is what makes the order
matter.

Both recovery methods reject ciphertext that is not a 256-byte integer below
the modulus before private-key computation. Old-style recovery returns empty
data for an invalid block; its caller must still verify the SHA-1 prefix.
``RSAPrivateKey/rawDecrypt(_:)`` remains a low-level operation for validated
inputs. RSA integrity checks use ``MTProtoConstantTime``.

``RSAPrivateKey/isConsistent()`` is worth calling at startup. A fingerprint is
computed from `n` and `e` alone, so a key whose `d` belongs to a different key
still advertises a *correct* fingerprint: clients find it, encrypt to it, and the
handshake dies at the decryption step with random garbage — a failure that looks
like anything but a bad key file.

## Messages

The 2.0 encrypted message layer (<https://core.telegram.org/mtproto/description>)
is ``MTProtoMessageCrypto``: the `auth_key_id`, the `msg_key` over a slice of the
auth key, and the AES-IGE key/IV derived from both. The `x` offset (0 or 8)
follows the *message's* origin, not who is processing it, so both ends of one
message use the same value.

The superseded MTProto 1.0 construction lives on the same type, behind
`legacy`-prefixed members. It survives for one reason: Perfect Forward Secrecy
(<https://core.telegram.org/api/pfs>) requires `auth.bindTempAuthKey`'s inner
`encrypted_message` to use it with the permanent key.

## Two-step verification

``SRP`` implements Telegram's
`passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow`, i.e. SRP-6a
over a 2048-bit group, per <https://core.telegram.org/api/srp>. The group is an
``SRP/Group`` value rather than a constant, so a deployment can configure or
rotate it; ``SRP/Group/telegram2048`` is the well-known one. Naming follows the
spec: `salt1` is the client salt, `salt2` the server salt, and every group element
is 256 bytes big-endian.

Proof verification rejects an `A` that is not 256 bytes or an `M1` that is not
32 bytes before big-integer work. Callers must also bound concurrent handshakes
and password checks: valid cryptographic operations remain expensive.

## Constant time

Comparisons of secret-dependent values go through ``MTProtoConstantTime`` so
response timing cannot become an oracle. Lengths are not secret: MTProto
authenticators are fixed-size, so a length mismatch already means "reject".

``BigUInt`` is *not* constant-time, and is not meant for secrets beyond the
handshake exponentiations it exists for.

## Topics

### Handshake

- ``PQChallenge``
- ``RSAPrivateKey``
- ``HandshakeKDF``
- ``BigUInt``

### Messages

- ``MTProtoMessageCrypto``
- ``AESIGE``

### Passwords

- ``SRP``

### Support

- ``MTProtoConstantTime``
- ``MTProtoCryptoError``

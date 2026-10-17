#ifndef CMTPROTO_AESIGE_H
#define CMTPROTO_AESIGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether this CPU has the AES instructions (AES-NI or the ARMv8 Cryptography
/// Extensions) the two functions below require. They must not be called when
/// this returns 0.
int cmtproto_aes_hw_available(void);

/// AES-256-IGE encryption of `length` bytes (a multiple of 16) with a 32-byte
/// `key` and 32-byte `iv`. `output` may equal `input` but must not otherwise
/// overlap it.
void cmtproto_aes256_ige_encrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length);

/// AES-256-IGE decryption; the same contract as `cmtproto_aes256_ige_encrypt`.
void cmtproto_aes256_ige_decrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length);

#ifdef __cplusplus
}
#endif

#endif

// AES-256-IGE on the CPU's AES instructions.
//
// Nonlinear substitutions use hardware AES instructions; control flow and
// memory addresses are independent of key and data. The key schedule is
// expanded once per call. CPUs without the instructions use the swift-crypto
// path instead (see `AESIGE.swift`).

#include "CMTProtoAESIGE.h"

#include <string.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#if defined(__x86_64__)
#define CMTPROTO_AES_X86 1
#include <cpuid.h>
#include <emmintrin.h>
#include <wmmintrin.h>
#elif defined(__aarch64__)
#define CMTPROTO_AES_ARM 1
#include <arm_neon.h>
#if defined(__linux__)
#include <sys/auxv.h>
#ifndef HWCAP_AES
#define HWCAP_AES (1 << 3)
#endif
#endif
#endif
#endif

#define ROUNDS 14
#define KEY_WORDS (4 * (ROUNDS + 1))
#define INLINE __attribute__((always_inline)) inline
#define NOINLINE __attribute__((noinline))

#if __has_attribute(zero_call_used_regs)
#define CLEAR_REGISTERS __attribute__((zero_call_used_regs("used")))
#else
#define CLEAR_REGISTERS
#endif

// Zeroes key material; the empty asm keeps the compiler from dropping the
// memset as a dead store.
static INLINE void wipe(void *buffer, size_t length) {
  memset(buffer, 0, length);
  __asm__ __volatile__("" : : "r"(buffer) : "memory");
}

#if defined(CMTPROTO_AES_X86) || defined(CMTPROTO_AES_ARM)

// Best-effort erasure, not a guarantee: wiping the named arrays alone misses
// compiler spills. Keep all key processing in a noinline worker (force its
// helpers inline even at -O0), then overwrite the vacated stack with a separate
// noinline call. The barrier after that call also prevents a tail call.
// 4096 bytes covers the workers' frames, including spills and the x86 red zone,
// in Clang's x86-64 / AArch64 output at -O0, -O2 and -O3. Recheck assembly when
// changing the workers or toolchain; instrumentation and other compilers can
// change the layout. This cannot erase caller-owned copies or OS-saved state.
// Where supported, zero_call_used_regs also clears the worker's used volatile
// registers (including vectors) on return; callee-saved registers must restore
// the caller's values. Older compilers still get the stack cleanup.
static NOINLINE void burn_stack(void) {
  uint8_t buffer[4096];
  wipe(buffer, sizeof buffer);
}

#if defined(CMTPROTO_AES_X86)
#define HW __attribute__((target("aes,sse2")))
typedef __m128i block;
#define bload(p) _mm_loadu_si128((const __m128i *)(const void *)(p))
#define bstore(p, v) _mm_storeu_si128((__m128i *)(void *)(p), (v))
#define bxor(a, b) _mm_xor_si128((a), (b))
#else
#define HW __attribute__((target("aes")))
typedef uint8x16_t block;
#define bload(p) vld1q_u8(p)
#define bstore(p, v) vst1q_u8((p), (v))
#define bxor(a, b) veorq_u8((a), (b))
#endif

// The S-box applied to each byte of `word`, through the AES instructions.
static INLINE HW uint32_t sub_word(uint32_t word) {
#if defined(CMTPROTO_AES_X86)
  // AESKEYGENASSIST's low lane is SubWord of the second lane.
  return (uint32_t)_mm_cvtsi128_si32(
      _mm_aeskeygenassist_si128(_mm_set1_epi32((int)word), 0));
#else
  // With four equal columns ShiftRows is the identity, so AESE with a zero
  // round key is SubBytes alone.
  uint8x16_t state = vreinterpretq_u8_u32(vdupq_n_u32(word));
  state = vaeseq_u8(state, vdupq_n_u8(0));
  return vgetq_lane_u32(vreinterpretq_u32_u8(state), 0);
#endif
}

static INLINE HW block inv_mix_columns(block value) {
#if defined(CMTPROTO_AES_X86)
  return _mm_aesimc_si128(value);
#else
  return vaesimcq_u8(value);
#endif
}

// FIPS-197 §5.2 for a 256-bit key. Words are little-endian, so byte 0 of a
// word is its low byte.
static INLINE HW void expand_encrypt_key(const uint8_t *key, block round_keys[ROUNDS + 1]) {
  uint32_t w[KEY_WORDS];
  // Keep key-bearing copies in the worker too, without a libc memcpy frame.
  __builtin_memcpy_inline(w, key, 32);
  uint32_t rcon = 1;
  for (int i = 8; i < KEY_WORDS; i++) {
    uint32_t t = w[i - 1];
    if (i % 8 == 0) {
      t = sub_word((t >> 8) | (t << 24)) ^ rcon;
      rcon <<= 1;
    } else if (i % 8 == 4) {
      t = sub_word(t);
    }
    w[i] = w[i - 8] ^ t;
  }
  __builtin_memcpy_inline(round_keys, w, sizeof w);
  wipe(w, sizeof w);
}

// The equivalent inverse cipher's schedule (FIPS-197 §5.3.5).
static INLINE HW void expand_decrypt_key(const uint8_t *key, block round_keys[ROUNDS + 1]) {
  block forward[ROUNDS + 1];
  expand_encrypt_key(key, forward);
  round_keys[0] = forward[ROUNDS];
  for (int r = 1; r < ROUNDS; r++) round_keys[r] = inv_mix_columns(forward[ROUNDS - r]);
  round_keys[ROUNDS] = forward[0];
  wipe(forward, sizeof forward);
}

// One IGE step's cipher call, E(chain ^ other) ^ mask, written so that only
// the chaining value sits on the serial path: `first` is other ^ k[0] and `last`
// is k[ROUNDS] ^ mask, both computable ahead of the previous block.
static INLINE HW block encrypt_step(
    block chain, block first, block last, const block k[ROUNDS + 1]) {
#if defined(CMTPROTO_AES_X86)
  block state = bxor(chain, first);
  for (int r = 1; r < ROUNDS; r++) state = _mm_aesenc_si128(state, k[r]);
  return _mm_aesenclast_si128(state, last);
#else
  // AESE adds its round key before SubBytes/ShiftRows, so keys run one ahead.
  block state = vaesmcq_u8(vaeseq_u8(chain, first));
  for (int r = 1; r < ROUNDS - 1; r++) state = vaesmcq_u8(vaeseq_u8(state, k[r]));
  return bxor(vaeseq_u8(state, k[ROUNDS - 1]), last);
#endif
}

// The same for D, over the equivalent inverse cipher's schedule.
static INLINE HW block decrypt_step(
    block chain, block first, block last, const block k[ROUNDS + 1]) {
#if defined(CMTPROTO_AES_X86)
  block state = bxor(chain, first);
  for (int r = 1; r < ROUNDS; r++) state = _mm_aesdec_si128(state, k[r]);
  return _mm_aesdeclast_si128(state, last);
#else
  block state = vaesimcq_u8(vaesdq_u8(chain, first));
  for (int r = 1; r < ROUNDS - 1; r++) state = vaesimcq_u8(vaesdq_u8(state, k[r]));
  return bxor(vaesdq_u8(state, k[ROUNDS - 1]), last);
#endif
}

// c_i = E(p_i ^ c_{i-1}) ^ p_{i-1}, seeded with c_{-1} = iv[0..16],
// p_{-1} = iv[16..32].
static NOINLINE CLEAR_REGISTERS HW void encrypt_worker(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  block k[ROUNDS + 1];
  expand_encrypt_key(key, k);
  block prev_cipher = bload(iv), prev_plain = bload(iv + 16);
  for (size_t offset = 0; offset < length; offset += 16) {
    block plain = bload(input + offset);
    block cipher = encrypt_step(
        prev_cipher, bxor(plain, k[0]), bxor(k[ROUNDS], prev_plain), k);
    bstore(output + offset, cipher);
    prev_cipher = cipher;
    prev_plain = plain;
  }
  wipe(k, sizeof k);
}

// p_i = D(c_i ^ p_{i-1}) ^ c_{i-1}, with the same seeds.
static NOINLINE CLEAR_REGISTERS HW void decrypt_worker(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  block k[ROUNDS + 1];
  expand_decrypt_key(key, k);
  block prev_cipher = bload(iv), prev_plain = bload(iv + 16);
  for (size_t offset = 0; offset < length; offset += 16) {
    block cipher = bload(input + offset);
    block plain = decrypt_step(
        prev_plain, bxor(cipher, k[0]), bxor(k[ROUNDS], prev_cipher), k);
    bstore(output + offset, plain);
    prev_cipher = cipher;
    prev_plain = plain;
  }
  wipe(k, sizeof k);
}

void cmtproto_aes256_ige_encrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  encrypt_worker(key, iv, input, output, length);
  burn_stack();
  __asm__ __volatile__("" : : : "memory");
}

void cmtproto_aes256_ige_decrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  decrypt_worker(key, iv, input, output, length);
  burn_stack();
  __asm__ __volatile__("" : : : "memory");
}

int cmtproto_aes_hw_available(void) {
#if defined(CMTPROTO_AES_X86)
  unsigned int eax, ebx, ecx, edx;
  if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
  return (ecx & bit_AES) != 0;
#elif defined(__APPLE__)
  // Every Apple arm64 core implements the Cryptography Extensions.
  return 1;
#elif defined(__linux__)
  return (getauxval(AT_HWCAP) & HWCAP_AES) != 0;
#else
  return 0;
#endif
}

#else  // No AES instructions this file knows how to use.

int cmtproto_aes_hw_available(void) { return 0; }

void cmtproto_aes256_ige_encrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  (void)key, (void)iv, (void)input, (void)output, (void)length, (void)wipe;
  __builtin_trap();
}

void cmtproto_aes256_ige_decrypt(
    const uint8_t *key, const uint8_t *iv, const uint8_t *input, uint8_t *output,
    size_t length) {
  (void)key, (void)iv, (void)input, (void)output, (void)length;
  __builtin_trap();
}

#endif

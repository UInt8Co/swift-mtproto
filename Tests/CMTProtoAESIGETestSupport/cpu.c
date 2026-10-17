#include "CMTProtoAESIGETestSupport.h"

#if defined(__x86_64__)
#include <cpuid.h>
#elif defined(__aarch64__) && defined(__linux__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#endif

int cmtproto_test_cpu_supports_aes(void) {
#if defined(__x86_64__)
  // CPUID is mandatory on x86-64. Query the architectural feature bit directly,
  // without sharing any code or feature macros with the production detector.
  unsigned int eax, ebx, ecx, edx;
  __cpuid(1, eax, ebx, ecx, edx);
  return (ecx & (1u << 25)) != 0;
#elif defined(__aarch64__) && defined(__APPLE__)
  return 1;
#elif defined(__aarch64__) && defined(__linux__)
  return (getauxval(AT_HWCAP) & HWCAP_AES) != 0;
#else
  return -1;
#endif
}

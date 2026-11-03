// Is ROMIO's strided read copy (ADIOI_GEN_ReadStrided memcpy, 61 of 83 INIT-MODULES samples in nsys 697697) slow
// because of first-touch page faults? Copies 520 MB in 201-double pieces (one x line of a 201^3 field, as with
// 0038's memory subarray) into: fresh malloc memory, the same memory again (pages now mapped), and fresh memory
// marked MADV_HUGEPAGE. Build: gcc -O2 -o build-tools/faultprobe harness/faultprobe.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + 1e-9 * t.tv_nsec; }

static double copy(char *dst, const char *src, size_t nbytes, size_t piece, size_t gap) {
  double t0 = now();
  size_t o = 0, d = 0;
  for (; o + piece <= nbytes; o += piece, d += piece + gap) memcpy(dst + d, src + o, piece);
  return now() - t0;
}

int main(void) {
  const size_t n = 520u << 20, piece = 201 * 8, gap = 8 * 8;  // ghost cells around each x line
  const size_t dn = n / piece * (piece + gap) + piece;
  char *src = malloc(n); memset(src, 1, n);
  char *a = malloc(dn);
  printf("fresh_malloc\t%.3f s\n", copy(a, src, n, piece, gap));
  printf("same_again\t%.3f s\n", copy(a, src, n, piece, gap));
  char *b = mmap(NULL, dn, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  int r = madvise(b, dn, MADV_HUGEPAGE);
  printf("madv_hugepage\t%.3f s\t(madvise %d)\n", copy(b, src, n, piece, gap), r);
  char *c = mmap(NULL, dn, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
  double t0 = now(); (void)c;
  printf("populate_then_copy\t%.3f s\n", copy(c, src, n, piece, gap));
  printf("(populate itself not timed separately; see mmap above, %.3f s since)\n", now() - t0);
  return 0;
}

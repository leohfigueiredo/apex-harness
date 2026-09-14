/* Apex Harness - memory bandwidth microbenchmark (pthreads)
 *
 * Purpose: establish the HARD CEILING for token generation on this machine.
 * Decoding is memory-bandwidth bound:  t/s_max ~= BW_effective / bytes_per_param
 * This program reports achievable aggregate read / triad bandwidth for a working
 * set far larger than L3 (24 MiB) - the number that actually matters for decode.
 *
 * Build: gcc -O3 -march=native -pthread -o membw membw.c
 * Usage: ./membw [GiB_per_thread] [threads]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

typedef struct {
    double *a, *b, *c;
    size_t n;
    double read_gbs, triad_gbs, copy_gbs;
} worker_t;

static void *worker(void *arg) {
    worker_t *w = (worker_t *)arg;
    size_t n = w->n;
    double *a = w->a, *b = w->b, *c = w->c;
    double bytes = (double)n * sizeof(double);

    /* --- READ: 8 independent accumulators, no per-iteration store --- */
    double best = 0;
    for (int r = 0; r < 3; r++) {
        double t0 = now_s();
        double s0=0,s1=0,s2=0,s3=0,s4=0,s5=0,s6=0,s7=0;
        for (size_t i = 0; i + 7 < n; i += 8) {
            s0 += a[i+0]; s1 += a[i+1]; s2 += a[i+2]; s3 += a[i+3];
            s4 += a[i+4]; s5 += a[i+5]; s6 += a[i+6]; s7 += a[i+7];
        }
        double acc = s0+s1+s2+s3+s4+s5+s6+s7;
        if (acc == 123456789.0) c[0] = acc;   /* defeat DCE, executed never */
        double t1 = now_s();
        double bw = bytes / 1e9 / (t1 - t0);
        if (bw > best) best = bw;
    }
    w->read_gbs = best;

    /* --- TRIAD: c = a + 3*b  (3 streams) --- */
    best = 0;
    for (int r = 0; r < 3; r++) {
        double t0 = now_s();
        for (size_t i = 0; i < n; i++) c[i] = a[i] + 3.0 * b[i];
        double t1 = now_s();
        double bw = 3.0 * bytes / 1e9 / (t1 - t0);
        if (bw > best) best = bw;
    }
    w->triad_gbs = best;

    /* --- COPY: 2 streams --- */
    best = 0;
    for (int r = 0; r < 3; r++) {
        double t0 = now_s();
        memcpy(c, a, bytes);
        double t1 = now_s();
        double bw = 2.0 * bytes / 1e9 / (t1 - t0);
        if (bw > best) best = bw;
    }
    w->copy_gbs = best;
    return NULL;
}

int main(int argc, char **argv) {
    size_t gib  = (argc > 1) ? (size_t)atoll(argv[1]) : 1;   /* GiB per thread */
    int nthr    = (argc > 2) ? atoi(argv[2]) : 0;
    if (nthr <= 0) nthr = (int)sysconf(_SC_NPROCESSORS_ONLN);

    size_t n = gib * 1024ULL * 1024ULL * 1024ULL / sizeof(double);
    n -= n % 8;

    double *a, *b, *c;
    if (posix_memalign((void **)&a, 64, n * sizeof(double)) ||
        posix_memalign((void **)&b, 64, n * sizeof(double)) ||
        posix_memalign((void **)&c, 64, n * sizeof(double))) {
        fprintf(stderr, "alloc failed\n");
        return 1;
    }
    /* Touch every page: measure DRAM traffic, not page faults. */
    for (size_t i = 0; i < n; i++) { a[i] = 1.0; b[i] = 2.0; c[i] = 0.0; }

    pthread_t *th = calloc((size_t)nthr, sizeof(*th));
    worker_t  *w  = calloc((size_t)nthr, sizeof(*w));
    for (int t = 0; t < nthr; t++) { w[t].a = a; w[t].b = b; w[t].c = c; w[t].n = n; }

    /* Every thread streams the WHOLE array. Aggregate traffic = nthr * bytes,
       which is exactly the access pattern of a real matvec where all cores
       read the same weight matrix out of RAM. */
    double t0 = now_s();
    for (int t = 0; t < nthr; t++) pthread_create(&th[t], NULL, worker, &w[t]);
    for (int t = 0; t < nthr; t++) pthread_join(th[t], NULL);
    double t1 = now_s();

    double read = 0, triad = 0, copy = 0;
    for (int t = 0; t < nthr; t++) {
        read += w[t].read_gbs; triad += w[t].triad_gbs; copy += w[t].copy_gbs;
    }

    printf("working_set_per_thread=%.2f GiB   threads=%d   wall=%.2fs\n",
           (double)n * sizeof(double) / (1024.0*1024*1024), nthr, t1 - t0);
    printf("  read   : %8.2f GB/s  (aggregate)\n", read);
    printf("  triad  : %8.2f GB/s  (aggregate)\n", triad);
    printf("  memcpy : %8.2f GB/s  (aggregate)\n", copy);

    printf("\n  DECODE CEILING (100%% BW efficiency - unreachable in practice)\n");
    const double bpp[] = {0.55, 0.30, 0.18};
    const char  *nm[]  = {"Q4_K dense 30B", "Q4_K MoE-A3B (~3B active)", "~Q2 dense 30B"};
    for (int i = 0; i < 3; i++) {
        double weights_gb = 30.0 * bpp[i];
        printf("    %-26s weights=%5.2f GB -> %6.1f t/s (read bw), %6.1f t/s (triad bw)\n",
               nm[i], weights_gb, read / weights_gb, triad / weights_gb);
    }
    printf("\n  Real-world llama.cpp decode reaches roughly 55-75%% of the read figure.\n");
    return 0;
}

#include <signal.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static uintptr_t samples[200000];
static volatile sig_atomic_t count;
static void tick(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    if (count < 200000) samples[count++] = (uintptr_t)uc->uc_mcontext->__ss.__pc;
}
static void finish(void) {
    struct itimerval stop = {0}; setitimer(ITIMER_PROF, &stop, 0);
    FILE *out = fopen(getenv("KAITO_PROFILE_OUT"), "w");
    if (!out) return;
    for (int i = 0; i < count; i++) {
        Dl_info info;
        if (dladdr((void *)samples[i], &info)) fprintf(out, "%s\t%llx\n", info.dli_fname, (unsigned long long)(samples[i] - (uintptr_t)info.dli_fbase));
    }
    fclose(out);
}
__attribute__((constructor)) static void start(void) {
    if (!getenv("KAITO_PROFILE_OUT")) return;
    struct sigaction action = {0}; action.sa_sigaction = tick; action.sa_flags = SA_SIGINFO; sigemptyset(&action.sa_mask); sigaction(SIGPROF, &action, 0);
    atexit(finish);
    struct itimerval timer = {{0, 1000}, {0, 1000}}; setitimer(ITIMER_PROF, &timer, 0);
}

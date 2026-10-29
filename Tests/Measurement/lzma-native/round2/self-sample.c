// 外部 profiler の task port が使えない環境用。Kaito 自身の main stack だけを採取する。
#include <signal.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <time.h>
#include <string.h>
#define CAPACITY 32768
#define DEPTH 24
typedef struct {unsigned count; uintptr_t pcs[DEPTH];} Sample;
static Sample samples[CAPACITY];
static _Atomic unsigned count, other;
static uintptr_t low,high;
static char *output;
static pthread_t main_thread,sampling_thread;
static _Atomic int running;
static uintptr_t clean(uintptr_t p) {return p&0x0000ffffffffffffULL;}
static void collect(int signal,siginfo_t *info,void *raw) {
#if defined(__aarch64__)
    ucontext_t *u=raw;
    uintptr_t sp=arm_thread_state64_get_sp(u->uc_mcontext->__ss);
    if(sp<low||sp>=high) {atomic_fetch_add_explicit(&other,1,memory_order_relaxed);return;}
    unsigned i=atomic_fetch_add_explicit(&count,1,memory_order_relaxed);
    if(i>=CAPACITY)return;
    Sample *s=&samples[i];s->count=0;
    s->pcs[s->count++]=arm_thread_state64_get_pc(u->uc_mcontext->__ss);
    s->pcs[s->count++]=arm_thread_state64_get_lr(u->uc_mcontext->__ss);
    uintptr_t fp=arm_thread_state64_get_fp(u->uc_mcontext->__ss);
    // active stack 内の整列した frame だけを読み、単調に上がらなければ止める。
    while(s->count<DEPTH&&fp>=sp&&fp<=high-16&&(fp&15)==0) {
        const uintptr_t *f=(const uintptr_t *)fp;
        s->pcs[s->count++]=clean(f[1]);
        uintptr_t next=clean(f[0]);if(next<=fp)break;fp=next;
    }
#endif
}
static void *ticker(void *unused) {
    uint32_t random=0x9247b153;
    while(atomic_load_explicit(&running,memory_order_relaxed)) {
        random^=random<<13;random^=random>>17;random^=random<<5;
        struct timespec delay={0,(300+(random%1401))*1000};nanosleep(&delay,0);
        if(atomic_load_explicit(&running,memory_order_relaxed))pthread_kill(main_thread,SIGPROF);
    }
    return 0;
}
static void finish(void) {
    atomic_store(&running,0);pthread_join(sampling_thread,0);
    sigset_t blocked;sigemptyset(&blocked);sigaddset(&blocked,SIGPROF);pthread_sigmask(SIG_BLOCK,&blocked,0);
    unsigned n=atomic_load(&count);if(n>CAPACITY)n=CAPACITY;
    FILE *f=fopen(output,"w");if(!f)return;
    unsigned main_index=0;
    for(unsigned i=0;i<_dyld_image_count();++i)
        if(_dyld_get_image_header(i)->filetype==MH_EXECUTE) {main_index=i;break;}
    fprintf(f,"M\t%p\t%llx\t%u\t%u\n",_dyld_get_image_header(main_index),(unsigned long long)_dyld_get_image_vmaddr_slide(main_index),n,atomic_load(&other));
    for(unsigned i=0;i<n;++i) {
        fprintf(f,"S");for(unsigned j=0;j<samples[i].count;++j)fprintf(f,"\t%llx",(unsigned long long)samples[i].pcs[j]);fputc('\n',f);
    }
    // symbol lookup は signal handler の外で行う。外部 binary の code は読まない。
    for(unsigned i=0;i<n;++i)for(unsigned j=0;j<samples[i].count;++j) {
        uintptr_t a=samples[i].pcs[j];Dl_info d={0};
        if(dladdr((void *)a,&d))fprintf(f,"D\t%llx\t%s\t%s\n",(unsigned long long)a,d.dli_fname?d.dli_fname:"",d.dli_sname?d.dli_sname:"");
    }
    fclose(f);
}
__attribute__((constructor))static void start(void) {
    const char *path=getenv("KK_PROFILE_OUT");if(!path)return;output=strdup(path);
    high=(uintptr_t)pthread_get_stackaddr_np(pthread_self());low=high-pthread_get_stacksize_np(pthread_self());
    struct sigaction action={0};action.sa_sigaction=collect;action.sa_flags=SA_SIGINFO|SA_RESTART;sigemptyset(&action.sa_mask);
    if(sigaction(SIGPROF,&action,0))return;
    // 周期的な output 窓との位相固定を避け、main thread へ jitter 付きで送る。
    main_thread=pthread_self();atomic_store(&running,1);
    if(pthread_create(&sampling_thread,0,ticker,0))return;
    atexit(finish);
}

// 子を reap する前に OS の実測カウンタを読み、wait4 の最大 RSS と併記する。
#include <libproc.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static uint64_t ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
int main(int argc,char **argv) {
    if(argc<3) return 2;
    uint64_t start=ns(); pid_t p=fork();
    if(p<0) return 3;
    if(p==0) { execvp(argv[2],argv+2); _exit(127); }
    siginfo_t signal={0};
    if(waitid(P_PID,p,&signal,WEXITED|WNOWAIT)) return 4;
    uint64_t end=ns(); struct rusage_info_v6 ri={0}; errno=0;
    int result=proc_pid_rusage(p,RUSAGE_INFO_V6,(rusage_info_t *)&ri), error=errno;
    int status=0; struct rusage ru={0};
    if(wait4(p,&status,0,&ru)!=p) return 5;
    int code=WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);
    FILE *f=fopen(argv[1],"w"); if(!f) return 6;
    fprintf(f,"{\"pid\":%d,\"exit\":%d,\"wall_ns\":%llu,\"rusage_result\":%d,\"rusage_errno\":%d,\"instructions\":%llu,\"cycles\":%llu,\"peak_rss_bytes\":%ld,\"user_seconds\":%.6f,\"system_seconds\":%.6f}\n",p,code,(unsigned long long)(end-start),result,error,(unsigned long long)ri.ri_instructions,(unsigned long long)ri.ri_cycles,ru.ru_maxrss,ru.ru_utime.tv_sec+ru.ru_utime.tv_usec/1e6,ru.ru_stime.tv_sec+ru.ru_stime.tv_usec/1e6);
    fclose(f); return code;
}

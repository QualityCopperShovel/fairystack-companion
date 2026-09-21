#define _GNU_SOURCE
#include "CommandRunner.h"
#include <spawn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#include <stdio.h>
#define LIMIT 131072
struct fs_command { atomic_int cancelled; pthread_mutex_t lock; char output[LIMIT]; size_t count; };
fs_command *fs_command_create(void) { fs_command *j=calloc(1,sizeof(*j)); if(j) pthread_mutex_init(&j->lock,0); return j; }
void fs_command_cancel(fs_command *j) { atomic_store(&j->cancelled,1); }
void fs_command_destroy(fs_command *j) { if(j){pthread_mutex_destroy(&j->lock);free(j);} }
size_t fs_command_output(fs_command *j,char *buffer,size_t size) { pthread_mutex_lock(&j->lock); size_t n=j->count<size?j->count:size; memcpy(buffer,j->output,n);pthread_mutex_unlock(&j->lock);return n; }
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void append(fs_command*j,char*b,size_t n){pthread_mutex_lock(&j->lock);size_t available=LIMIT-j->count;if(n>available)n=available;memcpy(j->output+j->count,b,n);j->count+=n;pthread_mutex_unlock(&j->lock);}
int fs_command_run(fs_command*j,const char*command,const char*directory,double seconds){
 if(!j||!command||!directory||seconds<=0||seconds>1800)return -1;
 if(atomic_load(&j->cancelled))return -2;
 int p[2];if(pipe(p))return -1;
 fcntl(p[0],F_SETFL,O_NONBLOCK);fcntl(p[0],F_SETFD,FD_CLOEXEC);fcntl(p[1],F_SETFD,FD_CLOEXEC);
 posix_spawn_file_actions_t actions;posix_spawnattr_t attr;
 posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attr);
 posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETPGROUP);posix_spawnattr_setpgroup(&attr,0);
 int err=posix_spawn_file_actions_addchdir_np(&actions,directory);
 posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
 posix_spawn_file_actions_adddup2(&actions,p[1],STDOUT_FILENO);posix_spawn_file_actions_adddup2(&actions,p[1],STDERR_FILENO);
 posix_spawn_file_actions_addclose(&actions,p[0]);posix_spawn_file_actions_addclose(&actions,p[1]);
 char *args[]={"/bin/sh","-c",(char*)command,NULL};
 /* Never forward server credentials or the helper's inherited environment. */
 char home[4096],user[512],tmp[4096];
 snprintf(home,sizeof(home),"HOME=%s",getenv("HOME")?getenv("HOME"):"/");
 snprintf(user,sizeof(user),"USER=%s",getenv("USER")?getenv("USER"):"");
 snprintf(tmp,sizeof(tmp),"TMPDIR=%s",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp");
 char *env[]={"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin","LANG=en_US.UTF-8",home,user,tmp,NULL};
 pid_t pid=0;if(!err)err=posix_spawn(&pid,"/bin/sh",&actions,&attr,args,env);
 posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);close(p[1]);
 if(err){close(p[0]);return -1;}
 double deadline=now()+seconds;
 pid_t parent=getpid(),watchdog=fork();
 if(watchdog==0){close(p[0]);for(;;){if(getppid()!=parent||now()>=deadline){kill(-pid,SIGKILL);_exit(0);}struct timespec tick={0,100000000};nanosleep(&tick,NULL);}}
 if(watchdog<0){kill(-pid,SIGKILL);waitpid(pid,NULL,0);close(p[0]);return -1;}
 int result=0,status=0;char buffer[8192];
 for(;;){
  /* Bound draining so a chatty child cannot starve cancellation. */
  for(int i=0;i<16;i++){ssize_t n=read(p[0],buffer,sizeof(buffer));if(n<=0)break;append(j,buffer,(size_t)n);}
  pid_t done=waitpid(pid,&status,WNOHANG);
  if(done==pid){result=atomic_load(&j->cancelled)?-2:now()>=deadline?-3:WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);break;}
  if(done<0&&errno!=EINTR){result=-1;break;}
  if(atomic_load(&j->cancelled)){result=-2;break;}
  if(now()>=deadline){result=-3;break;}
  struct timespec pause={0,50000000};nanosleep(&pause,NULL);
 }
 /* Own the entire group, including children left behind by an exited shell. */
 kill(-pid,SIGKILL);
 if(result<0)while(waitpid(pid,&status,0)<0&&errno==EINTR){}
 for(int i=0;i<32;i++){ssize_t n=read(p[0],buffer,sizeof(buffer));if(n<=0)break;append(j,buffer,(size_t)n);}
 kill(watchdog,SIGKILL);while(waitpid(watchdog,NULL,0)<0&&errno==EINTR){}
 close(p[0]);return result;
}

#ifndef FS_COMMAND_RUNNER_H
#define FS_COMMAND_RUNNER_H
#include <stddef.h>
typedef struct fs_command fs_command;
fs_command *fs_command_create(void);
void fs_command_cancel(fs_command *job);
void fs_command_destroy(fs_command *job);
size_t fs_command_output(fs_command *job, char *buffer, size_t length);
/* Returns exit code, or -1 launch failure, -2 cancelled, -3 deadline. */
int fs_command_run(fs_command *job, const char *command, const char *directory, double seconds);
#endif

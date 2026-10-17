#ifndef HANDREAM_IOS_GUEST_H
#define HANDREAM_IOS_GUEST_H

#include <stddef.h>

/* 1 when this binary was compiled with the iSH guest translation unit. */
int handbean_ios_guest_linked(void);

/* data_root is the fakefs data directory, the sibling of meta.db. */
int handbean_ios_guest_boot(const char *data_root);

/* Runs `/bin/sh -c command`. exit_code is the guest status shifted down. */
int handbean_ios_guest_exec(const char *command, int timeout_ms, int *exit_code, char *output,
                            size_t output_cap);

#endif

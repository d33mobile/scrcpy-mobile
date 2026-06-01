//
//  scrcpy-smoke.c — tiny NDK smoke test for libscrcpy.so (Android x86_64).
//
//  Declares scrcpy_main and calls it with `--help` so scrcpy prints its
//  usage/version text and returns, without connecting to any device. ACCEPT =
//  loads libscrcpy.so, enters scrcpy_main, prints usage/version, exits cleanly
//  (a non-zero usage/"no device" exit is fine; a crash/dlopen failure is NOT).
//
#include <stdio.h>

extern int scrcpy_main(int argc, char *argv[]);

int main(void) {
    fprintf(stderr, "[smoke] calling scrcpy_main --help\n");
    char *argv[] = { (char *) "scrcpy", (char *) "--help", NULL };
    int rc = scrcpy_main(2, argv);
    fprintf(stderr, "[smoke] scrcpy_main returned %d\n", rc);
    return 0;
}

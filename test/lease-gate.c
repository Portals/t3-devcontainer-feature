#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static volatile sig_atomic_t blocked;
static volatile sig_atomic_t released;

static void notify(int signal_number) {
    if (signal_number == SIGIO) blocked = 1;
    if (signal_number == SIGUSR1) released = 1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct sigaction action = {.sa_handler = notify};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGIO, &action, NULL) || sigaction(SIGUSR1, &action, NULL)) return 1;
    int descriptor = open(argv[1], O_CREAT | O_EXCL | O_RDWR, 0600);
    if (descriptor < 0) { perror("open lease marker"); return 1; }
    const char initial[] = "before-rollback\n";
    if (write(descriptor, initial, sizeof(initial) - 1) != sizeof(initial) - 1) return 1;
    if (fcntl(descriptor, F_SETLEASE, F_WRLCK) < 0) { perror("acquire file lease"); return 1; }
    puts("ready");
    fflush(stdout);
    while (!released) {
        if (blocked) { puts("blocked"); fflush(stdout); blocked = 0; }
        usleep(1000);
    }
    if (fcntl(descriptor, F_SETLEASE, F_UNLCK) < 0) return 1;
    return close(descriptor) != 0;
}

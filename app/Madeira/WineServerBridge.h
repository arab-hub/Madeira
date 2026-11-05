// WineServerBridge.h - Run Wine's wineserver as a thread on iOS
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Start the wineserver on a background thread.
// prefix_path: absolute path to the Wine prefix directory (e.g. app's Documents/wine)
// Returns 0 on success, -1 on failure.
int wineserver_start(const char *prefix_path);

// Check if wineserver is running
int wineserver_is_running(void);
/* 1 once the server has finished starting up (registry loaded), just before
 * its main loop: the point from which Wine may start. */
int wineserver_is_ready(void);
/* The message of the fatal error that ended the server thread in this session, NULL when
 * none; wineserver_is_running() is 0 from then on. */
const char *wineserver_fatal_message(void);

// Stop the wineserver (signals the thread to exit)
void wineserver_stop(void);

/* For the app's exit: ask the server to stop and wait up to 500 ms for it to finish, which
 * saves the registry. Never blocks longer; does nothing when the server never started or
 * has already stopped. The server does not run again in this app run. */
void wineserver_flush_for_exit(void);

// iOS socketpair bypass: inject a pre-connected client fd into the wineserver.
// Called from the app bridge after socketpair() — the wineserver event loop
// picks this up and calls create_process/create_thread on it.
void wineserver_inject_client_fd(int fd);

// Suppress os_log output from wineserver (file logging continues).
// Prevents os_log buffer contention from blocking the main thread.
extern volatile int ws_log_quiet;

#ifdef __cplusplus
}
#endif

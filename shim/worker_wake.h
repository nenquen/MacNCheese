/* A full notification pipe already contains a wakeup. Never block the game
 * thread waiting for a worker that might be busy in Xlib or have exited. */
#ifndef MACNCHEESE_WORKER_WAKE_H
#define MACNCHEESE_WORKER_WAKE_H
int macncheese_wake_pipe(int descriptors[2]);
void macncheese_wake_worker(int descriptor);
#endif

/* Kicking threads out of lost Darling waits.
 *
 * Darling sometimes loses the wakeup of a thread that sleeps in darlingserver
 * (psynch mutex and condition waits): the thread sleeps on although the lock
 * is free or the condition was signalled. A signal ends such a wait early. A
 * mutex wait then re-checks the lock and waits again while it is held; a
 * condition wait returns as a spurious wakeup (both checked in Darling with a
 * test program). Two watchdogs kick, both run by the watchdog thread in
 * net_trace.c every 100 ms:
 *  - net_trace.c: a UDP reader thread that leaves queued datagrams unread;
 *  - here: a thread waiting for a mutex (darling_fixes.c) for longer than
 *    250 ms. Such waits are futex waits now, which do not lose wakeups, so
 *    these kicks mostly serve to report where the thread waits; only after
 *    10 s does the wait fall back to Darling's own (psynch).
 *
 * The signal is SIGURG, which nothing else in the client uses. Roblox installs
 * its own handler on SIGUSR2 at startup (the one it also has on SIGTERM,
 * SIGHUP, SIGPIPE...), so the old SIGUSR2 kick reached whichever handler had
 * been installed last. It goes to the thread's Linux id with a direct Linux
 * tgkill, as exit_compat.c calls exit_group: pthread_kill with the pthread_t
 * of a thread that has exited reads freed memory, a stale id only gives ESRCH.
 *
 * When the watchdog asks, the handler also records where the thread was (RIP
 * and the frame-pointer chain within its stack); the watchdog thread names the
 * addresses with dladdr, which is not safe inside a signal handler.
 * MACNCHEESE_NO_KICK=1 turns the kicks off (stalls and long mutex waits are
 * still logged, without the location).
 *
 * A kick must only reach a thread that is still in the wait it was meant
 * for: a condition wait that is not lost returns early when a signal comes,
 * and some of Roblox's callers do not cope with that (see the untimed waits
 * in darling_fixes.c). The watchdog checks again right before each kick. */
typedef unsigned long size_t;
typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } dl_info_t;
struct darwin_sigaction_t { void (*handler)(int, void *, void *); unsigned int mask; int flags; };

extern char *getenv(const char *);
extern int sigaction(int, const struct darwin_sigaction_t *, struct darwin_sigaction_t *);
extern int pthread_key_create(unsigned long *, void (*)(void *));
extern void *pthread_getspecific(unsigned long);
extern int pthread_setspecific(unsigned long, const void *);
extern void *pthread_self(void);
extern void *pthread_get_stackaddr_np(void *);
extern size_t pthread_get_stacksize_np(void *);
extern unsigned long long mach_absolute_time(void);
extern int dladdr(const void *, dl_info_t *);
extern int snprintf(char *, size_t, const char *, ...);
extern long write(int, const void *, size_t);

static long linux_syscall3(long number, long a, long b, long c) {
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(number), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return result;
}
#define LINUX_GETPID 39
#define LINUX_GETTID 186
#define LINUX_TGKILL 234
#define LINUX_SIGURG 23
#define DARWIN_SIGURG 16
#define DARWIN_SA_SIGINFO 0x0040

static int kicks_enabled = 1;
static unsigned long tid_key;
static volatile int tid_key_ready;

/* The Linux id of the calling thread, cached in a pthread TSD slot (not a
 * __thread variable, see darling_fixes.c). */
long macncheese_thread_id(void) {
    if (!tid_key_ready)
        return linux_syscall3(LINUX_GETTID, 0, 0, 0);
    long tid = (long)pthread_getspecific(tid_key);
    if (!tid) {
        tid = linux_syscall3(LINUX_GETTID, 0, 0, 0);
        pthread_setspecific(tid_key, (void *)tid);
    }
    return tid;
}

/* ------------------------------------------------------------- location */

/* Location requests, one per thread asked. Only the watchdog thread asks and
 * reads; the kicked thread's handler fills its slot in. */
#define LOCATION_FRAMES 12
#define LOCATION_SLOTS 4
#define LOCATION_EXPIRES_NS 1000000000ULL
static struct {
    volatile long tid; /* 0 = free */
    volatile unsigned long long asked;
    void *volatile frames[LOCATION_FRAMES];
    volatile int count, ready;
} locations[LOCATION_SLOTS];

static void kick_handler(int signal, void *info, void *context) {
    (void)signal;
    (void)info;
    if (!context)
        return;
    long self = 0;
    for (int slot = 0; slot < LOCATION_SLOTS; slot++) {
        if (!locations[slot].tid || locations[slot].ready)
            continue;
        if (!self)
            self = linux_syscall3(LINUX_GETTID, 0, 0, 0);
        if (locations[slot].tid != self)
            continue;
        /* ucontext_t: uc_mcontext at word 6; mcontext: RBP word 8, RSP 9, RIP 18. */
        unsigned long long *mc = (unsigned long long *)((unsigned long long *)context)[6];
        if (!mc)
            return;
        int count = 0;
        locations[slot].frames[count++] = (void *)mc[18];
        void *thread = pthread_self();
        unsigned long top = (unsigned long)pthread_get_stackaddr_np(thread);
        unsigned long bottom = top - pthread_get_stacksize_np(thread);
        unsigned long frame = mc[8];
        if (frame < mc[9] || frame < bottom)
            frame = 0;
        /* Only frames within the used part of the stack: always mapped, so a
         * register that is not a frame pointer gives junk addresses, not a crash. */
        while (count < LOCATION_FRAMES && frame && frame + 16 <= top && !(frame & 7)) {
            void *const *pair = (void *const *)frame;
            if (!pair[1])
                break;
            locations[slot].frames[count++] = pair[1];
            unsigned long next = (unsigned long)pair[0];
            if (next <= frame)
                break;
            frame = next;
        }
        locations[slot].count = count;
        __sync_synchronize();
        locations[slot].ready = 1;
        return;
    }
}

/* Ask `tid` to record where it is at the next kick, unless it was asked
 * already. False when all slots are taken by requests under a second old. */
static int ask_location(long tid, unsigned long long now) {
    int free_slot = -1;
    for (int slot = 0; slot < LOCATION_SLOTS; slot++) {
        long owner = locations[slot].tid;
        if (owner == tid)
            return 1;
        if (free_slot < 0 && (!owner || now - locations[slot].asked > LOCATION_EXPIRES_NS))
            free_slot = slot;
    }
    if (free_slot < 0)
        return 0;
    locations[free_slot].tid = 0;
    __sync_synchronize();
    locations[free_slot].ready = 0;
    locations[free_slot].count = 0;
    locations[free_slot].asked = now;
    __sync_synchronize();
    locations[free_slot].tid = tid;
    return 1;
}

__attribute__((constructor)) static void install_kick_handler(void) {
    const char *off = getenv("MACNCHEESE_NO_KICK");
    kicks_enabled = !(off && off[0] && off[0] != '0');
    if (pthread_key_create(&tid_key, 0) == 0)
        tid_key_ready = 1;
    /* No SA_RESTART: the point is to interrupt the wait. */
    struct darwin_sigaction_t action = {kick_handler, 0, DARWIN_SA_SIGINFO};
    sigaction(DARWIN_SIGURG, &action, 0);
}

/* Kick `tid`; with `locate`, also ask it to record where it is (see
 * macncheese_located). Called by the watchdog thread only. */
int macncheese_kick(long tid, int locate) {
    if (tid <= 0)
        return -1;
    if (locate)
        ask_location(tid, mach_absolute_time());
    if (!kicks_enabled)
        return 0;
    return (int)linux_syscall3(LINUX_TGKILL, linux_syscall3(LINUX_GETPID, 0, 0, 0), tid, LINUX_SIGURG);
}

int macncheese_kicks_enabled(void) { return kicks_enabled; }

static void append(char *out, size_t size, size_t *used, const char *text) {
    while (*text && *used + 1 < size)
        out[(*used)++] = *text++;
    out[*used] = 0;
}

/* If `tid` has recorded its location, write it as "lib (symbol+offset) <
 * caller < ..." to `out`, free the request and return 1. */
int macncheese_located(long tid, char *out, size_t size) {
    int slot = 0;
    while (slot < LOCATION_SLOTS && !(locations[slot].tid == tid && locations[slot].ready))
        slot++;
    if (!size || slot == LOCATION_SLOTS)
        return 0;
    __sync_synchronize();
    size_t used = 0;
    out[0] = 0;
    for (int i = 0; i < locations[slot].count; i++) {
        char part[160];
        dl_info_t info = {0, 0, 0, 0};
        void *address = locations[slot].frames[i];
        if (dladdr(address, &info) && info.fname) {
            const char *name = info.fname;
            for (const char *c = info.fname; *c; c++)
                if (*c == '/') name = c + 1;
            if (info.sname)
                snprintf(part, sizeof part, "%s (%s+%ld)", name, info.sname,
                         (long)((char *)address - (char *)info.saddr));
            else
                snprintf(part, sizeof part, "%s+0x%lx", name,
                         (unsigned long)((char *)address - (char *)info.fbase));
        } else {
            snprintf(part, sizeof part, "%p", address);
        }
        if (i)
            append(out, size, &used, " < ");
        append(out, size, &used, part);
    }
    locations[slot].tid = 0;
    return 1;
}

/* ------------------------------------------------------- mutex waits */

#define MAX_WAITERS 256
#define WAIT_KICK_NS 250000000ULL
#define WAIT_KICK_MAX_NS 1000000000ULL
enum { NOT_REPORTED, LOCATING, REPORTED };
static struct {
    volatile long tid;
    volatile unsigned long long since, next_kick, interval, asked;
    volatile int report;
} waiters[MAX_WAITERS];
static volatile long lock_kicks, lock_waits_seen;

/* darling_fixes.c calls these around a mutex wait that has to sleep. */
int macncheese_wait_begin(void) {
    long tid = macncheese_thread_id();
    for (int i = 0; i < MAX_WAITERS; i++) {
        if (__sync_bool_compare_and_swap(&waiters[i].tid, 0, tid)) {
            unsigned long long now = mach_absolute_time();
            waiters[i].interval = WAIT_KICK_NS;
            waiters[i].next_kick = now + WAIT_KICK_NS;
            waiters[i].report = NOT_REPORTED;
            __sync_synchronize();
            waiters[i].since = now;
            return i;
        }
    }
    return -1;
}

void macncheese_wait_end(int slot) {
    if (slot < 0)
        return;
    waiters[slot].since = 0;
    __sync_synchronize();
    waiters[slot].tid = 0;
}

static void report_wait(long tid, unsigned long long waited, const char *what, const char *where) {
    char line[1400];
    int length = snprintf(line, sizeof line, "[MacNCheese Lock] thread %ld waiting %llu ms for a mutex, %s%s%s\n",
                          tid, waited / 1000000ULL, what, where ? "; at: " : "", where ? where : "");
    if (length > 0)
        write(2, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
}

/* Called by the watchdog every tick: kick waits longer than 250 ms, then
 * every 0.5 s, 1 s, 1 s ... while they last. The first waits are logged,
 * with the waiting thread's location when it records one within a second. */
void macncheese_kick_stuck_waiters(unsigned long long now) {
    for (int i = 0; i < MAX_WAITERS; i++) {
        long tid = waiters[i].tid;
        unsigned long long since = waiters[i].since;
        if (!tid || !since || now < since)
            continue;
        if (waiters[i].report == LOCATING) {
            char where[1200];
            if (macncheese_located(tid, where, sizeof where)) {
                waiters[i].report = REPORTED;
                report_wait(tid, now - since, "kicked", where);
            } else if (now - waiters[i].asked > LOCATION_EXPIRES_NS) {
                waiters[i].report = REPORTED;
                report_wait(tid, now - since, "kicked", "(not recorded)");
            }
        }
        if (now < waiters[i].next_kick)
            continue;
        if (waiters[i].tid != tid || waiters[i].since != since)
            continue; /* the wait ended during the report above */
        if (waiters[i].report == NOT_REPORTED) {
            long seen = __sync_add_and_fetch(&lock_waits_seen, 1);
            int log = seen <= 20 || seen % 100 == 0;
            if (log && !kicks_enabled)
                report_wait(tid, now - since, "not kicked (MACNCHEESE_NO_KICK)", 0);
            waiters[i].report = log && kicks_enabled ? LOCATING : REPORTED;
            waiters[i].asked = now;
        }
        unsigned long long interval = waiters[i].interval * 2;
        waiters[i].interval = interval > WAIT_KICK_MAX_NS ? WAIT_KICK_MAX_NS : interval;
        waiters[i].next_kick = now + waiters[i].interval;
        if (!kicks_enabled)
            continue;
        if (waiters[i].tid != tid || waiters[i].since != since)
            continue;
        __sync_add_and_fetch(&lock_kicks, 1);
        macncheese_kick(tid, waiters[i].report == LOCATING);
    }
}

long macncheese_lock_kick_count(void) { return lock_kicks; }

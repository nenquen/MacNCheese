/* Minimal X11 client: hides/shows the cursor with XFixes, and answers which
 * visual a window and the screen use (for picking EGL configs, gl_profile.c).
 *
 * Why: under Xwayland, XWarpPointer moves only the X server's pointer and the
 * next Wayland motion undoes it, so recentering during mouse lock bounced the
 * pointer. Xwayland emulates warps properly (locked pointer + relative motion)
 * while the X cursor is hidden with XFixes, as Wine does. Darling wraps
 * libX11 but not libXfixes, and sending the requests through Xlib internals
 * is unsafe (_XGetRequest/_XReply need Xlib's internal display lock, which
 * XLockDisplay does not take; a test hung in XUnlockDisplay). So this speaks
 * the X protocol directly on its own socket: setup, QueryExtension("XFIXES"),
 * XFixes QueryVersion, then HideCursor/ShowCursor on the root window. The
 * hide is per-client and ends automatically if this connection closes.
 *
 * The connection authenticates like libX11, with the display's
 * MIT-MAGIC-COOKIE-1 from the Xauthority file (Xorg sessions of most display
 * managers accept nothing else); without one it connects without, which
 * servers that allow the local user (Xwayland under GNOME, niri) accept. */

typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned long size_t;
struct darwin_sockaddr_un { unsigned char len, family; char path[104]; };
extern int socket(int, int, int);
extern int connect(int, const void *, socklen_t);
extern ssize_t write(int, const void *, size_t);
extern ssize_t read(int, void *, size_t);
extern int close(int);
extern int open(const char *, int, ...);
extern int fcntl(int, int, ...);
extern void *malloc(size_t);
extern void free(void *);
extern char *getenv(const char *);

#define DARWIN_O_RDONLY 0
#define DARWIN_O_CLOEXEC 0x1000000
#define DARWIN_F_SETFD 2
#define DARWIN_FD_CLOEXEC 1

static int x_socket = -1;
static unsigned char xfixes_opcode;
static unsigned int root_window;

/* The helpers take the socket: the cursor thread keeps one connection open,
 * visual queries open their own. */
static int write_all_on(int fd, const void *data, size_t length) {
    const unsigned char *bytes = data;
    while (length) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0)
            return 0;
        bytes += written;
        length -= (size_t)written;
    }
    return 1;
}

static int read_all_on(int fd, void *data, size_t length) {
    unsigned char *bytes = data;
    while (length) {
        ssize_t got = read(fd, bytes, length);
        if (got <= 0)
            return 0;
        bytes += got;
        length -= (size_t)got;
    }
    return 1;
}

/* Read the 32-byte reply to the last request, skipping events. */
static int read_reply_on(int fd, unsigned char reply[32]) {
    for (int guard = 0; guard < 256; guard++) {
        if (!read_all_on(fd, reply, 32))
            return 0;
        if (reply[0] == 0)
            return 0; /* X error */
        if (reply[0] == 1) {
            unsigned int extra = *(unsigned int *)(reply + 4) * 4;
            unsigned char skip[256];
            while (extra) {
                size_t chunk = extra < sizeof skip ? extra : sizeof skip;
                if (!read_all_on(fd, skip, chunk))
                    return 0;
                extra -= (unsigned int)chunk;
            }
            return 1;
        }
    }
    return 0;
}

static int display_number(void) {
    const char *display = getenv("DISPLAY");
    int number = 0;
    if (!display)
        return 0;
    while (*display && *display != ':')
        display++;
    if (*display == ':')
        display++;
    while (*display >= '0' && *display <= '9')
        number = number * 10 + (*display++ - '0');
    return number;
}

static int connect_display_on(int *out) {
    struct darwin_sockaddr_un address = {0};
    int number = display_number();
    /* Darling's /tmp is private; the host's X socket is under SystemRoot. */
    const char prefix[] = "/Volumes/SystemRoot/tmp/.X11-unix/X";
    int length = 0;
    while (prefix[length]) {
        address.path[length] = prefix[length];
        length++;
    }
    char digits[12];
    int count = 0;
    do {
        digits[count++] = (char)('0' + number % 10);
        number /= 10;
    } while (number && count < 11);
    while (count)
        address.path[length++] = digits[--count];
    address.family = 1; /* AF_UNIX */
    address.len = (unsigned char)(2 + length + 1);
    int fd = socket(1, 1 /* SOCK_STREAM */, 0);
    if (fd < 0)
        return 0;
    /* A child process that inherited the cursor connection would keep the
     * cursor hidden after the game exits. */
    fcntl(fd, DARWIN_F_SETFD, DARWIN_FD_CLOEXEC);
    if (connect(fd, &address, sizeof address) != 0) {
        close(fd);
        return 0;
    }
    *out = fd;
    return 1;
}

/* ------------------------------------------------------ authorization */

#define COOKIE_NAME "MIT-MAGIC-COOKIE-1"
#define COOKIE_NAME_LENGTH 18
#define COOKIE_LENGTH 16
#define FAMILY_LOCAL 256
#define FAMILY_WILD 65535

static volatile int cookie_state; /* 0: not looked up yet, 1: found, -1: none */
static unsigned char cookie[COOKIE_LENGTH];

static int same_text(const unsigned char *field, unsigned int length, const char *text) {
    unsigned int i = 0;
    for (; i < length && text[i]; i++)
        if (field[i] != (unsigned char)text[i])
            return 0;
    return i == length && !text[i];
}

static unsigned int big_endian16(const unsigned char *bytes) { return (unsigned int)bytes[0] << 8 | bytes[1]; }

/* The best MIT-MAGIC-COOKIE-1 in an Xauthority file for display `number`
 * on `host`: entries are a big-endian 16-bit family, then address, display
 * number, name and data, each a big-endian 16-bit length and the bytes. As
 * in libX11, a local entry for this host is used, or a wildcard one; a local
 * entry for another host name (the name changed since login) comes last. */
static int best_cookie(const unsigned char *file, unsigned long size, const char *number, const char *host,
                       unsigned char out[COOKIE_LENGTH]) {
    int best = 0;
    unsigned long at = 0;
    while (at + 2 <= size) {
        unsigned int family = big_endian16(file + at);
        at += 2;
        const unsigned char *field[4];
        unsigned int length[4];
        for (int i = 0; i < 4; i++) {
            if (at + 2 > size)
                return best;
            length[i] = big_endian16(file + at);
            at += 2;
            if (at + length[i] > size)
                return best;
            field[i] = file + at;
            at += length[i];
        }
        /* field: 0 address, 1 display number, 2 name, 3 data */
        if (!same_text(field[2], length[2], COOKIE_NAME) || length[3] != COOKIE_LENGTH ||
            (length[1] && !same_text(field[1], length[1], number)))
            continue;
        int score = family == FAMILY_LOCAL ? (host[0] && same_text(field[0], length[0], host) ? 3 : 1)
                  : family == FAMILY_WILD ? 2 : 0;
        if (score > best) {
            best = score;
            for (int i = 0; i < COOKIE_LENGTH; i++)
                out[i] = field[3][i];
        }
    }
    return best;
}

/* The host's name as libX11 in this process sees it (Linux uname). */
static void host_name(char out[65]) {
    char names[6 * 65];
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(63L /* Linux uname */), "D"(names) : "rcx", "r11", "memory");
    out[0] = 0;
    if (result == 0)
        for (int i = 0; i < 65; i++)
            if (!(out[i] = names[65 + i])) /* nodename */
                break;
    out[64] = 0;
}

/* Reads up to 64 KB of `path` (a path of the host when `host_path`: it is
 * reached through /Volumes/SystemRoot) into a malloc'ed buffer. */
static unsigned char *read_file(const char *path, const char *suffix, int host_path, unsigned long *size) {
    char full[1100];
    unsigned long used = 0;
    const char *parts[3] = {host_path ? "/Volumes/SystemRoot" : "", path, suffix};
    if (host_path) {
        const char *prefix = "/Volumes/SystemRoot/";
        int already = 1;
        for (int i = 0; prefix[i]; i++)
            if (path[i] != prefix[i]) { already = 0; break; }
        if (already)
            parts[0] = "";
    }
    for (int part = 0; part < 3; part++)
        for (const char *c = parts[part]; *c; c++) {
            if (used + 1 >= sizeof full)
                return 0;
            full[used++] = *c;
        }
    full[used] = 0;
    int fd = open(full, DARWIN_O_RDONLY | DARWIN_O_CLOEXEC);
    if (fd < 0)
        return 0;
    unsigned char *data = malloc(1 << 16);
    unsigned long total = 0;
    ssize_t got;
    while (data && total < (1 << 16) && (got = read(fd, data + total, (1 << 16) - total)) > 0)
        total += (unsigned long)got;
    close(fd);
    *size = total;
    return data;
}

/* The display's cookie, looked up once: $XAUTHORITY (a host path) or else
 * ~/.Xauthority, as libX11 does; inside Darling HOME is the prefix's
 * /Users/<name>, so both the host's and the prefix's copy are tried. */
static int display_cookie(unsigned char out[COOKIE_LENGTH]) {
    if (cookie_state == 0) {
        char number[12], host[65];
        int value = display_number(), count = 0;
        char digits[12];
        do {
            digits[count++] = (char)('0' + value % 10);
            value /= 10;
        } while (value && count < 11);
        for (int i = 0; i < count; i++)
            number[i] = digits[count - 1 - i];
        number[count] = 0;
        host_name(host);
        const char *authority = getenv("XAUTHORITY"), *home = getenv("HOME");
        struct { const char *path, *suffix; int host_path; } files[3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
        if (authority && authority[0] == '/')
            files[0].path = authority, files[0].suffix = "", files[0].host_path = 1;
        else if (home && home[0] == '/') {
            files[0].path = home, files[0].suffix = "/.Xauthority", files[0].host_path = 1;
            files[1].path = home, files[1].suffix = "/.Xauthority", files[1].host_path = 0;
        }
        unsigned char found[COOKIE_LENGTH];
        int state = -1;
        for (int i = 0; i < 3 && files[i].path && state < 0; i++) {
            unsigned long size = 0;
            unsigned char *data = read_file(files[i].path, files[i].suffix, files[i].host_path, &size);
            if (data && best_cookie(data, size, number, host, found)) {
                for (int j = 0; j < COOKIE_LENGTH; j++)
                    cookie[j] = found[j];
                state = 1;
            }
            free(data);
        }
        __sync_synchronize();
        cookie_state = state;
    }
    if (cookie_state < 0)
        return 0;
    for (int i = 0; i < COOKIE_LENGTH; i++)
        out[i] = cookie[i];
    return 1;
}

/* Connection setup; returns the first screen's root window and visual. */
static int setup_on(int fd, unsigned int *root, unsigned int *visual) {
    /* 'l' = little endian, protocol 11.0, then the authorization name and
     * data (lengths at 6 and 8), each padded to four bytes. */
    unsigned char request[12 + 20 + COOKIE_LENGTH] = {'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    unsigned long request_length = 12;
    unsigned char key[COOKIE_LENGTH];
    if (display_cookie(key)) {
        request[6] = COOKIE_NAME_LENGTH;
        request[8] = COOKIE_LENGTH;
        for (int i = 0; i < COOKIE_NAME_LENGTH; i++)
            request[12 + i] = (unsigned char)COOKIE_NAME[i];
        for (int i = 0; i < COOKIE_LENGTH; i++)
            request[32 + i] = key[i];
        request_length = sizeof request;
    }
    unsigned char header[8];
    if (!write_all_on(fd, request, request_length) || !read_all_on(fd, header, sizeof header) ||
        header[0] != 1)
        return 0;
    unsigned int body_length = *(unsigned short *)(header + 6) * 4u;
    /* Not static: the cursor thread and a visual query can set up at once. */
    unsigned char *body = malloc(body_length ? body_length : 1);
    if (!body || !read_all_on(fd, body, body_length)) {
        free(body);
        return 0;
    }
    int ok = 0;
    unsigned int vendor_length = body_length >= 32 ? *(unsigned short *)(body + 16) : 0;
    unsigned int formats = body_length >= 32 ? body[21] : 0;
    unsigned int screen = 32 + ((vendor_length + 3) & ~3u) + 8 * formats;
    if (body_length >= 32 && screen + 36 <= body_length) {
        *root = *(unsigned int *)(body + screen);
        if (visual)
            *visual = *(unsigned int *)(body + screen + 32);
        ok = 1;
    }
    free(body);
    return ok;
}

static int query_xfixes(void) {
    unsigned char request[16] = {98 /* QueryExtension */, 0, 4, 0, 6, 0, 0, 0,
                                 'X', 'F', 'I', 'X', 'E', 'S', 0, 0};
    unsigned char reply[32];
    if (!write_all_on(x_socket, request, sizeof request) || !read_reply_on(x_socket, reply) || !reply[8])
        return 0;
    xfixes_opcode = reply[9];
    unsigned char version[12] = {xfixes_opcode, 0 /* QueryVersion */, 3, 0, 5, 0, 0, 0, 0, 0, 0, 0};
    return write_all_on(x_socket, version, sizeof version) && read_reply_on(x_socket, reply);
}

int macncheese_raw_xfixes_open(void) {
    if (x_socket >= 0)
        return 1;
    if (!connect_display_on(&x_socket))
        return 0;
    if (!setup_on(x_socket, &root_window, 0) || !query_xfixes()) {
        close(x_socket);
        x_socket = -1;
        return 0;
    }
    return 1;
}

int macncheese_raw_xfixes_set_hidden(int hidden) {
    if (x_socket < 0)
        return 0;
    unsigned char request[8] = {xfixes_opcode, hidden ? 29 /* HideCursor */ : 30 /* ShowCursor */,
                                2, 0};
    *(unsigned int *)(request + 4) = root_window;
    return write_all_on(x_socket, request, sizeof request);
}

/* The screen's default visual and, if `window` is not 0, that window's
 * visual (GetWindowAttributes). Opens and closes its own connection.
 * Returns 0 when the X server cannot be reached. */
int macncheese_raw_x_visuals(unsigned int window, unsigned int *root_visual, unsigned int *window_visual) {
    int fd;
    unsigned int root;
    if (!connect_display_on(&fd))
        return 0;
    int ok = setup_on(fd, &root, root_visual);
    if (ok && window && window_visual) {
        unsigned char request[8] = {3 /* GetWindowAttributes */, 0, 2, 0};
        unsigned char reply[32];
        *(unsigned int *)(request + 4) = window;
        ok = write_all_on(fd, request, sizeof request) && read_reply_on(fd, reply);
        if (ok)
            *window_visual = *(unsigned int *)(reply + 8);
    }
    close(fd);
    return ok;
}

#include "telemetry_hosts.h"
#include "shim_lock.h"
#include "worker_wake.h"
#include "graphics_context.h"
#include "x_modifier_state.h"
#include "dns_concurrency.h"
#include "cursor_selection.h"
typedef struct objc_class *Class;
typedef struct objc_object { Class isa; } *id;
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef void (*IMP)(void);

extern unsigned long long mach_absolute_time(void);
extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *str);
extern Method class_getInstanceMethod(Class cls, SEL name);
extern Method class_getClassMethod(Class cls, SEL name);
extern IMP method_getImplementation(Method m);
extern IMP method_setImplementation(Method m, IMP imp);
extern const char* method_getTypeEncoding(Method m);
extern Class object_getClass(id obj);
extern const char* object_getClassName(id obj);
extern id objc_msgSend(id self, SEL op, ...);

extern char *getenv(const char *);
extern int write(int fd, const void *buf, unsigned long count);
extern int backtrace(void** array, int size);
extern void backtrace_symbols_fd(void* const* array, int size, int fd);
extern void* dlsym(void* handle, const char* symbol);
extern long _dyld_get_image_vmaddr_slide(unsigned int image_index);

#define RTLD_NEXT ((void*)-1)
#define RTLD_DEFAULT ((void*)-2)

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static void write_str(const char* s);
static void print_hex(unsigned long long val);
static void print_num(long long val);
extern int macncheese_wayland_enabled(void);
extern int macncheese_wayland_captured(void);
extern id macncheese_wayland_display(void);
extern int macncheese_wayland_associate(unsigned int);

// A MACNCHEESE_* switch: on when set to anything but "" or "0".
static int macncheese_env_on(const char* name) {
    const char* value = getenv(name);
    return value && value[0] && !(value[0] == '0' && !value[1]);
}

// The same, read once: `*cache` starts at -1.
static int macncheese_env_cached(const char* name, volatile int* cache) {
    int value = *cache;
    if (value < 0)
        *cache = value = macncheese_env_on(name);
    return value;
}

// dlsym(RTLD_NEXT, name), looked up once per call site: Darling's dlsym
// walks every loaded image, far too slow for per-frame or per-throw paths.
#define MACNCHEESE_NEXT(type, name) ({ \
    static void* volatile macncheese_next_cache; \
    void* macncheese_next_symbol = macncheese_next_cache; \
    if (!macncheese_next_symbol) \
        macncheese_next_cache = macncheese_next_symbol = dlsym(RTLD_NEXT, name); \
    (type)macncheese_next_symbol; })

// Darling can create an IONotificationPort but currently returns an error when
// Roblox registers HID matching notifications.  Roblox then destroys the port
// and attempts a second registration with the cleared pointer, which crashes
// inside IOKit.  Report a valid empty registration: controller hot-plugging is
// unavailable, while AppKit keyboard and mouse input remain unaffected.
typedef void (*MacNCheeseIOServiceMatchingCallback)(void*, unsigned int);
extern int IOServiceAddMatchingNotification(
    void*, const char*, void*, MacNCheeseIOServiceMatchingCallback, void*, unsigned int*);
static int macncheese_IOServiceAddMatchingNotification(
    void* notification_port,
    const char* notification_type,
    void* matching,
    MacNCheeseIOServiceMatchingCallback callback,
    void* context,
    unsigned int* iterator) {
    (void)notification_port;
    (void)notification_type;
    (void)callback;
    (void)context;
    // Like the real function, consume the caller's reference to `matching`.
    extern void CFRelease(const void*);
    if (matching)
        CFRelease(matching);
    if (iterator)
        *iterator = 0;
    write_str("[MacNCheese] IOKit HID notification registered with empty iterator\n");
    return 0;
}
DYLD_INTERPOSE(macncheese_IOServiceAddMatchingNotification,
               IOServiceAddMatchingNotification);

// Rewrite invalid GLSL 1.50 array-index arithmetic and capture the first
// source the driver rejects: Roblox's normal log contains the
// compiler message and line number, but not the GLSL text that caused it.
// The fix applies to every shader; sources are kept (for the final-program
// dump) only with MACNCHEESE_TRACE_GL=1, and only for the first 8192 names.
extern void glShaderSource(unsigned int, int, const char* const*, const int*);
extern void glCompileShader(unsigned int);
extern unsigned int glCreateShader(unsigned int);
extern void glAttachShader(unsigned int, unsigned int);
extern void* malloc(unsigned long);
extern void free(void*);
typedef struct MacNCheeseFILE MacNCheeseFILE;
extern MacNCheeseFILE* fopen(const char*, const char*);
extern unsigned long fwrite(const void*, unsigned long, unsigned long, MacNCheeseFILE*);
extern int fclose(MacNCheeseFILE*);

#define MACNCHEESE_SHADER_SLOTS 8192
static char* macncheese_shader_sources[MACNCHEESE_SHADER_SLOTS];
static unsigned long macncheese_shader_source_lengths[MACNCHEESE_SHADER_SLOTS];
static unsigned int macncheese_shader_types[MACNCHEESE_SHADER_SLOTS];
static unsigned int macncheese_program_shaders[MACNCHEESE_SHADER_SLOTS][4];
static volatile int macncheese_dumped_failed_shader;
static volatile int macncheese_dumped_final_program;

static int macncheese_gl_trace_enabled(void);
static int macncheese_gl_test_ui_color(void) {
    static volatile int enabled = -1;
    return macncheese_env_cached("MACNCHEESE_GL_TEST_UI_COLOR", &enabled);
}

static unsigned int macncheese_glCreateShader(unsigned int type) {
    static unsigned int (*real_function)(unsigned int);
    if (!real_function)
        real_function = (unsigned int (*)(unsigned int))
            dlsym(RTLD_NEXT, "glCreateShader");
    unsigned int shader = real_function ? real_function(type) : 0;
    if (shader < MACNCHEESE_SHADER_SLOTS)
        macncheese_shader_types[shader] = type;
    return shader;
}
DYLD_INTERPOSE(macncheese_glCreateShader, glCreateShader);

static void macncheese_glAttachShader(unsigned int program, unsigned int shader) {
    static void (*real_function)(unsigned int, unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int))
            dlsym(RTLD_NEXT, "glAttachShader");
    if (program < MACNCHEESE_SHADER_SLOTS) {
        for (int index = 0; index < 4; index++) {
            if (!macncheese_program_shaders[program][index] ||
                macncheese_program_shaders[program][index] == shader) {
                macncheese_program_shaders[program][index] = shader;
                break;
            }
        }
    }
    if (real_function)
        real_function(program, shader);
}
DYLD_INTERPOSE(macncheese_glAttachShader, glAttachShader);

static unsigned long macncheese_cstr_length(const char* text) {
    unsigned long length = 0;
    if (text)
        while (text[length]) length++;
    return length;
}

extern char* macncheese_fix_shader_indices(char*, unsigned long*);

static void macncheese_apply_ui_color_test(char* source,
                                         unsigned long source_length) {
    if (!macncheese_gl_test_ui_color())
        return;
    static const char needle[] =
        "_entryPointOutput = VARYING1 * _676;";
    static const char replacement[] =
        "_entryPointOutput = vec4(1,0,1,1)  ;";
    const unsigned long length = sizeof(needle) - 1;
    for (unsigned long position = 0;
         position + length <= source_length; position++) {
        unsigned long index = 0;
        while (index < length && source[position + index] == needle[index])
            index++;
        if (index == length) {
            for (index = 0; index < length; index++)
                source[position + index] = replacement[index];
            write_str("[MacNCheese GL] Forced UI fragment shader color\n");
            return;
        }
    }
}

static int macncheese_source_contains(const char* source,
                                    unsigned long source_length,
                                    const char* needle) {
    unsigned long needle_length = macncheese_cstr_length(needle);
    for (unsigned long position = 0;
         position + needle_length <= source_length; position++) {
        unsigned long index = 0;
        while (index < needle_length &&
               source[position + index] == needle[index])
            index++;
        if (index == needle_length)
            return 1;
    }
    return 0;
}

static void macncheese_glShaderSource(unsigned int shader, int count,
                                    const char* const* strings,
                                    const int* lengths) {
    void (*real_function)(unsigned int, int, const char* const*, const int*) =
        MACNCHEESE_NEXT(void (*)(unsigned int, int, const char* const*, const int*), "glShaderSource");

    const char* fixed_string = 0;
    int fixed_length = 0;
    char* owned = 0;
    if (count > 0 && strings) {
        unsigned long total = 0;
        for (int index = 0; index < count; index++) {
            unsigned long part = (lengths && lengths[index] >= 0)
                ? (unsigned long)lengths[index]
                : macncheese_cstr_length(strings[index]);
            if (part > 1024UL * 1024UL - total) {
                total = 0;
                break;
            }
            total += part;
        }
        if (total) {
            char* copy = (char*)malloc(total + 1);
            if (copy) {
                unsigned long position = 0;
                for (int index = 0; index < count; index++) {
                    unsigned long part = (lengths && lengths[index] >= 0)
                        ? (unsigned long)lengths[index]
                        : macncheese_cstr_length(strings[index]);
                    for (unsigned long offset = 0; offset < part; offset++)
                        copy[position++] = strings[index][offset];
                }
                copy[position] = 0;
                copy = macncheese_fix_shader_indices(copy, &total);
                macncheese_apply_ui_color_test(copy, total);
                if (macncheese_gl_test_ui_color() && shader < MACNCHEESE_SHADER_SLOTS &&
                    macncheese_shader_types[shader] == 0x8B31U &&
                    macncheese_source_contains(copy, total,
                                             "out vec2 VARYING2;")) {
                    static const char forced_vertex[] =
                        "#version 150\n"
                        "in vec4 POSITION; in vec2 TEXCOORD0; in vec4 COLOR0;\n"
                        "out vec2 VARYING0; out vec4 VARYING1; out vec2 VARYING2;\n"
                        "void main(){ int v=gl_VertexID%3; vec2 p=(v==0)?vec2(-1,-1):(v==1)?vec2(3,-1):vec2(-1,3); gl_Position=vec4(p,0,1); VARYING0=vec2(0); VARYING1=vec4(1); VARYING2=vec2(0); }\n";
                    unsigned long forced_length = sizeof(forced_vertex) - 1;
                    char* forced = (char*)malloc(forced_length + 1);
                    if (forced) {
                        for (unsigned long index = 0; index <= forced_length;
                             index++)
                            forced[index] = forced_vertex[index];
                        free(copy);
                        copy = forced;
                        total = forced_length;
                        write_str("[MacNCheese GL] Forced UI vertex coverage\n");
                    }
                }
                fixed_string = copy;
                fixed_length = (int)total;
                if (macncheese_gl_trace_enabled() && shader < MACNCHEESE_SHADER_SLOTS) {
                    if (macncheese_shader_sources[shader])
                        free(macncheese_shader_sources[shader]);
                    macncheese_shader_sources[shader] = copy;
                    macncheese_shader_source_lengths[shader] = total;
                } else {
                    owned = copy; // GL keeps its own copy of the source
                }
            }
        }
    }
    if (real_function) {
        if (fixed_string)
            real_function(shader, 1, &fixed_string, &fixed_length);
        else
            real_function(shader, count, strings, lengths);
    }
    free(owned);
}
DYLD_INTERPOSE(macncheese_glShaderSource, glShaderSource);

static void macncheese_glCompileShader(unsigned int shader) {
    void (*real_compile)(unsigned int) =
        MACNCHEESE_NEXT(void (*)(unsigned int), "glCompileShader");
    void (*real_get_shader_iv)(unsigned int, unsigned int, int*) =
        MACNCHEESE_NEXT(void (*)(unsigned int, unsigned int, int*), "glGetShaderiv");
    if (real_compile)
        real_compile(shader);

    // A status query can wait for asynchronous driver compilation. Roblox
    // checks its own shaders; the extra query is only for source diagnostics.
    if (!macncheese_gl_trace_enabled())
        return;
    int succeeded = 1;
    if (real_get_shader_iv)
        real_get_shader_iv(shader, 0x8B81U, &succeeded); // GL_COMPILE_STATUS
    if (succeeded || macncheese_dumped_failed_shader)
        return;
    // The source as GL has it (after the fixes above).
    void (*real_get_source)(unsigned int, int, int*, char*) =
        MACNCHEESE_NEXT(void (*)(unsigned int, int, int*, char*), "glGetShaderSource");
    int size = 0;
    if (real_get_shader_iv)
        real_get_shader_iv(shader, 0x8B88U, &size); // GL_SHADER_SOURCE_LENGTH
    char* source = size > 0 && real_get_source ? (char*)malloc((unsigned long)size) : 0;
    int length = 0;
    if (source)
        real_get_source(shader, size, &length, source);
    if (source && length > 0 &&
        __sync_bool_compare_and_swap(&macncheese_dumped_failed_shader, 0, 1)) {
        MacNCheeseFILE* output = fopen(
            "/private/tmp/macncheese-first-failed-shader.glsl", "w");
        if (output) {
            fwrite(source, 1, (unsigned long)length, output);
            fclose(output);
            write_str("[MacNCheese GL] Captured first failed shader source\n");
        }
    }
    free(source);
}
DYLD_INTERPOSE(macncheese_glCompileShader, glCompileShader);

// Trace every CGL/EGL binding change with its thread. Roblox renders on a
// worker thread; EGL allows a surface to be current in only one thread, so a
// failed eglMakeCurrent there leaves the renderer without a window surface.
// Enabled with MACNCHEESE_TRACE_CGL=1; the output is bounded per function.
extern void* pthread_self(void);
extern unsigned int pthread_mach_thread_np(void*);
extern int CGLCreateContext(void*, void*, void**);
extern int CGLChoosePixelFormat(const int*, void**, int*);
extern int CGLSetCurrentContext(void*);
extern int CGLContextMakeCurrentAndAttachToWindow(void*, void*);
extern int CGLFlushDrawable(void*);
extern unsigned int eglMakeCurrent(void*, void*, void*, void*);

static int macncheese_trace_cgl_enabled(void) {
    static volatile int enabled = -1;
    return macncheese_env_cached("MACNCHEESE_TRACE_CGL", &enabled);
}

static int macncheese_trace_cgl_should_log(volatile long* counter) {
    long count = __sync_add_and_fetch(counter, 1);
    return count <= 40 || count % 1000 == 0;
}

static void macncheese_trace_cgl_prefix(const char* name, volatile long* counter) {
    write_str("[MacNCheese CGL] ");
    write_str(name);
    write_str(" #");
    print_num(*counter);
    write_str(" thread=");
    print_num(pthread_mach_thread_np(pthread_self()));
}

static void* macncheese_cgl_egl_context(void* cgl) {
    // struct _CGLContextObj: retain_count, pthread_mutex_t (64 bytes on
    // Darwin x86_64), egl_context, egl_surface.
    return cgl ? ((void**)cgl)[9] : 0;
}

static void* macncheese_cgl_egl_surface(void* cgl) {
    return cgl ? ((void**)cgl)[10] : 0;
}

static volatile long macncheese_cgl_create_count;
static int macncheese_CGLChoosePixelFormat(const int* attributes, void** result, int* count) {
    int* terminated = macncheese_copy_pixel_attributes(attributes);
    if (!terminated) {
        if (result) *result = 0;
        if (count) *count = 0;
        return attributes ? 10016 /* kCGLBadAlloc */ : 10000 /* kCGLBadAttribute */;
    }
    int error = CGLChoosePixelFormat(attributes, result, count);
    if (!error && result && *result && terminated) {
        // Darling's CGL copy omits the final zero, but its descriptor scans
        // until zero. Replace that owned allocation with the complete list.
        void** format = (void**)*result;
        free(format[1]);
        format[1] = terminated;
    } else {
        free(terminated);
    }
    return error;
}
DYLD_INTERPOSE(macncheese_CGLChoosePixelFormat, CGLChoosePixelFormat);

static int macncheese_CGLCreateContext(void* format, void* share, void** result) {
    // Darling initializes its EGL display inside this call. The EGL context
    // wrapper binds desktop GL after that initialization, on this thread.
    if (macncheese_trace_cgl_enabled() && format) {
        // struct _CGLPixelFormatObj { GLuint retain_count; CGLPixelFormatAttribute* attributes; }
        int* attributes = ((int**)format)[1];
        write_str("[MacNCheese CGL] pixel format:");
        for (int index = 0; attributes && index < 64 && attributes[index]; index++) {
            write_str(" ");
            print_num(attributes[index]);
        }
        write_str("\n");
    }
    int error = CGLCreateContext(format, share, result);
    if (macncheese_trace_cgl_enabled() &&
        macncheese_trace_cgl_should_log(&macncheese_cgl_create_count)) {
        macncheese_trace_cgl_prefix("CGLCreateContext", &macncheese_cgl_create_count);
        write_str(" share=");
        print_hex((unsigned long long)share);
        write_str(" share-egl=");
        print_hex((unsigned long long)macncheese_cgl_egl_context(share));
        write_str(" result=");
        print_hex((unsigned long long)(result ? *result : 0));
        write_str(" egl=");
        print_hex((unsigned long long)macncheese_cgl_egl_context(result ? *result : 0));
        write_str(" error=");
        print_num(error);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macncheese_CGLCreateContext, CGLCreateContext);

static volatile long macncheese_cgl_set_current_count;
static int macncheese_CGLSetCurrentContext(void* context) {
    macncheese_context_change change;
    if (!macncheese_begin_context_change(&change))
        return 10004;
    int error = CGLSetCurrentContext(context);
    error = macncheese_finish_context_change(&change, error);
    if (macncheese_trace_cgl_enabled() &&
        macncheese_trace_cgl_should_log(&macncheese_cgl_set_current_count)) {
        macncheese_trace_cgl_prefix("CGLSetCurrentContext",
                                  &macncheese_cgl_set_current_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macncheese_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)macncheese_cgl_egl_surface(context));
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macncheese_CGLSetCurrentContext, CGLSetCurrentContext);

static volatile long macncheese_cgl_attach_count;
static int macncheese_CGLContextMakeCurrentAndAttachToWindow(void* context,
                                                          void* window) {
    if (!context)
        return 10004;
    macncheese_context_change change;
    if (!macncheese_begin_context_change(&change))
        return 10004;
    change.surface_slot = &((void**)context)[10];
    change.previous_surface = *change.surface_slot;
    int error = CGLContextMakeCurrentAndAttachToWindow(context, window);
    error = macncheese_finish_context_change(&change, error);
    if (macncheese_trace_cgl_enabled() &&
        macncheese_trace_cgl_should_log(&macncheese_cgl_attach_count)) {
        macncheese_trace_cgl_prefix("CGLContextMakeCurrentAndAttachToWindow",
                                  &macncheese_cgl_attach_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macncheese_cgl_egl_context(context));
        write_str(" window=");
        print_hex((unsigned long long)window);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macncheese_CGLContextMakeCurrentAndAttachToWindow,
               CGLContextMakeCurrentAndAttachToWindow);

// Frame presentation (gl_profile.c): vsync off unless MACNCHEESE_VSYNC=1,
// and an FPS line every 5 s with MACNCHEESE_FPS_LOG=1.
extern void macncheese_frame_presenting(void* cgl_context);
static volatile long macncheese_cgl_flush_drawable_count;
static int macncheese_CGLFlushDrawable(void* context) {
    if (!context)
        return 10004;
    if (macncheese_trace_cgl_enabled() &&
        macncheese_trace_cgl_should_log(&macncheese_cgl_flush_drawable_count)) {
        macncheese_trace_cgl_prefix("CGLFlushDrawable",
                                  &macncheese_cgl_flush_drawable_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macncheese_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)macncheese_cgl_egl_surface(context));
        write_str("\n");
    }
    macncheese_frame_presenting(context);
    unsigned long serial = macncheese_egl_swap_serial();
    return macncheese_finish_cgl_swap(serial, CGLFlushDrawable(context));
}
DYLD_INTERPOSE(macncheese_CGLFlushDrawable, CGLFlushDrawable);

static volatile long macncheese_egl_make_current_count;
static unsigned int macncheese_eglMakeCurrent(void* display, void* draw,
                                            void* read, void* context) {
    unsigned int result = eglMakeCurrent(display, draw, read, context);
    macncheese_record_egl_binding(result, context);
    if (macncheese_trace_cgl_enabled() &&
        macncheese_trace_cgl_should_log(&macncheese_egl_make_current_count)) {
        macncheese_trace_cgl_prefix("eglMakeCurrent",
                                  &macncheese_egl_make_current_count);
        write_str(" display=");
        print_hex((unsigned long long)display);
        write_str(" draw=");
        print_hex((unsigned long long)draw);
        write_str(" context=");
        print_hex((unsigned long long)context);
        write_str(" result=");
        print_num(result);
        write_str(" error=");
        print_hex((unsigned int)macncheese_egl_binding_error());
        write_str("\n");
    }
    return result;
}
DYLD_INTERPOSE(macncheese_eglMakeCurrent, eglMakeCurrent);

// Count the commands that can actually produce or resolve pixels. A steady
// stream of NSOpenGLContext flushes only proves that Darling swaps the X11
// surface; it does not prove that Roblox submitted a frame to that surface.
// Keep these wrappers passive so the diagnostic cannot change GL state.
extern void glDrawArrays(unsigned int, int, int);
extern void glDrawElements(unsigned int, int, unsigned int, const void*);
extern void glDrawRangeElements(unsigned int, unsigned int, unsigned int, int,
                                unsigned int, const void*);
extern void glDrawElementsBaseVertex(unsigned int, int, unsigned int,
                                     const void*, int);
extern void glDrawArraysInstanced(unsigned int, int, int, int);
extern void glDrawElementsInstanced(unsigned int, int, unsigned int,
                                    const void*, int);
extern void glDrawElementsInstancedBaseVertex(unsigned int, int, unsigned int,
                                              const void*, int, int);
extern void glBlitFramebuffer(int, int, int, int, int, int, int, int,
                              unsigned int, unsigned int);
extern void glBindFramebuffer(unsigned int, unsigned int);
extern void glClear(unsigned int);

static volatile long macncheese_gl_draw_count;
static volatile long macncheese_gl_blit_count;
static volatile long macncheese_gl_clear_count;
static volatile long macncheese_gl_default_framebuffer_bind_count;
static void* macncheese_gl_window_surface;
static void* macncheese_gl_window_egl_context;
static void* macncheese_gl_render_egl_context;
static volatile long macncheese_gl_surface_repair_attempts;
static volatile long macncheese_gl_traced_window_draws;
static volatile long macncheese_gl_skipped_foreign_draws;
static volatile int macncheese_dumped_uniform_blocks;
static volatile int macncheese_dumped_actual_program;

static void macncheese_dump_actual_program_sources(unsigned int program) {
    if (program < 700 ||
        !__sync_bool_compare_and_swap(&macncheese_dumped_actual_program, 0, 1))
        return;
    void (*attached_shaders)(unsigned int, int, int*, unsigned int*) =
        (void (*)(unsigned int, int, int*, unsigned int*))
            dlsym(RTLD_NEXT, "glGetAttachedShaders");
    void (*shader_iv)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetShaderiv");
    void (*shader_source)(unsigned int, int, int*, char*) =
        (void (*)(unsigned int, int, int*, char*))
            dlsym(RTLD_NEXT, "glGetShaderSource");
    if (!attached_shaders || !shader_iv || !shader_source)
        return;
    unsigned int shaders[4] = {0, 0, 0, 0};
    int shader_count = 0;
    attached_shaders(program, 4, &shader_count, shaders);
    write_str("[MacNCheese GL] actual program=");
    print_num(program);
    write_str(" attached=");
    print_num(shader_count);
    write_str(" shaders=");
    for (int index = 0; index < shader_count && index < 4; index++) {
        if (index)
            write_str(",");
        print_num(shaders[index]);
        int source_length = 0;
        shader_iv(shaders[index], 0x8B88U, &source_length);
        if (source_length <= 1 || source_length > 1024 * 1024)
            continue;
        char* source = (char*)malloc((unsigned long)source_length);
        if (!source)
            continue;
        int written = 0;
        shader_source(shaders[index], source_length, &written, source);
        char path[] =
            "/Volumes/SystemRoot/tmp/macncheese-actual-program-shader-0.glsl";
        path[sizeof(path) - sizeof("0.glsl")] = (char)('0' + index);
        MacNCheeseFILE* output = fopen(path, "w");
        if (output) {
            fwrite(source, 1, (unsigned long)(written > 0 ? written : 0),
                   output);
            fclose(output);
        }
        free(source);
    }
    write_str("\n");
}

// The EGL surface repair and foreign-draw filtering below were workarounds
// for Roblox drawing into the wrong context, which restoring the context
// after CALayerContext renders fixed properly. They stay available for
// debugging with MACNCHEESE_GL_HACKS=1.
static int macncheese_gl_hacks_disabled(void) {
    static volatile int enabled = -1;
    return !macncheese_env_cached("MACNCHEESE_GL_HACKS", &enabled);
}

static void macncheese_ensure_gl_window_surface(void) {
    if (macncheese_gl_hacks_disabled())
        return;
    void* surface = macncheese_gl_window_surface;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!surface || !current_surface || current_surface(0x3059)) // EGL_DRAW
        return;

    void* (*current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    int (*make_current)(void*, void*, void*, void*) =
        (int (*)(void*, void*, void*, void*))
            dlsym(RTLD_NEXT, "eglMakeCurrent");
    unsigned int (*egl_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "eglGetError");
    if (!current_display || !current_context || !make_current)
        return;

    // Roblox switches from AppKit's initial CGL context to its own shared
    // render context. The latter owns the draws but Darling leaves it
    // surfaceless, so attach whichever live context is selecting framebuffer
    // zero rather than limiting this repair to AppKit's original context.
    void* context = current_context();
    if (!context)
        return;

    int attached = make_current(current_display(), surface, surface,
                                context);
    long attempt = __sync_add_and_fetch(&macncheese_gl_surface_repair_attempts, 1);
    if (attempt <= 5) {
        write_str("[MacNCheese GL] draw-time EGL surface repair #");
        print_num(attempt);
        write_str(" result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
}

static int macncheese_should_skip_foreign_window_command(int learn_renderer) {
    if (macncheese_gl_hacks_disabled())
        return 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    if (!current_surface || !current_context ||
        current_surface(0x3059) != macncheese_gl_window_surface)
        return 0;

    void* context = current_context();
    if (learn_renderer) {
        void (*get_integer)(unsigned int, int*) =
            (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
        int program = 0;
        if (get_integer)
            get_integer(0x8B8DU, &program); // GL_CURRENT_PROGRAM
        if (program > 0) {
            macncheese_gl_render_egl_context = context;
            if (macncheese_gl_test_ui_color() && program >= 700) {
                void (*disable)(unsigned int) =
                    (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
                void (*color_mask)(unsigned char, unsigned char,
                                   unsigned char, unsigned char) =
                    (void (*)(unsigned char, unsigned char, unsigned char,
                              unsigned char))dlsym(RTLD_NEXT, "glColorMask");
                if (disable) {
                    disable(0x0BE2U); // GL_BLEND
                    disable(0x0B71U); // GL_DEPTH_TEST
                    disable(0x0B44U); // GL_CULL_FACE
                    disable(0x0C11U); // GL_SCISSOR_TEST
                    disable(0x0B90U); // GL_STENCIL_TEST
                    disable(0x8C89U); // GL_RASTERIZER_DISCARD
                    for (unsigned int clip = 0; clip < 8; clip++)
                        disable(0x3000U + clip); // GL_CLIP_DISTANCE0..
                }
                if (color_mask)
                    color_mask(1, 1, 1, 1);
            }
        }
    }
    return macncheese_gl_render_egl_context &&
           context != macncheese_gl_render_egl_context;
}

static void macncheese_trace_window_draw(unsigned int mode, int count) {
    // Once the bounded capture is complete, avoid driver queries on every
    // later draw. Diagnostic logging must not keep synchronizing gameplay.
    if (__atomic_load_n(&macncheese_gl_traced_window_draws, __ATOMIC_RELAXED) >= 16)
        return;
    unsigned int (*get_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
    unsigned int draw_error = get_error ? get_error() : 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!current_surface || !current_surface(0x3059))
        return;

    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    if (!get_integer)
        return;
    int framebuffer = -1;
    get_integer(0x8CA6U, &framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    if (framebuffer)
        return;

    long sequence = __sync_add_and_fetch(&macncheese_gl_traced_window_draws, 1);
    if (sequence > 16)
        return;

    int program = 0;
    int vertex_array = 0;
    int active_texture = 0;
    int texture = 0;
    int viewport[4] = {0, 0, 0, 0};
    int scissor[4] = {0, 0, 0, 0};
    get_integer(0x8B8DU, &program);       // GL_CURRENT_PROGRAM
    get_integer(0x85B5U, &vertex_array);  // GL_VERTEX_ARRAY_BINDING
    get_integer(0x84E0U, &active_texture);// GL_ACTIVE_TEXTURE
    get_integer(0x0BA2U, viewport);       // GL_VIEWPORT
    get_integer(0x0C10U, scissor);        // GL_SCISSOR_BOX

    int (*uniform_location)(unsigned int, const char*) =
        (int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformLocation");
    void (*get_uniform)(unsigned int, int, int*) =
        (void (*)(unsigned int, int, int*))
            dlsym(RTLD_NEXT, "glGetUniformiv");
    void (*active_texture_fn)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glActiveTexture");
    int sampler = 0;
    if (uniform_location && get_uniform && program > 0) {
        int location = uniform_location((unsigned int)program,
                                        "DiffuseMapTexture");
        if (location >= 0)
            get_uniform((unsigned int)program, location, &sampler);
    }
    if (active_texture_fn) {
        active_texture_fn(0x84C0U + (unsigned int)sampler); // GL_TEXTURE0
        get_integer(0x8069U, &texture); // GL_TEXTURE_BINDING_2D
        active_texture_fn((unsigned int)active_texture);
    }

    unsigned int (*uniform_block_index)(unsigned int, const char*) =
        (unsigned int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformBlockIndex");
    void (*uniform_block_iv)(unsigned int, unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetActiveUniformBlockiv");
    void (*get_integer_indexed)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetIntegeri_v");
    int cb0_buffer = -1;
    int cb1_buffer = -1;
    macncheese_dump_actual_program_sources((unsigned int)program);
    if (uniform_block_index && uniform_block_iv && get_integer_indexed &&
        program > 0) {
        const char* names[2] = {"block_CB0", "block_CB1"};
        int* buffers[2] = {&cb0_buffer, &cb1_buffer};
        for (int index = 0; index < 2; index++) {
            unsigned int block = uniform_block_index((unsigned int)program,
                                                      names[index]);
            if (block != 0xFFFFFFFFU) {
                int binding = 0;
                uniform_block_iv((unsigned int)program, block, 0x8A3FU,
                                 &binding); // GL_UNIFORM_BLOCK_BINDING
                get_integer_indexed(0x8A28U, (unsigned int)binding,
                                    buffers[index]);
            }
        }
    }

    if (program >= 700 && uniform_block_iv && get_integer_indexed &&
        __sync_bool_compare_and_swap(&macncheese_dumped_uniform_blocks, 0, 1)) {
        void (*get_program)(unsigned int, unsigned int, int*) =
            (void (*)(unsigned int, unsigned int, int*))
                dlsym(RTLD_NEXT, "glGetProgramiv");
        void (*block_name)(unsigned int, unsigned int, int, int*, char*) =
            (void (*)(unsigned int, unsigned int, int, int*, char*))
                dlsym(RTLD_NEXT, "glGetActiveUniformBlockName");
        int blocks = 0;
        if (get_program)
            get_program((unsigned int)program, 0x8A36U, &blocks);
        write_str("[MacNCheese GL] uniform-blocks program=");
        print_num(program);
        write_str(" count=");
        print_num(blocks);
        write_str("\n");
        for (int block = 0; block < blocks && block < 8; block++) {
            int binding = -1;
            int size = -1;
            int buffer = -1;
            int written = 0;
            char name[128];
            name[0] = 0;
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A3FU, &binding);
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A40U, &size); // GL_UNIFORM_BLOCK_DATA_SIZE
            if (block_name)
                block_name((unsigned int)program, (unsigned int)block,
                           127, &written, name);
            name[127] = 0;
            if (binding >= 0)
                get_integer_indexed(0x8A28U, (unsigned int)binding, &buffer);
            write_str("[MacNCheese GL] uniform-block #");
            print_num(block);
            write_str(" name=");
            write_str(name);
            write_str(" binding=");
            print_num(binding);
            write_str(" buffer=");
            print_num(buffer);
            write_str(" size=");
            print_num(size);
            write_str("\n");
        }
    }

    unsigned char (*is_enabled)(unsigned int) =
        (unsigned char (*)(unsigned int))dlsym(RTLD_NEXT, "glIsEnabled");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    write_str("[MacNCheese GL] window-draw #");
    print_num(sequence);
    write_str(" mode=");
    print_hex(mode);
    write_str(" count=");
    print_num(count);
    write_str(" program=");
    print_num(program);
    write_str(" error=");
    print_hex(draw_error);
    write_str(" egl-context=");
    print_hex((unsigned long long)(current_context ? current_context() : 0));
    write_str(" vao=");
    print_num(vertex_array);
    write_str(" sampler=");
    print_num(sampler);
    write_str(" texture=");
    print_num(texture);
    write_str(" cb0=");
    print_num(cb0_buffer);
    write_str(" cb1=");
    print_num(cb1_buffer);
    write_str(" blend=");
    print_num(is_enabled ? is_enabled(0x0BE2U) : -1);
    write_str(" scissor-enabled=");
    print_num(is_enabled ? is_enabled(0x0C11U) : -1);
    write_str(" viewport=");
    print_num(viewport[0]); write_str(","); print_num(viewport[1]);
    write_str(","); print_num(viewport[2]); write_str(",");
    print_num(viewport[3]);
    write_str(" scissor=");
    print_num(scissor[0]); write_str(","); print_num(scissor[1]);
    write_str(","); print_num(scissor[2]); write_str(",");
    print_num(scissor[3]);
    write_str("\n");
}

// GL call tracing is opt-in (MACNCHEESE_TRACE_GL=1). Without it the wrappers
// below only forward: tracing costs dlsym, glGetError and several
// glGetIntegerv per draw, which in game (thousands of draws per frame) was a
// large part of the frame time.
static int macncheese_gl_trace_enabled(void) {
    static volatile int enabled = -1;
    return macncheese_env_cached("MACNCHEESE_TRACE_GL", &enabled);
}

static void macncheese_glBindFramebuffer(unsigned int target,
                                       unsigned int framebuffer) {
    static void (*real_function)(unsigned int, unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int))
            dlsym(RTLD_NEXT, "glBindFramebuffer");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(target, framebuffer);
        return;
    }
    // Binding framebuffer 0 selects the window drawable. Restore its EGL
    // surface before GL validates the following clear and draw commands.
    if (!framebuffer) {
        macncheese_ensure_gl_window_surface();
        __sync_add_and_fetch(&macncheese_gl_default_framebuffer_bind_count, 1);
    }
    if (real_function)
        real_function(target, framebuffer);
}
DYLD_INTERPOSE(macncheese_glBindFramebuffer, glBindFramebuffer);

static void macncheese_glClear(unsigned int mask) {
    static void (*real_function)(unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mask);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_clear_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(0))
        real_function(mask);
}
DYLD_INTERPOSE(macncheese_glClear, glClear);

static void macncheese_glDrawArrays(unsigned int mode, int first, int count) {
    static void (*real_function)(unsigned int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int))
            dlsym(RTLD_NEXT, "glDrawArrays");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count);
        // Keep the initial AppKit draw's error check without enabling tracing
        // on every draw. Removing this single query reproduces an early
        // NVIDIA worker abort under Darling, with both -O0 and -O2 builds.
        if (macncheese_graphics_first_draw()) {
            unsigned int (*error)(void) = MACNCHEESE_NEXT(unsigned int (*)(void), "glGetError");
            if (error) error();
        }
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, first, count);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawArrays, glDrawArrays);

static void macncheese_glDrawElements(unsigned int mode, int count,
                                    unsigned int type, const void* indices) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawElements");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawElements, glDrawElements);

static void macncheese_glDrawRangeElements(unsigned int mode, unsigned int start,
                                         unsigned int end, int count,
                                         unsigned int type,
                                         const void* indices) {
    static void (*real_function)(unsigned int, unsigned int, unsigned int, int,
                                 unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int, unsigned int, int,
                                  unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawRangeElements");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, start, end, count, type, indices);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, start, end, count, type, indices);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawRangeElements, glDrawRangeElements);

static void macncheese_glDrawElementsBaseVertex(unsigned int mode, int count,
                                              unsigned int type,
                                              const void* indices,
                                              int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsBaseVertex");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, base_vertex);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, base_vertex);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawElementsBaseVertex, glDrawElementsBaseVertex);

static void macncheese_glDrawArraysInstanced(unsigned int mode, int first,
                                           int count, int instances) {
    static void (*real_function)(unsigned int, int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int, int))
            dlsym(RTLD_NEXT, "glDrawArraysInstanced");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count, instances);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, first, count, instances);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawArraysInstanced, glDrawArraysInstanced);

static void macncheese_glDrawElementsInstanced(unsigned int mode, int count,
                                             unsigned int type,
                                             const void* indices,
                                             int instances) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsInstanced");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawElementsInstanced, glDrawElementsInstanced);

static void macncheese_glDrawElementsInstancedBaseVertex(
    unsigned int mode, int count, unsigned int type, const void* indices,
    int instances, int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int, int);
    if (!real_function)
        real_function =
            (void (*)(unsigned int, int, unsigned int, const void*, int, int))
                dlsym(RTLD_NEXT, "glDrawElementsInstancedBaseVertex");
    if (!macncheese_gl_trace_enabled() && macncheese_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances, base_vertex);
        return;
    }
    macncheese_ensure_gl_window_surface();
    __sync_add_and_fetch(&macncheese_gl_draw_count, 1);
    if (real_function &&
        !macncheese_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances, base_vertex);
    else
        __sync_add_and_fetch(&macncheese_gl_skipped_foreign_draws, 1);
    macncheese_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macncheese_glDrawElementsInstancedBaseVertex,
               glDrawElementsInstancedBaseVertex);

static void macncheese_glBlitFramebuffer(int sx0, int sy0, int sx1, int sy1,
                                       int dx0, int dy0, int dx1, int dy1,
                                       unsigned int mask,
                                       unsigned int filter) {
    static void (*real_function)(int, int, int, int, int, int, int, int,
                                 unsigned int, unsigned int);
    if (!real_function)
        real_function =
            (void (*)(int, int, int, int, int, int, int, int, unsigned int,
                      unsigned int))dlsym(RTLD_NEXT, "glBlitFramebuffer");
    __sync_add_and_fetch(&macncheese_gl_blit_count, 1);
    if (real_function)
        real_function(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}
DYLD_INTERPOSE(macncheese_glBlitFramebuffer, glBlitFramebuffer);

static void write_str(const char* s) {
    if (!s) return;
    int len = 0;
    while (s[len]) len++;
    write(2, s, len);
}

static void print_hex(unsigned long long val) {
    char buf[20];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 15; i >= 0; i--) {
        int nibble = (val >> (i * 4)) & 0xF;
        buf[2 + (15 - i)] = (nibble < 10) ? ('0' + nibble) : ('a' + nibble - 10);
    }
    buf[18] = '\0';
    write(2, buf, 18);
}

static void print_num(long long val) {
    char buf[32];
    int pos = 30;
    buf[31] = '\0';
    int neg = 0;
    if (val < 0) { neg = 1; val = -val; }
    if (val == 0) {
        buf[pos--] = '0';
    } else {
        while (val > 0) {
            buf[pos--] = '0' + (val % 10);
            val /= 10;
        }
    }
    if (neg) buf[pos--] = '-';
    write(2, &buf[pos + 1], 30 - pos);
}

static void print_backtrace(void) {
    void* frames[64];
    int n = backtrace(frames, 64);
    for (int i = 0; i < n; i++) {
        write_str("  [frame ");
        print_num(i);
        write_str("]: ");
        print_hex((unsigned long long)frames[i]);
        write_str("\n");
    }
    backtrace_symbols_fd(frames, n, 2);
}

// Trace the exact resolver requests made by Roblox. A plain getaddrinfo probe
// succeeds in Darling while Roblox reports DnsResolve, so the hints passed by
// its networking layer are relevant to the failure.
struct macncheese_addrinfo_head {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
};
//
// Preserve Darling's getaddrinfo validation and addrinfo allocation, but use
// a caller-owned BIND state for its imported res_9_query transport. The legacy
// query uses global _res storage; merely removing the old lookup lock races
// query IDs, sockets and buffers. Reentrant APIs let independent lookups run
// concurrently. A custom runtime without them keeps the protected fallback.
// Temporary EAI_AGAIN/EAI_FAIL/EAI_SYSTEM errors still get four attempts with
// direct Linux sleeps 50 ms apart; permanent errors are never retried.
extern int getaddrinfo(const char*, const char*, const void*, void**);
extern int res_9_query(const char*, int, int, unsigned char*, int);
extern int *__error(void);
extern void macncheese_sleep_us(unsigned int);
extern int macncheese_dns_resolve(const char* node, const char* service,
                                const void* hints, void** result);
static const struct macncheese_resolver_api *macncheese_resolver_functions(void) {
    static struct macncheese_resolver_api api;
    static volatile unsigned int ready, initialization_lock;
    if (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) {
        macncheese_lock(&initialization_lock);
        if (!ready) {
            api.initialize = (int (*)(void*))dlsym(RTLD_NEXT, "res_9_ninit");
            api.query = (int (*)(void*, const char*, int, int, unsigned char*, int))
                dlsym(RTLD_NEXT, "res_9_nquery");
            api.destroy = (void (*)(void*))dlsym(RTLD_NEXT, "res_9_ndestroy");
            __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
        }
        macncheese_unlock(&initialization_lock);
    }
    return &api;
}
static int macncheese_res_9_query(const char *name, int dns_class, int type,
                               unsigned char *answer, int capacity) {
    macncheese_query_function original = MACNCHEESE_NEXT(macncheese_query_function, "res_9_query");
    return macncheese_query_in_scope(original, name, dns_class, type, answer, capacity);
}
DYLD_INTERPOSE(macncheese_res_9_query, res_9_query)
// Milliseconds on the Linux CLOCK_MONOTONIC, like macncheese_sleep_us: the
// resolver work and its lock waits are what a startup stall is made of.
struct macncheese_timespec { long sec; long nsec; };
static long macncheese_millis(void) {
    struct macncheese_timespec now = {0, 0};
    long result;
    __asm__ volatile("syscall"
                     : "=a"(result)
                     : "a"(228L /* Linux clock_gettime */), "D"(1L /* MONOTONIC */), "S"(&now)
                     : "rcx", "r11", "memory");
    (void)result;
    return now.sec * 1000 + now.nsec / 1000000;
}
// One line per lookup. Emitted for every failed lookup and for any lookup
// slower than 200 ms. waited_ms is zero on the concurrent private-state path;
// it remains useful when an older runtime needs the serialized fallback.
static void macncheese_dns_trace(const char* node, const char* service,
                               const void* hints, int attempts, int status,
                               long waited_ms, long took_ms) {
    write_str("[MacNCheese DNS] node=");
    write_str(node ? node : "(null)");
    write_str(" service=");
    write_str(service ? service : "(null)");
    if (hints) {
        const struct macncheese_addrinfo_head* head =
            (const struct macncheese_addrinfo_head*)hints;
        write_str(" flags="); print_num(head->ai_flags);
        write_str(" family="); print_num(head->ai_family);
        write_str(" socktype="); print_num(head->ai_socktype);
        write_str(" protocol="); print_num(head->ai_protocol);
    } else {
        write_str(" hints=(null)");
    }
    write_str(" attempts="); print_num(attempts);
    write_str(" result="); print_num(status);
    write_str(" waited_ms="); print_num(waited_ms);
    write_str(" took_ms="); print_num(took_ms);
    write_str("\n");
}
static int ascii_strings_equal(const char* left, const char* right);
static int macncheese_getaddrinfo(const char* node, const char* service,
                                const void* hints, void** result) {
    // Preserve the existing optional-telemetry hostname policy. Regional
    // beacon timeouts were observed, but an isolated redirect comparison
    // did not eliminate the remaining leave-game rendering pause.
    if (macncheese_is_blocked_telemetry(node)) {
        if (result)
            *result = 0;
        return 8; /* EAI_NONAME */
    }
    long started = macncheese_millis();
    // DNS chosen in the launcher, for Roblox only (dns_override.c).
    int own = macncheese_dns_resolve(node, service, hints, result);
    if (own >= 0) {
        long took = macncheese_millis() - started;
        if (took > 200)
            macncheese_dns_trace(node, service, hints, 0, own, 0, took);
        return own;
    }
    int (*real_getaddrinfo)(const char*, const char*, const void*, void**) =
        MACNCHEESE_NEXT(int (*)(const char*, const char*, const void*, void**), "getaddrinfo");

    int attempts = 0;
    long waited_ms = 0;
    int status = macncheese_retry_addrinfo(real_getaddrinfo, macncheese_resolver_functions(),
        node, service, hints, result, __error(), macncheese_millis, macncheese_sleep_us,
        &attempts, &waited_ms);

    long took = macncheese_millis() - started;
    static volatile int trace = -1;
    if (status != 0 || waited_ms > 200 || took > 200 ||
        macncheese_env_cached("MACNCHEESE_TRACE_DNS", &trace)) {
        macncheese_dns_trace(node, service, hints, attempts, status, waited_ms, took);
    }
    return status;
}
DYLD_INTERPOSE(macncheese_getaddrinfo, getaddrinfo)

// Interposed functions
extern void exit(int);
extern void _exit(int);
extern void _Exit(int);
extern void abort(void);
extern void __cxa_throw(void*, void*, void(*)(void*));
extern void _ZSt9terminatev(void);
extern void objc_exception_throw(id);
extern int NSApplicationMain(int argc, const char *argv[]);

// The exception hooks run for every throw and every unwinding step (Lua
// errors in game scripts are C++ exceptions), so the switch and the real
// functions are looked up once, not with getenv and dlsym every time.
static int trace_exceptions_enabled(void) {
    static volatile int enabled = -1;
    return macncheese_env_cached("MACNCHEESE_TRACE_EXCEPTIONS", &enabled);
}

void my_cxa_throw(void* thrown_exception, void* tinfo, void (*dest)(void*)) {
    void (*real_throw)(void*, void*, void(*)(void*)) =
        MACNCHEESE_NEXT(void (*)(void*, void*, void(*)(void*)), "__cxa_throw");
    if (!trace_exceptions_enabled()) {
        if (real_throw) real_throw(thrown_exception, tinfo, dest);
        while (1);
    }
    write_str("\n[MacNCheese Hook] ========================================\n");
    write_str("[MacNCheese Hook] __cxa_throw called!\n");
    if (tinfo) {
        const char* mangled = ((const char**)tinfo)[1];
        if (mangled) {
            write_str("[MacNCheese Hook] Mangled type: ");
            write_str(mangled);
            write_str("\n");
            typedef char* (*demangle_fn)(const char*, char*, unsigned long*, int*);
            demangle_fn demangle = (demangle_fn)dlsym(RTLD_DEFAULT, "__cxa_demangle");
            if (demangle) {
                int status = 0;
                char* demangled = demangle(mangled, 0, 0, &status);
                if (demangled) {
                    write_str("[MacNCheese Hook] Demangled type: ");
                    write_str(demangled);
                    write_str("\n");
                }
            }
        }
    }
    // C++ can throw scalars and arbitrary classes, not just std::exception.
    // Never interpret an unknown exception object as a vtable or call through it.
    write_str("[MacNCheese Hook] Backtrace:\n");
    print_backtrace();
    write_str("[MacNCheese Hook] ========================================\n\n");
    if (real_throw)
        real_throw(thrown_exception, tinfo, dest);
    while (1);
}
DYLD_INTERPOSE(my_cxa_throw, __cxa_throw);

void my_objc_exception_throw(id exception) {
    void (*real_throw)(id) = MACNCHEESE_NEXT(void (*)(id), "objc_exception_throw");
    if (!trace_exceptions_enabled()) {
        if (real_throw) real_throw(exception);
        while (1);
    }
    write_str("\n[MacNCheese Hook] ========================================\n");
    write_str("[MacNCheese Hook] objc_exception_throw called!\n");
    if (exception) {
        write_str("[MacNCheese Hook] Exception class: ");
        write_str(object_getClassName(exception));
        write_str("\n");
    }
    write_str("[MacNCheese Hook] Backtrace:\n");
    print_backtrace();
    write_str("[MacNCheese Hook] ========================================\n\n");
    if (real_throw)
        real_throw(exception);
    while (1);
}
DYLD_INTERPOSE(my_objc_exception_throw, objc_exception_throw);

// Interpose _Unwind_Resume, __throw_system_error, __cxa_rethrow
extern void _Unwind_Resume(void*);
void my_Unwind_Resume(void* exc) {
    void (*real_fn)(void*) = MACNCHEESE_NEXT(void (*)(void*), "_Unwind_Resume");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn(exc);
        while (1);
    }
    write_str("\n[MacNCheese Hook] ========================================\n");
    write_str("[MacNCheese Hook] _Unwind_Resume called! exc: ");
    print_hex((unsigned long long)exc);
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[MacNCheese Hook] ========================================\n\n");
    if (real_fn) real_fn(exc);
    while (1);
}
DYLD_INTERPOSE(my_Unwind_Resume, _Unwind_Resume);

extern void _ZNSt3__120__throw_system_errorEiPKc(int, const char*);
void my_throw_system_error(int err, const char* msg) {
    void (*real_fn)(int, const char*) =
        MACNCHEESE_NEXT(void (*)(int, const char*), "_ZNSt3__120__throw_system_errorEiPKc");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn(err, msg);
        while (1);
    }
    write_str("\n[MacNCheese Hook] ========================================\n");
    write_str("[MacNCheese Hook] std::__throw_system_error called! err: ");
    print_num(err);
    write_str(", msg: ");
    write_str(msg ? msg : "(null)");
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[MacNCheese Hook] ========================================\n\n");
    if (real_fn) real_fn(err, msg);
    while (1);
}
DYLD_INTERPOSE(my_throw_system_error, _ZNSt3__120__throw_system_errorEiPKc);

extern void __cxa_rethrow(void);
void my_cxa_rethrow(void) {
    void (*real_fn)(void) = MACNCHEESE_NEXT(void (*)(void), "__cxa_rethrow");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn();
        while (1);
    }
    write_str("\n[MacNCheese Hook] ========================================\n");
    write_str("[MacNCheese Hook] __cxa_rethrow called!\nBacktrace:\n");
    print_backtrace();
    write_str("[MacNCheese Hook] ========================================\n\n");
    if (real_fn) real_fn();
    while (1);
}
DYLD_INTERPOSE(my_cxa_rethrow, __cxa_rethrow);

static id macncheese_pending_uri(void);
static int ascii_strings_equal(const char* left, const char* right);
static volatile int macncheese_protocol_string_present;
static volatile int macncheese_pending_uri_injection_logged;

static int macncheese_has_protocol_string(int argc, const char *argv[]) {
    if (!argv)
        return 0;
    for (int index = 0; index < argc; index++) {
        if (argv[index] && ascii_strings_equal(argv[index], "-protocolString"))
            return 1;
    }
    return 0;
}

static void macncheese_log_startup_argv(int argc, const char *argv[]) {
    write_str("[MacNCheese Argv] argc=");
    print_num(argc);
    write_str("\n");
    for (int index = 0; index < argc; index++) {
        write_str("[MacNCheese Argv] argv[");
        print_num(index);
        write_str("]=");
        write_str(argv && argv[index] ? argv[index] : "(null)");
        write_str("\n");
    }
    macncheese_protocol_string_present = macncheese_has_protocol_string(argc, argv);
    const char* pending = getenv("MACNCHEESE_PENDING_URI");
    write_str("[MacNCheese URL] Startup sources: -protocolString=");
    print_num(macncheese_protocol_string_present != 0);
    write_str(" MACNCHEESE_PENDING_URI=");
    print_num(pending && pending[0] ? 1 : 0);
    write_str("\n");
    if (macncheese_protocol_string_present && pending && pending[0])
        write_str("[MacNCheese URL] Both protocolString and pending URI are present; protocolString wins\n");
}

int my_NSApplicationMain(int argc, const char *argv[]) {
    write_str("\n[MacNCheese Hook] NSApplicationMain entered!\n");
    macncheese_log_startup_argv(argc, argv);
    if (macncheese_protocol_string_present) {
        write_str("[MacNCheese URL] Pending URI injection: disabled (native -protocolString present)\n");
    } else {
        write_str("[MacNCheese URL] Pending URI injection: enabled (no -protocolString)\n");
        // Capture the process-bound copy before the launcher can clear its
        // host-side pending file. The value remains opaque until it is turned
        // into the Cocoa URL object at delivery time.
        (void)macncheese_pending_uri();
    }

    void* (*open_display)(const char*) = (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    if (open_display && !macncheese_wayland_enabled()) {
        void* test_dpy = open_display(0);
        if (!test_dpy) {
            write_str("[MacNCheese] FATAL: Cannot connect to X11 display! XOpenDisplay returned NULL.\n");
            write_str("[MacNCheese] Make sure an X server or Xwayland is running.\n");
            extern void macncheese_immediate_exit(int);
            macncheese_immediate_exit(1);
        } else if (close_display) {
            close_display(test_dpy);
        }
    }
    int (*real_main)(int, const char*[]) = (int (*)(int, const char*[]))dlsym(RTLD_NEXT, "NSApplicationMain");
    int res = real_main ? real_main(argc, argv) : 0;
    write_str("\n[MacNCheese Hook] NSApplicationMain returned: ");
    print_num(res);
    write_str("\n[MacNCheese Hook] Backtrace:\n");
    print_backtrace();
    return res;
}
DYLD_INTERPOSE(my_NSApplicationMain, NSApplicationMain);

// Signal crash handler
struct darwin_sigaction {
    void (*sa_sigaction)(int, void*, void*);
    unsigned int sa_mask;
    int sa_flags;
};
extern int sigaction(int, const struct darwin_sigaction*, struct darwin_sigaction*);

typedef struct dl_info {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
extern int dladdr(const void *, Dl_info *);

static void print_addr_info(const char* prefix, void* addr) {
    write_str(prefix);
    print_hex((unsigned long long)addr);
    Dl_info dli;
    if (dladdr(addr, &dli)) {
        if (dli.dli_fname) {
            write_str(" in ");
            write_str(dli.dli_fname);
        }
        if (dli.dli_sname) {
            write_str(" (");
            write_str(dli.dli_sname);
            write_str("+");
            print_num((long long)((char*)addr - (char*)dli.dli_saddr));
            write_str(")");
        }
    }
    write_str("\n");
}

static void crash_handler(int sig, void* info, void* uap) {
    write_str("\n\n[MacNCheese FATAL CRASH] ****************************************\n");
    write_str("[MacNCheese FATAL CRASH] Signal received: ");
    print_num(sig);
    write_str("\n");
    if (info) {
        write_str("[MacNCheese FATAL CRASH] siginfo: ");
        print_hex((unsigned long long)info);
        // Darwin siginfo_t: si_code at byte 8, si_pid at 12, si_addr at 24.
        const unsigned char* si = (const unsigned char*)info;
        write_str("\n  si_code: ");
        print_num(*(const int*)(si + 8));
        write_str("\n  si_pid: ");
        print_num(*(const int*)(si + 12));
        write_str("\n  si_addr: ");
        print_hex(*(const unsigned long long*)(si + 24));
        write_str("\n");
    }
    if (uap) {
        write_str("[MacNCheese FATAL CRASH] ucontext: ");
        print_hex((unsigned long long)uap);
        write_str("\n");
        unsigned long long* p = (unsigned long long*)uap;
        write_str("  uc_mcontext ptr: ");
        print_hex(p[6]);
        write_str("\n");
        unsigned long long* mc = (unsigned long long*)p[6];
        if (mc) {
            write_str("  RAX: "); print_hex(mc[2]); write_str("\n");
            write_str("  RBX: "); print_hex(mc[3]); write_str("\n");
            write_str("  RCX: "); print_hex(mc[4]); write_str("\n");
            write_str("  RDX: "); print_hex(mc[5]); write_str("\n");
            write_str("  RDI: "); print_hex(mc[6]); write_str("\n");
            write_str("  RSI: "); print_hex(mc[7]); write_str("\n");
            write_str("  RBP: "); print_hex(mc[8]); write_str("\n");
            write_str("  RSP: "); print_hex(mc[9]); write_str("\n");
            write_str("  RIP: "); print_hex(mc[18]); write_str("\n");
            write_str("  RFLAGS: "); print_hex(mc[19]); write_str("\n");
            // Exception state before the registers: trap number, error code
            // and the faulting address.
            write_str("  trap: "); print_num(mc[0] & 0xffff);
            write_str(" err: "); print_hex(mc[0] >> 32);
            write_str(" fault address: "); print_hex(mc[1]); write_str("\n");

            print_addr_info("  Fault RIP info: ", (void*)mc[18]);
            print_addr_info("  RDI info: ", (void*)mc[6]);
            print_addr_info("  RSI info: ", (void*)mc[7]);

            // Raw stack words that look like user-space addresses, innermost
            // and outermost: a trail through code without frame pointers
            // (the host's GPU driver), where the walk below finds nothing.
            write_str("\n[MacNCheese Stack Words near RSP]:\n");
            // A stack overflow leaves RSP in the guard page: start above it.
            unsigned long long* sp = (unsigned long long*)((mc[9] + 0x1000) & ~0xfffULL);
            int shown = 0;
            for (int i = 0; i < 4096; i++) {
                unsigned long long word = sp[i];
                if (word < 0x7f0000000000ULL || word >= 0x800000000000ULL) continue;
                print_hex(word);
                write_str(++shown % 6 ? " " : "\n");
            }
            extern void* pthread_get_stackaddr_np(void*);
            extern void* pthread_self(void);
            unsigned long long* top = (unsigned long long*)pthread_get_stackaddr_np(pthread_self());
            write_str("\n[MacNCheese Stack Words near the stack top ");
            print_hex((unsigned long long)top);
            write_str("]:\n");
            shown = 0;
            if (top && (unsigned long long)top > mc[9] && (unsigned long long)top - mc[9] > 16384) {
                for (int i = 2048; i > 0; i--) {
                    unsigned long long word = top[-i];
                    if (word < 0x7f0000000000ULL || word >= 0x800000000000ULL) continue;
                    print_hex(word);
                    write_str(++shown % 6 ? " " : "\n");
                }
            }
            write_str("\n");
            write_str("\n[MacNCheese Stack Walk from RBP]:\n");
            void** fp = (void**)mc[8];
            unsigned long long low = mc[9];
            unsigned long long high = (unsigned long long)top > mc[9] ? (unsigned long long)top : mc[9] + (1ULL << 20);
            for (int i = 0; i < 30 && fp; i++) {
                // Code without frame pointers leaves other values in RBP:
                // only follow ones inside this stack, going up.
                if ((unsigned long long)fp < low || (unsigned long long)fp >= high ||
                    ((unsigned long long)fp & 7)) break;
                void* ret_addr = fp[1];
                write_str("  #"); print_num(i); write_str(" ");
                print_addr_info("", ret_addr);
                low = (unsigned long long)fp + 16;
                fp = (void**)fp[0];
            }
        }
    }
    write_str("[MacNCheese FATAL CRASH] ****************************************\n\n");
    _exit(128 + sig);
}

int my_sigaction(int sig, const struct darwin_sigaction *act, struct darwin_sigaction *oact) {
    write_str("[MacNCheese Hook] sigaction called for sig: ");
    print_num(sig);
    write_str(", new handler: ");
    print_hex(act ? (unsigned long long)act->sa_sigaction : 0);
    write_str("\n");
    int (*real_sigaction)(int, const void*, void*) =
        MACNCHEESE_NEXT(int (*)(int, const void*, void*), "sigaction");
    // Opt-in crash diagnosis only: preserve the application's handlers normally.
    static volatile int diagnose = -1;
    if (macncheese_env_cached("MACNCHEESE_DIAGNOSTIC_SIGNALS", &diagnose) && sig == 11 && act && real_sigaction) {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        return real_sigaction(sig, &debug_action, oact);
    }
    return real_sigaction ? real_sigaction(sig, act, oact) : 0;
}
DYLD_INTERPOSE(my_sigaction, sigaction);

// Swizzle NSConcreteScanner
static id (*orig_concrete_initWithString)(id self, SEL _cmd, id str) = 0;
static id hooked_concrete_initWithString(id self, SEL _cmd, id str) {
    if (!str) {
        write_str("\n[MacNCheese Hook] -[NSConcreteScanner initWithString:nil] called!\n");
    }
    return orig_concrete_initWithString(self, _cmd, str);
}

// Swizzle NSApplication run
static void (*orig_app_run)(id self, SEL _cmd) = 0;
static void macncheese_queue_pending_uri(id app);
static void hooked_app_run(id self, SEL _cmd) {
    write_str("\n[MacNCheese Hook] -[NSApplication run] entered!\n");
    // If Darling does not call finishLaunching through the swizzled entry
    // point, the main-queue turn below still runs after AppKit has started its
    // event loop and the delegate has been installed.
    macncheese_queue_pending_uri(self);
    orig_app_run(self, _cmd);
    write_str("\n[MacNCheese Hook] -[NSApplication run] returned!\n");
}

static int ascii_strings_equal(const char* left, const char* right) {
    if (!left || !right)
        return 0;
    while (*left && *right && *left == *right) {
        left++;
        right++;
    }
    return *left == 0 && *right == 0;
}

static void (*orig_app_finish_launching)(id self, SEL cmd) = 0;

// Browser protocol handoff -------------------------------------------------
//
// A direct executable launch has no LaunchServices/Apple Event envelope.  The
// launcher therefore passes the original opaque browser value in
// MACNCHEESE_PENDING_URI and leaves the pending-uri file path available as a
// fallback.  Once AppKit has finished launching, deliver it through the
// delegate's normal Cocoa URL entry point.  No URI fields are inspected or
// rebuilt here.
extern MacNCheeseFILE* fopen(const char*, const char*);
extern unsigned long fread(void*, unsigned long, unsigned long, MacNCheeseFILE*);
extern int fclose(MacNCheeseFILE*);
extern void dispatch_async(void*, void (^)(void));
extern unsigned long long dispatch_time(unsigned long long, long long);
extern void dispatch_after(unsigned long long, void*, void (^)(void));
extern struct dispatch_queue_s _dispatch_main_q;

static id macncheese_captured_delegate;
static volatile int macncheese_pending_uri_checked;
static volatile int macncheese_pending_uri_delivered;
static id macncheese_pending_uri_string;

static unsigned long macncheese_fourcc(char a, char b, char c, char d) {
    return ((unsigned long)(unsigned char)a << 24) |
           ((unsigned long)(unsigned char)b << 16) |
           ((unsigned long)(unsigned char)c << 8) |
           (unsigned long)(unsigned char)d;
}

static id macncheese_ns_string_from_bytes(const char* bytes, unsigned long length) {
    if (!bytes || !length)
        return 0;
    char* copy = (char*)malloc(length + 1);
    if (!copy)
        return 0;
    for (unsigned long index = 0; index < length; index++)
        copy[index] = bytes[index];
    copy[length] = 0;
    id string_class = (id)objc_getClass("NSString");
    id value = string_class
        ? ((id (*)(id, SEL, const char*))objc_msgSend)(
              string_class, sel_registerName("stringWithUTF8String:"), copy)
        : 0;
    free(copy);
    if (value)
        value = ((id (*)(id, SEL))objc_msgSend)(value, sel_registerName("retain"));
    return value;
}

static id macncheese_pending_uri(void) {
    if (macncheese_pending_uri_checked)
        return macncheese_pending_uri_string;
    macncheese_pending_uri_checked = 1;

    const char* value = getenv("MACNCHEESE_PENDING_URI");
    unsigned long length = value ? macncheese_cstr_length(value) : 0;
    if (value && length)
        macncheese_pending_uri_string = macncheese_ns_string_from_bytes(value, length);

    // A launch without the command-line copy can still consume the pending
    // file.  It is read through SystemRoot because Darling's /tmp and home are
    // private while the launcher cache is on the host filesystem.
    if (!macncheese_pending_uri_string) {
        const char* path = getenv("MACNCHEESE_PENDING_URI_FILE");
        MacNCheeseFILE* file = path && path[0] ? fopen(path, "rb") : 0;
        if (file) {
            unsigned long capacity = 64 * 1024;
            char* bytes = (char*)malloc(capacity);
            unsigned long count = bytes ? fread(bytes, 1, capacity, file) : 0;
            fclose(file);
            if (count)
                macncheese_pending_uri_string = macncheese_ns_string_from_bytes(bytes, count);
            free(bytes);
        }
    }

    if (macncheese_pending_uri_string) {
        write_str("[MacNCheese URL] Pending URI detected\n");
    }
    return macncheese_pending_uri_string;
}

static signed char macncheese_log_uri_selector(id delegate, const char* name) {
    SEL selector = sel_registerName(name);
    Class delegate_class = object_getClass(delegate);
    Method method = delegate_class ? class_getInstanceMethod(delegate_class, selector) : 0;
    signed char responds = ((signed char (*)(id, SEL, SEL))objc_msgSend)(
        delegate, sel_registerName("respondsToSelector:"), selector);
    write_str("[MacNCheese URL] Selector ");
    write_str(name);
    write_str(" responds=");
    print_num(responds != 0);
    write_str(" encoding=");
    const char* encoding = method ? method_getTypeEncoding(method) : 0;
    write_str(encoding ? encoding : "(unavailable)");
    if (ascii_strings_equal(name, "application:openURLs:")) {
        write_str(" expected=v32@0:8@16@24 matches=");
        print_num(ascii_strings_equal(encoding, "v32@0:8@16@24"));
    }
    write_str("\n");
    return responds;
}

static unsigned long macncheese_uri_delay_ms(void) {
    const char* value = getenv("MACNCHEESE_URI_DELAY_MS");
    if (!value || !value[0])
        return 0;
    unsigned long delay = 0;
    for (const char* digit = value; *digit; digit++) {
        if (*digit < '0' || *digit > '9' || delay > 1000) {
            write_str("[MacNCheese URL] Invalid delay; using 0 ms\n");
            return 0;
        }
        delay = delay * 10 + (unsigned long)(*digit - '0');
    }
    if (delay > 10000) {
        write_str("[MacNCheese URL] Delay exceeds 10000 ms; using 0 ms\n");
        return 0;
    }
    return delay;
}

static id macncheese_make_url_event(id url_string) {
    Class descriptor_class = objc_getClass("NSAppleEventDescriptor");
    if (!descriptor_class)
        return 0;
    SEL descriptor_with_string = sel_registerName("descriptorWithString:");
    SEL apple_event = sel_registerName(
        "appleEventWithEventClass:eventID:targetDescriptor:returnID:transactionID:");
    if (!class_getClassMethod(descriptor_class, descriptor_with_string) ||
        !class_getClassMethod(descriptor_class, apple_event))
        return 0;
    id url_descriptor = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)descriptor_class, descriptor_with_string, url_string);
    id event = ((id (*)(id, SEL, unsigned long, unsigned long, id, short, long))objc_msgSend)(
        (id)descriptor_class, apple_event,
        macncheese_fourcc('G', 'U', 'R', 'L'), // kInternetEventClass
        macncheese_fourcc('G', 'U', 'R', 'L'), // kAEGetURL
        0, -1, 0);                            // auto return ID, any transaction
    SEL set_parameter = sel_registerName("setParamDescriptor:forKeyword:");
    if (!event || !url_descriptor || !class_getInstanceMethod(descriptor_class, set_parameter))
        return 0;
    ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(
        event, set_parameter, url_descriptor, macncheese_fourcc('-', '-', '-', '-'));
    return event;
}

static void macncheese_deliver_pending_uri(id app) {
    if (macncheese_protocol_string_present) {
        if (!macncheese_pending_uri_injection_logged) {
            macncheese_pending_uri_injection_logged = 1;
            write_str("[MacNCheese URL] Pending URI injection skipped; -protocolString already supplied the URI\n");
        }
        return;
    }
    if (macncheese_pending_uri_delivered)
        return;
    id value = macncheese_pending_uri();
    if (!value)
        return;
    /* Always resolve the delegate from the live application: the captured
     * global goes stale within seconds of launch (menu web content swaps
     * delegates), and messaging the freed object is a main-queue SIGSEGV
     * inside objc_msgSend. A cached pointer that no longer matches the
     * app's delegate is never touched. */
    id delegate = 0;
    if (app)
        delegate = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("delegate"));
    if (!delegate) {
        if (macncheese_captured_delegate)
            write_str("[MacNCheese URL] Live delegate gone; stale capture not messaged\n");
        else
            write_str("[MacNCheese URL] Delegate not available yet\n");
        return;
    }
    macncheese_captured_delegate = delegate;
    write_str("[MacNCheese URL] Delegate: ");
    write_str(object_getClassName(delegate));
    write_str("\n");

    const char* open_urls_name = "application:openURLs:";
    const char* open_file_name = "application:openFile:";
    const char* handle_get_url_name = "application:handleGetURLEvent:withReplyEvent:";
    signed char has_open_urls = macncheese_log_uri_selector(delegate, open_urls_name);
    signed char has_open_file = macncheese_log_uri_selector(delegate, open_file_name);
    signed char has_get_url = macncheese_log_uri_selector(delegate, handle_get_url_name);
    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSURL"), sel_registerName("URLWithString:"), value);
    if (!url) {
        write_str("[MacNCheese URL] NSURL rejected the pending URI; trying legacy handlers\n");
    } else {
        id absolute = ((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString"));
        signed char unchanged = absolute && ((signed char (*)(id, SEL, id))objc_msgSend)(
            absolute, sel_registerName("isEqualToString:"), value);
        write_str("[MacNCheese URL] NSURL absoluteString matches pending=");
        print_num(unchanged != 0);
        write_str("\n");
    }

    const char* order = getenv("MACNCHEESE_URI_SELECTOR_ORDER");
    int apple_first = ascii_strings_equal(order, "B");
    write_str(apple_first ? "[MacNCheese URL] Selector order=B\n" :
                            "[MacNCheese URL] Selector order=A\n");
    for (int choice = 0; choice < 3; choice++) {
        int kind = apple_first ? (choice == 0 ? 2 : choice == 1 ? 0 : 1) : choice;
        if (kind == 0 && url && has_open_urls) {
        SEL open_urls = sel_registerName(open_urls_name);
        id urls = ((id (*)(id, SEL, const id*, unsigned long))objc_msgSend)(
            (id)objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), &url, 1);
        if (!urls) {
            write_str("[MacNCheese URL] Delivered failed\n");
            return;
        }
        write_str("[MacNCheese URL] Using: application:openURLs:\n");
        write_str("[MacNCheese URL] Before application:openURLs:\n");
        @try {
            // -[RobloxPlayerAppDelegate application:openURLs:] is void with
            // NSApplication* and NSArray<NSURL*>* object arguments.
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, open_urls, app, urls);
            write_str("[MacNCheese URL] After application:openURLs:\n");
            macncheese_pending_uri_delivered = 1;
            write_str("[MacNCheese URL] Delivered successfully\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[MacNCheese URL] Delivered failed\n");
        }
        return;
        }

        if (kind == 1 && has_open_file) {
        SEL open_file = sel_registerName(open_file_name);
        write_str("[MacNCheese URL] Using: application:openFile:\n");
        signed char accepted = 0;
        write_str("[MacNCheese URL] Before application:openFile:\n");
        @try {
            accepted = ((signed char (*)(id, SEL, id, id))objc_msgSend)(delegate, open_file, app, value);
            write_str("[MacNCheese URL] After application:openFile: accepted=");
            print_num(accepted != 0);
            write_str("\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[MacNCheese URL] Delivered failed\n");
            return;
        }
        if (accepted) {
            macncheese_pending_uri_delivered = 1;
            write_str("[MacNCheese URL] Delivered successfully\n");
        } else {
            write_str("[MacNCheese URL] Delivered failed\n");
        }
        return;
        }

        if (kind == 2 && has_get_url) {
        SEL handle_get_url = sel_registerName(handle_get_url_name);
        write_str("[MacNCheese URL] Using: application:handleGetURLEvent:withReplyEvent:\n");
        id event = macncheese_make_url_event(value);
        if (!event) {
            write_str("[MacNCheese URL] Delivered failed\n");
            return;
        }
        write_str("[MacNCheese URL] Before application:handleGetURLEvent:withReplyEvent:\n");
        @try {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, handle_get_url, app, event, 0);
            write_str("[MacNCheese URL] After application:handleGetURLEvent:withReplyEvent:\n");
            macncheese_pending_uri_delivered = 1;
            write_str("[MacNCheese URL] Delivered successfully\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[MacNCheese URL] Delivered failed\n");
        }
        return;
        }
    }

    write_str("[MacNCheese URL] Delivered failed\n");
}

static void macncheese_queue_pending_uri(id app) {
    if (macncheese_protocol_string_present) {
        if (!macncheese_pending_uri_injection_logged) {
            macncheese_pending_uri_injection_logged = 1;
            write_str("[MacNCheese URL] Pending URI injection skipped; -protocolString already supplied the URI\n");
        }
        return;
    }
    if (!macncheese_pending_uri())
        return;
    write_str("[MacNCheese URL] Pending URI injection running\n");
    unsigned long delay_ms = macncheese_uri_delay_ms();
    write_str("[MacNCheese URL] Queued delivery after ");
    print_num(delay_ms);
    write_str(" ms\n");
    if (delay_ms) {
        dispatch_after(dispatch_time(0, (long long)delay_ms * 1000000LL),
                       &_dispatch_main_q, ^{ macncheese_deliver_pending_uri(app); });
    } else {
        dispatch_async(&_dispatch_main_q, ^{ macncheese_deliver_pending_uri(app); });
    }
}

// Window icon: MACNCHEESE_ICON_ARGB names a file of 32-bit little-endian words
// in _NET_WM_ICON layout (width, height, ARGB pixels, repeated per size),
// written by the launcher. It is set on the Roblox X window from a separate
// X connection, so docks and window switchers show the Mac'n Cheese logo.
extern void* malloc(unsigned long);
extern void free(void*);
static unsigned long macncheese_icon_window;
static void* macncheese_set_window_icon_thread(void* unused) {
    (void)unused;
    const char* path = getenv("MACNCHEESE_ICON_ARGB");
    MacNCheeseFILE* file = path ? fopen(path, "rb") : 0;
    if (!file)
        return 0;
    extern unsigned long fread(void*, unsigned long, unsigned long, MacNCheeseFILE*);
    unsigned int* words = (unsigned int*)malloc(1 << 22);
    unsigned long count = words ? fread(words, 4, (1 << 22) / 4, file) : 0;
    fclose(file);
    if (!count) {
        free(words);
        return 0;
    }
    // Xlib passes format-32 property data as C longs.
    unsigned long* longs = (unsigned long*)malloc(count * sizeof(unsigned long));
    for (unsigned long index = 0; index < count && longs; index++)
        longs[index] = words[index];
    free(words);
    void* (*open_display)(const char*) = (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    unsigned long (*intern)(void*, const char*, int) =
        (unsigned long (*)(void*, const char*, int))dlsym(RTLD_DEFAULT, "XInternAtom");
    int (*change)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int) =
        (int (*)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int))
            dlsym(RTLD_DEFAULT, "XChangeProperty");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    int (*sync)(void*, int) = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    void* display = open_display && longs ? open_display(0) : 0;
    if (display && intern && change) {
        unsigned long atom = intern(display, "_NET_WM_ICON", 0);
        change(display, macncheese_icon_window, atom, 6 /* XA_CARDINAL */, 32,
               0 /* PropModeReplace */, longs, (int)count);
        if (sync)
            sync(display, 0);
        write_str("[MacNCheese] Window icon set\n");
    }
    if (display && close_display)
        close_display(display);
    free(longs);
    return 0;
}

static unsigned long macncheese_native_window_handle(id window) {
    /* NSWindow/RBXWindow is the Cocoa object. Only its platformWindow has
     * Darling's X11 windowHandle; sending it to RBXWindow raises an exception
     * on every attempted camera lock, before the lock can become active. */
    SEL responds = sel_registerName("respondsToSelector:");
    SEL native = sel_registerName("platformWindow");
    if (!window || !((signed char (*)(id, SEL, SEL))objc_msgSend)(window, responds, native))
        return 0;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, native);
    if (!platform || !((signed char (*)(id, SEL, SEL))objc_msgSend)(
                         platform, responds,
                         sel_registerName("windowHandle")))
        return 0;
    return ((unsigned long (*)(id, SEL))objc_msgSend)(
        platform, sel_registerName("windowHandle"));
}

static void macncheese_set_window_icon(id window) {
    if (macncheese_wayland_enabled())
        return;
    if (!getenv("MACNCHEESE_ICON_ARGB") || macncheese_icon_window)
        return;
    macncheese_icon_window = macncheese_native_window_handle(window);
    if (!macncheese_icon_window)
        return;
    extern int pthread_create(void**, const void*, void* (*)(void*), void*);
    extern int pthread_detach(void*);
    void* thread;
    if (pthread_create(&thread, 0, macncheese_set_window_icon_thread, 0) == 0)
        pthread_detach(thread);
}

// Darling draws the macOS menu bar (Roblox, Edit, Window...) inside each
// window. With MACNCHEESE_HIDE_MENU_BAR=1 its height is 0: cocotron uses
// +[NSMainMenuView menuHeight] for the bar itself and for converting between
// window frame and content rect, so the game fills the whole window, also
// after Roblox rebuilds its menu (which re-showed a strip after sign-in).
static double macncheese_zero_menu_height(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return 0.0;
}

// Secure-coding convenience methods (macOS 10.13) missing in Darling.
// Roblox archives some state with them after sign-in and unarchives it at
// the next start, which crashed. Map them to the older keyed archiver API;
// unreadable data or an object of the wrong class gives nil, not a crash.
static id keyed_archiver_archived_data(id cls, SEL cmd, id root, signed char secure, id* error) {
    (void)cls; (void)cmd; (void)secure;
    if (error)
        *error = 0;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSKeyedArchiver"), sel_registerName("archivedDataWithRootObject:"), root);
}
static id keyed_unarchiver_unarchived_object(id cls, SEL cmd, Class expected, id data, id* error) {
    (void)cls; (void)cmd;
    if (error)
        *error = 0;
    if (!data)
        return 0;
    id object = 0;
    @try {
        object = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSKeyedUnarchiver"), sel_registerName("unarchiveObjectWithData:"), data);
    } @catch (id exception) {
        (void)exception;
        object = 0;
    }
    if (object && expected &&
        !((signed char (*)(id, SEL, Class))objc_msgSend)(object, sel_registerName("isKindOfClass:"), expected))
        object = 0;
    return object;
}

static void macncheese_install_late_hooks(void);
static void macncheese_start_xfixes_worker(void);
static void hooked_app_finish_launching(id self, SEL cmd) {
    macncheese_install_late_hooks();
    macncheese_start_xfixes_worker(); // ready before the first mouse lock
    orig_app_finish_launching(self, cmd);
    write_str("[MacNCheese Hook] -[NSApplication finishLaunching] returned\n");
    macncheese_queue_pending_uri(self);

    id windows = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("windows"));
    unsigned long count = windows
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) : 0;
    for (unsigned long index = 0; index < count; index++) {
        id window = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            windows, sel_registerName("objectAtIndex:"), index);
        const char* class_name = window ? object_getClassName(window) : 0;
        if (!ascii_strings_equal(class_name, "RBXWindow"))
            continue;
        macncheese_set_window_icon(window);
        signed char visible = ((signed char (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("isVisible"));
        if (!visible) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                window, sel_registerName("makeKeyAndOrderFront:"), 0);
            write_str("[MacNCheese] Ordered RBXWindow to the front after launch\n");
        }
    }
}

// Swizzle NSApplication terminate:
// The launcher watches MACNCHEESE_QUIT_SENTINEL: the file's existence means the
// user asked to quit, so the session can end without waiting for Roblox's
// whole teardown (network closes, telemetry) to finish.
static void macncheese_write_quit_sentinel(void) {
    const char* path = getenv("MACNCHEESE_QUIT_SENTINEL");
    if (!path || !path[0])
        return;
    MacNCheeseFILE* file = fopen(path, "w");
    if (!file)
        return;
    fclose(file);
    write_str("[MacNCheese] Quit sentinel written\n");
}
static void hooked_app_check_for_terminate(id self, SEL _cmd) {
    // No-op: Cocotron's _checkForTerminate calls [self terminate: self] whenever
    // windows are temporarily hidden (place load, return to menu).
}
static void (*orig_app_terminate)(id self, SEL _cmd, id sender) = 0;
static void hooked_app_terminate(id self, SEL _cmd, id sender) {
    write_str("\n[MacNCheese Hook] -[NSApplication terminate:] called!\nBacktrace:\n");
    print_backtrace();
    if (sender != self)
        macncheese_write_quit_sentinel();
    orig_app_terminate(self, _cmd, sender);
}

// Swizzle NSApplication setDelegate:
static void (*orig_app_setDelegate)(id self, SEL _cmd, id del) = 0;
static void hooked_app_setDelegate(id self, SEL _cmd, id del) {
    write_str("\n[MacNCheese Hook] -[NSApplication setDelegate:] called with: ");
    write_str(del ? object_getClassName(del) : "(nil)");
    write_str("\n");
    orig_app_setDelegate(self, _cmd, del);
    macncheese_captured_delegate = del;
}

// Swizzle NSBundle loadNibNamed:owner:
static signed char (*orig_loadNibNamed)(id self, SEL _cmd, id name, id owner) = 0; // BOOL
static signed char hooked_loadNibNamed(id self, SEL _cmd, id name, id owner) {
    write_str("\n[MacNCheese Hook] +[NSBundle loadNibNamed:owner:] entered\n");
    signed char res = orig_loadNibNamed(self, _cmd, name, owner);
    write_str("[MacNCheese Hook] +[NSBundle loadNibNamed:owner:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSNib instantiateNibWithExternalNameTable:
static signed char (*orig_instantiateNib)(id self, SEL _cmd, id table) = 0; // BOOL
static signed char hooked_instantiateNib(id self, SEL _cmd, id table) {
    write_str("\n[MacNCheese Hook] -[NSNib instantiateNibWithExternalNameTable:] entered\n");
    signed char res = orig_instantiateNib(self, _cmd, table);
    write_str("[MacNCheese Hook] -[NSNib instantiateNibWithExternalNameTable:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSWindowTemplate initWithCoder:
static int in_wt_init = 0;
static id (*orig_wt_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_wt_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[MacNCheese Hook] -[NSWindowTemplate initWithCoder:] START\n");
    in_wt_init = 1;
    id res = 0;
    @try {
        res = orig_wt_initWithCoder(self, _cmd, coder);
    } @finally {
        in_wt_init = 0; // or every later decode is logged
    }
    write_str("[MacNCheese Hook] -[NSWindowTemplate initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSKeyedUnarchiver decodeObjectForKey:
static id (*orig_decodeObjectForKey)(id self, SEL _cmd, id key) = 0;
static id hooked_decodeObjectForKey(id self, SEL _cmd, id key) {
    const char* kstr = in_wt_init && key
        ? ((const char* (*)(id, SEL))objc_msgSend)(key, sel_registerName("UTF8String")) : 0;
    if (in_wt_init) {
        write_str("  [WT decodeObjectForKey]: ");
        write_str(kstr ? kstr : "(null)");
        write_str("\n");
    }
    id res = orig_decodeObjectForKey(self, _cmd, key);
    if (in_wt_init) {
        write_str("    -> returned: ");
        write_str(res ? object_getClassName(res) : "(nil)");
        write_str("\n");
    }
    return res;
}

// Swizzle NSIBObjectData initWithCoder:
static id (*orig_od_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_od_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[MacNCheese Hook] -[NSIBObjectData initWithCoder:] START\n");
    id res = orig_od_initWithCoder(self, _cmd, coder);
    write_str("[MacNCheese Hook] -[NSIBObjectData initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSIBObjectData establishConnections
static void (*orig_od_establish)(id self, SEL _cmd) = 0;
static void hooked_od_establish(id self, SEL _cmd) {
    write_str("[MacNCheese Hook] -[NSIBObjectData establishConnections] START\n");
    orig_od_establish(self, _cmd);
    write_str("[MacNCheese Hook] -[NSIBObjectData establishConnections] END\n");
}

// Swizzle NSNibConnector establishConnection
static void (*orig_conn_establish)(id self, SEL _cmd) = 0;
static void hooked_conn_establish(id self, SEL _cmd) {
    write_str("[MacNCheese Hook] -[NSNibConnector establishConnection] called on: ");
    write_str(object_getClassName(self));
    write_str("\n");
    orig_conn_establish(self, _cmd);
    write_str("[MacNCheese Hook] -[NSNibConnector establishConnection] finished\n");
}

// Cocoa x86_64 ABI: NSRect is four doubles passed by value; BOOL is signed char.
typedef struct { double x, y; } MacNCheesePoint;
typedef struct { double width, height; } MacNCheeseSize;
typedef struct { MacNCheesePoint origin; MacNCheeseSize size; } MacNCheeseRect;
typedef signed char MacNCheeseBool;

// Swizzle NSWindow initWithContentRect:styleMask:backing:defer:
static id (*orig_win_init)(id self, SEL _cmd, MacNCheeseRect r, unsigned long sm, unsigned long bs, MacNCheeseBool def) = 0;
static id hooked_win_init(id self, SEL _cmd, MacNCheeseRect r, unsigned long sm, unsigned long bs, MacNCheeseBool def) {
    write_str("\n[MacNCheese Hook] -[NSWindow initWithContentRect:...] START, class: ");
    write_str(object_getClassName(self));
    write_str("\n");
    id res = orig_win_init(self, _cmd, r, sm, bs, def);
    write_str("[MacNCheese Hook] -[NSWindow initWithContentRect:...] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Experimental 1x backing-size fallback for Darling's non-Retina NSView.
// Only add it when AppKit does not implement the method.
extern signed char class_addMethod(Class, SEL, IMP, const char*);
static MacNCheeseSize backing_size_1x(id self, SEL cmd, MacNCheeseSize size) {
    (void)self; (void)cmd;
    return size;
}

// Scale the client's UI contract without changing Cocoa drawable/input pixels.
#include "ui_scale_hook.h"

// Title bar options of macOS 10.10 that Roblox sets on its window
// (setTitlebarAppearsTransparent:, setTitleVisibility:). The Darling release
// this is tested with has them; an older or differently built Darling does
// not, and the game died at start with "unrecognized selector". Darling draws
// no such title bar anyway, so where they are missing they only remember the
// value. Per window state is not needed: Roblox has one window.
static signed char macncheese_titlebar_transparent;
static long macncheese_title_visibility;
static void window_set_titlebar_appears_transparent(id self, SEL cmd, signed char flag) {
    (void)self; (void)cmd;
    macncheese_titlebar_transparent = flag;
}
static signed char window_titlebar_appears_transparent(id self, SEL cmd) {
    (void)self; (void)cmd;
    return macncheese_titlebar_transparent;
}
static void window_set_title_visibility(id self, SEL cmd, long visibility) {
    (void)self; (void)cmd;
    macncheese_title_visibility = visibility;
}
static long window_title_visibility(id self, SEL cmd) {
    (void)self; (void)cmd;
    return macncheese_title_visibility;
}

// NSWindow gained rectangle variants of its screen conversion API after the
// AppKit snapshot used by Darling.  Roblox uses convertRectFromScreen: while
// handling mouse movement.  Falling through Objective-C forwarding is unsafe
// for a CGRect return on x86_64, so implement the methods in terms of the older
// point conversion calls which Darling does provide.
static MacNCheeseRect window_convert_rect_from_screen(id self, SEL cmd, MacNCheeseRect rect) {
    (void)cmd;
    rect.origin = ((MacNCheesePoint (*)(id, SEL, MacNCheesePoint))objc_msgSend)(
        self, sel_registerName("convertScreenToBase:"), rect.origin);
    return rect;
}

static MacNCheeseRect window_convert_rect_to_screen(id self, SEL cmd, MacNCheeseRect rect) {
    (void)cmd;
    rect.origin = ((MacNCheesePoint (*)(id, SEL, MacNCheesePoint))objc_msgSend)(
        self, sel_registerName("convertBaseToScreen:"), rect.origin);
    return rect;
}

static long window_number_at_point(id cls, SEL cmd, MacNCheesePoint point, long belowWindowNumber) {
    (void)cls; (void)cmd; (void)point; (void)belowWindowNumber;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    id win = app ? ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow")) : 0;
    if (!win && app)
        win = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    if (!win && app) {
        id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
        if (windows && ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) > 0)
            win = ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), 0);
    }
    if (win) {
        if (!((MacNCheeseBool (*)(id, SEL))objc_msgSend)(win, sel_registerName("isKeyWindow"))) {
            ((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("makeKeyAndOrderFront:"), (id)0);
        }
        return ((long (*)(id, SEL))objc_msgSend)(win, sel_registerName("windowNumber"));
    }
    return 0;
}

// Darling exposes a deliberately small WebPreferences forwarding stub, but
// omits this legacy singleton constructor.  Roblox asks for the singleton while
// creating its experience coordinator, before any preference setters are sent.
static id macncheese_standard_web_preferences;
static volatile int macncheese_web_preferences_lock;
static id web_preferences_standard_preferences(id cls, SEL cmd) {
    (void)cmd;
    if (macncheese_standard_web_preferences)
        return macncheese_standard_web_preferences;
    while (__sync_lock_test_and_set(&macncheese_web_preferences_lock, 1))
        macncheese_sleep_us(1000);
    if (!macncheese_standard_web_preferences) {
        id preferences = ((id (*)(id, SEL))objc_msgSend)(
            cls, sel_registerName("alloc"));
        preferences = preferences
            ? ((id (*)(id, SEL))objc_msgSend)(preferences, sel_registerName("init"))
            : 0;
        macncheese_standard_web_preferences = preferences;
    }
    __sync_lock_release(&macncheese_web_preferences_lock);
    return macncheese_standard_web_preferences;
}

/* The generic WebKit forwarding stub advertises a zero-argument signature
 * for this BOOL setter, which raises NSForwardSignatureError in Roblox. */
static char web_plugins_enabled_key;
static void web_preferences_set_plugins_enabled(id self, SEL cmd, MacNCheeseBool enabled) {
    (void)cmd;
    extern void objc_setAssociatedObject(id, const void*, id, unsigned long);
    id value = ((id (*)(id, SEL, MacNCheeseBool))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), enabled);
    objc_setAssociatedObject(self, &web_plugins_enabled_key, value, 1);
}
static MacNCheeseBool web_preferences_plugins_enabled(id self, SEL cmd) {
    (void)cmd;
    extern id objc_getAssociatedObject(id, const void*);
    id value = objc_getAssociatedObject(self, &web_plugins_enabled_key);
    return value ? ((MacNCheeseBool (*)(id, SEL))objc_msgSend)(value, sel_registerName("boolValue")) : 0;
}

// Darling's AVFoundation class shell does not implement device discovery.
// Roblox/WebRTC probes cameras during Universal App startup even when voice or
// video capture is not in use.  An empty inventory is the correct headless
// result and lets the rest of the client continue initializing.
static id empty_capture_devices(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel_registerName("array"));
}

// +[AVCaptureDevice authorizationStatusForMediaType:] and
// requestAccessForMediaType:completionHandler: (voice chat asks for the
// microphone): granted; the host's own permissions still apply.
static long capture_authorization_status(id cls, SEL cmd, id media_type) {
    (void)cls; (void)cmd; (void)media_type;
    return 3; // AVAuthorizationStatusAuthorized
}
struct MacNCheeseBoolBlock { void* isa; int flags; int reserved; void (*invoke)(void*, signed char); };
static void capture_request_access(id cls, SEL cmd, id media_type, struct MacNCheeseBoolBlock* handler) {
    (void)cls; (void)cmd; (void)media_type;
    if (handler && handler->invoke)
        handler->invoke(handler, 1);
}
static id empty_capture_devices_for_media_type(id cls, SEL cmd, id media_type) {
    (void)media_type;
    return empty_capture_devices(cls, cmd);
}

static id no_default_capture_device(id cls, SEL cmd, id media_type) {
    (void)cls; (void)cmd; (void)media_type;
    return 0;
}

// Keep the missing CALayer property as associated state. Darling's renderer
// still only supports the existing 1x path; this does not add Retina rendering.
extern void objc_setAssociatedObject(id, const void*, id, unsigned long);
extern id objc_getAssociatedObject(id, const void*);
static char contents_scale_key;
static void layer_set_contents_scale(id self, SEL cmd, double scale) {
    (void)cmd;
    id number = ((id (*)(id, SEL, double))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithDouble:"), scale);
    objc_setAssociatedObject(self, &contents_scale_key, number, 1);
    if (scale != 1.0)
        write_str("[MacNCheese] Warning: CALayer backing rendering above/below 1x is unimplemented\n");
}
static double layer_contents_scale(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &contents_scale_key);
    return number ? ((double (*)(id, SEL))objc_msgSend)(number, sel_registerName("doubleValue")) : 1.0;
}

// Preserve requested touch filtering; this does not synthesize touch events.
static char allowed_touch_types_key;
static void view_set_allowed_touch_types(id self, SEL cmd, unsigned long types) {
    (void)cmd;
    id number = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedLong:"), types);
    objc_setAssociatedObject(self, &allowed_touch_types_key, number, 1);
}
static unsigned long view_allowed_touch_types(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &allowed_touch_types_key);
    return number ? ((unsigned long (*)(id, SEL))objc_msgSend)(number, sel_registerName("unsignedLongValue")) : 0;
}

// Newer AppKit exposes inertial-scroll phases on NSEvent. Darling does not
// synthesize those events, so the only correct value for its existing mouse
// events is NSEventPhaseNone (zero). This also keeps Roblox's input path out of
// Objective-C forwarding while the pointer is over the render view.
static unsigned long event_phase_none(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Darling predates NSProcessInfo's thermal and low-power APIs. Linux exposes
// neither state through this compatibility layer, so report the documented
// neutral values used by macOS when no throttling is active.
static long process_info_thermal_state_nominal(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

static MacNCheeseBool process_info_low_power_mode_disabled(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Trace the handoff between Roblox's OpenGL renderer and Darling's X11
// drawable. Keep this bounded because makeCurrentContext/flushBuffer normally
// run once per frame.
static id (*orig_gl_context_init)(id, SEL, id, id) = 0;
static void (*orig_gl_context_set_view)(id, SEL, id) = 0;
static void (*orig_gl_context_make_current)(id, SEL) = 0;
static void (*orig_gl_context_flush)(id, SEL) = 0;
static volatile long macncheese_gl_make_current_count;
static volatile long macncheese_gl_flush_count;

static void trace_gl_context(const char* action, id self, long count) {
    void** slots = (void**)self;
    write_str("[MacNCheese GL] ");
    write_str(action);
    if (count >= 0) {
        write_str(" #");
        print_num(count);
    }
    write_str(" self=");
    print_hex((unsigned long long)self);
    if (self) {
        write_str(" class=");
        write_str(object_getClassName(self));
        write_str(" view=");
        print_hex((unsigned long long)slots[2]);
        write_str(" cgl-context=");
        print_hex((unsigned long long)slots[3]);
        write_str(" subwindow=");
        print_hex((unsigned long long)slots[4]);
        write_str(" egl-surface=");
        print_hex((unsigned long long)slots[5]);
    }
    write_str("\n");
}

extern void macncheese_prepare_context(void* format);
extern void macncheese_finish_context(void);
extern void macncheese_note_pixel_format(void* format, const unsigned int* attributes);
static id hooked_gl_context_init(id self, SEL cmd, id format, id shared) {
    macncheese_prepare_context(format); // Core Profile if Roblox asked for it (gl_profile.c)
    id result = orig_gl_context_init(self, cmd, format, shared);
    macncheese_finish_context();
    trace_gl_context("init", result, -1);
    return result;
}

static void hooked_gl_context_set_view(id self, SEL cmd, id view) {
    orig_gl_context_set_view(self, cmd, view);
    trace_gl_context("setView", self, -1);
}

static void hooked_gl_context_make_current(id self, SEL cmd) {
    orig_gl_context_make_current(self, cmd);
    long count = __sync_add_and_fetch(&macncheese_gl_make_current_count, 1);
    void** slots = (void**)self;
    if (self && slots[3] && slots[5]) {
        void** cgl_slots = (void**)slots[3];
        macncheese_gl_window_surface = slots[5];
        macncheese_gl_window_egl_context = cgl_slots[9];
    }
    if (count <= 5 || count == 60 || count == 600)
        trace_gl_context("makeCurrentContext", self, count);
    if (macncheese_gl_hacks_disabled()) // runs every frame: no lookups
        return;
    void* (*current_display)(void) = MACNCHEESE_NEXT(void* (*)(void), "eglGetCurrentDisplay");
    void* (*current_context)(void) = MACNCHEESE_NEXT(void* (*)(void), "eglGetCurrentContext");
    void* (*current_surface)(int) = MACNCHEESE_NEXT(void* (*)(int), "eglGetCurrentSurface");
    int (*make_current)(void*, void*, void*, void*) =
        MACNCHEESE_NEXT(int (*)(void*, void*, void*, void*), "eglMakeCurrent");
    unsigned int (*egl_error)(void) = MACNCHEESE_NEXT(unsigned int (*)(void), "eglGetError");
    if (self && slots[5] && current_display && current_context &&
        current_surface && make_current && !current_surface(0x3059)) {
        void* display = current_display();
        void* context = current_context();
        int attached = make_current(display, slots[5], slots[5], context);
        write_str("[MacNCheese GL] repaired missing EGL window surface result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
}

static void dump_final_program_shaders(int program) {
    if (program <= 0 || program >= MACNCHEESE_SHADER_SLOTS ||
        !__sync_bool_compare_and_swap(&macncheese_dumped_final_program, 0, 1))
        return;

    write_str("[MacNCheese GL] final program=");
    print_num(program);
    write_str(" shaders=");
    for (int index = 0; index < 4; index++) {
        unsigned int shader = macncheese_program_shaders[program][index];
        if (index)
            write_str(",");
        print_num(shader);
        write_str(":");
        print_hex(shader < MACNCHEESE_SHADER_SLOTS
                      ? macncheese_shader_types[shader]
                      : 0);
        if (!shader || shader >= MACNCHEESE_SHADER_SLOTS ||
            !macncheese_shader_sources[shader])
            continue;
        char path[] = "/Volumes/SystemRoot/tmp/macncheese-final-shader-0.glsl";
        path[sizeof(path) - sizeof("0.glsl")] = (char)('0' + index);
        MacNCheeseFILE* output = fopen(path, "w");
        if (output) {
            fwrite(macncheese_shader_sources[shader], 1,
                   macncheese_shader_source_lengths[shader], output);
            fclose(output);
        }
    }
    write_str("\n");
}

static void trace_gl_frame_state(long count) {
    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    void (*read_pixels)(int, int, int, int, unsigned int, unsigned int, void*) =
        (void (*)(int, int, int, int, unsigned int, unsigned int, void*))
            dlsym(RTLD_NEXT, "glReadPixels");
    void (*set_read_buffer)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glReadBuffer");
    if (!get_integer)
        return;

    int draw_framebuffer = -1;
    int read_framebuffer = -1;
    int program = -1;
    int draw_buffer = -1;
    int read_buffer = -1;
    int viewport[4] = {-1, -1, -1, -1};
    get_integer(0x8CA6U, &draw_framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    get_integer(0x8CAAU, &read_framebuffer); // GL_READ_FRAMEBUFFER_BINDING
    get_integer(0x8B8DU, &program);          // GL_CURRENT_PROGRAM
    get_integer(0x0C01U, &draw_buffer);      // GL_DRAW_BUFFER
    get_integer(0x0C02U, &read_buffer);      // GL_READ_BUFFER
    get_integer(0x0BA2U, viewport);          // GL_VIEWPORT
    dump_final_program_shaders(program);

    void* (*egl_current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    void* (*egl_current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*egl_current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");

    write_str("[MacNCheese GL] frame-state #");
    print_num(count);
    write_str(" draws=");
    print_num(macncheese_gl_draw_count);
    write_str(" blits=");
    print_num(macncheese_gl_blit_count);
    write_str(" clears=");
    print_num(macncheese_gl_clear_count);
    write_str(" default-binds=");
    print_num(macncheese_gl_default_framebuffer_bind_count);
    write_str(" draw-fbo=");
    print_num(draw_framebuffer);
    write_str(" read-fbo=");
    print_num(read_framebuffer);
    write_str(" program=");
    print_num(program);
    write_str(" draw-buffer=");
    print_hex((unsigned long long)(unsigned int)draw_buffer);
    write_str(" read-buffer=");
    print_hex((unsigned long long)(unsigned int)read_buffer);
    write_str(" egl-context=");
    print_hex((unsigned long long)(egl_current_context
                                      ? egl_current_context()
                                      : 0));
    write_str(" egl-display=");
    print_hex((unsigned long long)(egl_current_display
                                      ? egl_current_display()
                                      : 0));
    write_str(" egl-draw-surface=");
    print_hex((unsigned long long)(egl_current_surface
                                      ? egl_current_surface(0x3059)
                                      : 0)); // EGL_DRAW
    write_str(" viewport=");
    print_num(viewport[0]);
    write_str(",");
    print_num(viewport[1]);
    write_str(",");
    print_num(viewport[2]);
    write_str(",");
    print_num(viewport[3]);
    if (read_pixels && set_read_buffer && viewport[2] > 0 && viewport[3] > 0) {
        static const int fractions[3] = {1, 2, 3};
        // Roblox leaves the default read buffer disabled. Select the same back
        // buffer it draws into only while sampling, then restore its state.
        set_read_buffer(0x0402U); // GL_BACK_LEFT
        write_str(" samples=");
        for (int row = 0; row < 3; row++) {
            for (int column = 0; column < 3; column++) {
                unsigned char pixel[4] = {0, 0, 0, 0};
                int x = viewport[0] + viewport[2] * fractions[column] / 4;
                int y = viewport[1] + viewport[3] * fractions[row] / 4;
                read_pixels(x, y, 1, 1, 0x1908U, 0x1401U, pixel);
                if (row || column)
                    write_str(";");
                print_num(pixel[0]);
                write_str(",");
                print_num(pixel[1]);
                write_str(",");
                print_num(pixel[2]);
                write_str(",");
                print_num(pixel[3]);
            }
        }
        set_read_buffer((unsigned int)read_buffer);
    }
    write_str("\n");
}

static void hooked_gl_context_flush(id self, SEL cmd) {
    long count = __sync_add_and_fetch(&macncheese_gl_flush_count, 1);
    static volatile int test_clear = -1;
    if (macncheese_env_cached("MACNCHEESE_GL_TEST_CLEAR", &test_clear)) {
        void (*disable)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
        void (*color_mask)(unsigned char, unsigned char, unsigned char,
                           unsigned char) =
            (void (*)(unsigned char, unsigned char, unsigned char,
                      unsigned char))dlsym(RTLD_NEXT, "glColorMask");
        void (*clear_color)(float, float, float, float) =
            (void (*)(float, float, float, float))
                dlsym(RTLD_NEXT, "glClearColor");
        void (*clear)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
        unsigned int (*get_error)(void) =
            (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
        unsigned int (*check_framebuffer)(unsigned int) =
            (unsigned int (*)(unsigned int))
                dlsym(RTLD_NEXT, "glCheckFramebufferStatus");
        void (*finish)(void) = (void (*)(void))dlsym(RTLD_NEXT, "glFinish");
        if (disable && color_mask && clear_color && clear) {
            unsigned int before_error = get_error ? get_error() : 0;
            disable(0x0C11U); // GL_SCISSOR_TEST
            color_mask(1, 1, 1, 1);
            clear_color(1.0f, 0.0f, 1.0f, 1.0f);
            clear(0x00004000U); // GL_COLOR_BUFFER_BIT
            if (finish)
                finish();
            if (count <= 5) {
                write_str("[MacNCheese GL] test-clear before-error=");
                print_hex(before_error);
                write_str(" after-error=");
                print_hex(get_error ? get_error() : 0);
                write_str(" framebuffer-status=");
                print_hex(check_framebuffer
                              ? check_framebuffer(0x8CA9U) // GL_DRAW_FRAMEBUFFER
                              : 0);
                write_str("\n");
            }
        }
    }
    if (macncheese_gl_trace_enabled() && (count <= 5 || count == 60 || count == 600)) {
        trace_gl_frame_state(count);
        trace_gl_context("flushBuffer", self, count);
    }
    orig_gl_context_flush(self, cmd);
}

// Darling's CALayerContext renders layers on the main thread and leaves its
// own CGL context current. On macOS the render server does this in another
// process, so Roblox makes its NSOpenGLContext current once and expects it to
// stay current. Without restoring it, every later Roblox GL call goes to the
// surfaceless layer context, where Roblox's shaders and buffers do not exist.
extern void* CGLGetCurrentContext(void);
static void (*orig_layer_context_render_layer)(id, SEL, id) = 0;
static volatile long macncheese_layer_context_restores;
static void hooked_layer_context_render_layer(id self, SEL cmd, id layer) {
    void* previous = CGLGetCurrentContext();
    orig_layer_context_render_layer(self, cmd, layer);
    if (CGLGetCurrentContext() != previous) {
        int error = macncheese_CGLSetCurrentContext(previous);
        if (!error && __sync_add_and_fetch(&macncheese_layer_context_restores, 1) == 1)
            write_str("[MacNCheese GL] Restored app GL context after CALayerContext render\n");
    }
}

/* CARenderer calls its image uploader directly, so dyld interposition cannot
 * replace that call. Populate a new texture before entering its recursive
 * renderer; the original then preserves its animation and child transforms. */
extern void macncheese_CATexImage2DCGImage(void*);
extern void glGenTextures(int, unsigned int*);
extern unsigned char glIsTexture(unsigned int);
extern void glBindTexture(unsigned int, unsigned int);
extern void glTexParameteri(unsigned int, unsigned int, int);
static void (*orig_ca_renderer_render_layer)(id, SEL, id, double, double);
static void hooked_ca_renderer_render_layer(id self, SEL cmd, id layer,
                                           double z, double current_time) {
    id number = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("_textureId"));
    unsigned int texture = number ? ((unsigned int (*)(id, SEL))objc_msgSend)(
        number, sel_registerName("unsignedIntValue")) : 0;
    if (!texture || !glIsTexture(texture)) {
        if (!texture) {
            glGenTextures(1, &texture);
            if (!texture)
                return;
            id value = ((id (*)(id, SEL, unsigned int))objc_msgSend)(
                (id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedInt:"), texture);
            ((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("_setTextureId:"), value);
        }
        glBindTexture(0x0DE1 /* GL_TEXTURE_2D */, texture);
        id contents = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("contents"));
        macncheese_CATexImage2DCGImage(contents);
        const char* filter_names[] = {"minificationFilter", "magnificationFilter"};
        const unsigned int parameters[] = {0x2801, 0x2800};
        for (int i = 0; i < 2; ++i) {
            id filter = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName(filter_names[i]));
            unsigned char nearest = ((unsigned char (*)(id, SEL, id))objc_msgSend)(
                filter, sel_registerName("isEqualToString:"), @"nearest");
            glTexParameteri(0x0DE1, parameters[i], nearest ? 0x2600 : 0x2601);
        }
        glTexParameteri(0x0DE1, 0x2802 /* GL_TEXTURE_WRAP_S */, 0x2901 /* GL_REPEAT */);
        glTexParameteri(0x0DE1, 0x2803 /* GL_TEXTURE_WRAP_T */, 0x2901);
    }
    orig_ca_renderer_render_layer(self, cmd, layer, z, current_time);
}

// Mouse lock (in-game camera). On macOS CGAssociateMouseAndMouseCursorPosition
// (false) freezes the cursor and mouse events carry raw deltas. Darling's
// version cannot be used for that:
//  - it passes "connected" to -[NSDisplay grabMouse:] unchanged (inverted);
//  - Roblox repeats the call every frame and each grab recenters the pointer;
//  - in grab mode deltas are measured from the pin point, and events queued
//    before the asynchronous warp-back report growing offsets (5, 10, 15
//    instead of 5, 5, 5), so the camera spun far too fast;
//  - Roblox's per-frame CGWarpMouseCursorPosition fought the pin point.
// So the lock is implemented here: the pointer stays free and Darling's
// ordinary per-event deltas are used; when it drifts more than
// MACNCHEESE_LOCK_RADIUS from the window center it is moved back with a
// relative XWarpPointer, and the single motion event caused by that warp is
// dropped. Roblox's own warp requests during the lock are ignored; when the
// lock ends the pointer goes back to where the lock began, as a frozen macOS
// cursor stays put.
extern int CGAssociateMouseAndMouseCursorPosition(unsigned int connected);
extern int CGWarpMouseCursorPosition(MacNCheesePoint position);
#define MACNCHEESE_LOCK_RADIUS 100.0
static volatile int macncheese_pointer_grabbed;
static volatile int macncheese_mouse_lock_requested;
static volatile int macncheese_drop_next_motion; // first motion after re-entering mid-lock
static volatile int macncheese_drop_warp_motion;
static int macncheese_warp_wait_events; // motion events seen since the warp
static MacNCheesePoint macncheese_expected_warp_delta;
static volatile long macncheese_associate_mouse_count;
static MacNCheesePoint macncheese_lock_anchor;
static volatile int macncheese_lock_anchor_pending;

// Move the pointer by (dx, dy) window points (Cocoa axes, y up).
static void macncheese_warp_pointer_by(double dx, double dy) {
    static int (*warp)(void*, unsigned long, unsigned long, int, int,
                       unsigned int, unsigned int, int, int);
    static int (*flush)(void*);
    if (!warp) {
        warp = (int (*)(void*, unsigned long, unsigned long, int, int,
                        unsigned int, unsigned int, int, int))
            dlsym(RTLD_DEFAULT, "XWarpPointer");
        flush = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFlush");
    }
    id display_object = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
    void* display = display_object
        ? ((void* (*)(id, SEL))objc_msgSend)(display_object, sel_registerName("display"))
        : 0;
    int ix = (int)(dx < 0 ? dx - 0.5 : dx + 0.5);
    int iy = (int)(dy < 0 ? dy - 0.5 : dy + 0.5);
    if (!warp || !display || (!ix && !iy))
        return;
    // X11 y grows downward.
    warp(display, 0, 0, 0, 0, 0, 0, ix, -iy);
    if (flush)
        flush(display);
    macncheese_expected_warp_delta.x = ix;
    macncheese_expected_warp_delta.y = iy;
    macncheese_warp_wait_events = 0;
    macncheese_drop_warp_motion = 1;
}

static MacNCheesePoint macncheese_window_center(id window) {
    // NSRect is returned in memory on x86_64: objc_msgSend_stret, not objc_msgSend.
    extern void objc_msgSend_stret(void);
    MacNCheeseRect frame = ((MacNCheeseRect (*)(id, SEL))objc_msgSend_stret)(
        window, sel_registerName("frame"));
    MacNCheesePoint center = {frame.size.width / 2.0, frame.size.height / 2.0};
    return center;
}

static id macncheese_lock_window(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
                                             sel_registerName("sharedApplication"));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    if (!window)
        window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    return window;
}

// While locked, a macOS cursor does not move: event locations, the window's
// mouse location and +[NSEvent mouseLocation] all stay where the lock began,
// and only the deltas change. Here the real pointer wanders around the window
// center, so report the frozen positions to Roblox as macOS would.
static MacNCheesePoint macncheese_frozen_window_location;
static MacNCheesePoint macncheese_frozen_screen_location;
static MacNCheesePoint (*orig_event_location_in_window)(id, SEL) = 0;
static MacNCheesePoint (*orig_window_mouse_location)(id, SEL) = 0;
static MacNCheesePoint (*orig_event_mouse_location)(id, SEL) = 0;
static MacNCheesePoint hooked_event_location_in_window(id self, SEL cmd) {
    if (macncheese_pointer_grabbed) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("type"));
        if ((type >= 1 && type <= 7) || type == 25 || type == 26 || type == 27)
            return macncheese_frozen_window_location;
    }
    return orig_event_location_in_window(self, cmd);
}
static MacNCheesePoint hooked_window_mouse_location(id self, SEL cmd) {
    if (macncheese_pointer_grabbed)
        return macncheese_frozen_window_location;
    return orig_window_mouse_location(self, cmd);
}
static MacNCheesePoint hooked_event_mouse_location(id cls, SEL cmd) {
    if (macncheese_pointer_grabbed)
        return macncheese_frozen_screen_location;
    return orig_event_mouse_location(cls, cmd);
}
static MacNCheesePoint macncheese_real_window_mouse_location(id window) {
    SEL selector = sel_registerName("mouseLocationOutsideOfEventStream");
    return orig_window_mouse_location ? orig_window_mouse_location(window, selector)
        : ((MacNCheesePoint (*)(id, SEL))objc_msgSend)(window, selector);
}
static MacNCheesePoint macncheese_real_event_location(id event) {
    SEL selector = sel_registerName("locationInWindow");
    return orig_event_location_in_window ? orig_event_location_in_window(event, selector)
        : ((MacNCheesePoint (*)(id, SEL))objc_msgSend)(event, selector);
}

// Under Xwayland, XWarpPointer only moves the X server's idea of the pointer;
// the next Wayland motion reports the real position again, so recentering
// bounced the pointer back and forth. Xwayland emulates warps properly while
// the X cursor is hidden with XFixes. The requests go over a private X11
// socket (xfixes_raw.c), and on a worker thread, so the game thread never
// waits on X.
//
// The worker sleeps in a read of a pipe and wakes when the wanted state
// changes. It used to poll every 5 ms with Darling's usleep, two
// darlingserver requests each (400 a second for the whole session), and a
// hide could lag 5 ms behind the lock. It starts, and opens its connection,
// when the app finishes launching, not at the first lock.
extern int macncheese_raw_xfixes_open(void);
extern int macncheese_raw_xfixes_set_hidden(int hidden);
extern int macncheese_wayland_enabled(void);
extern int pthread_create(void**, const void*, void* (*)(void*), void*);
extern int pthread_detach(void*);
extern int pipe(int[2]);
extern long read(int, void*, unsigned long);
extern int macncheese_cursor_overlay_update(int, unsigned long, int);
static volatile int macncheese_cursor_wanted_hidden;
static volatile unsigned long macncheese_cursor_lock_window;
static volatile int macncheese_cursor_hide_depth;
static volatile int macncheese_cursor_worker_ready;
static volatile int macncheese_cursor_worker_started;
static volatile unsigned long long macncheese_cursor_retry_after;
static volatile int macncheese_input_focused = 1;
static int macncheese_cursor_wake[2] = {-1, -1};
static MacNCheeseCursorSelection macncheese_window_cursor_selection;
static volatile unsigned int macncheese_window_cursor_lock;
static unsigned long long macncheese_input_now_ns(void) {
    struct { long seconds, nanoseconds; } now = {0, 0};
    long result;
    __asm__ volatile("syscall" : "=a"(result)
        : "a"(228L /* Linux clock_gettime */), "D"(1L /* CLOCK_MONOTONIC */), "S"(&now)
        : "rcx", "r11", "memory");
    return result == 0 ? (unsigned long long)now.seconds * 1000000000ULL + now.nanoseconds : 0;
}
static void* macncheese_xfixes_worker(void* unused) {
    (void)unused;
    if (!macncheese_raw_xfixes_open()) {
        write_str("[MacNCheese] XFixes unavailable, mouse lock may bounce\n");
        __atomic_store_n(&macncheese_cursor_retry_after, macncheese_input_now_ns() + 1000000000ULL, __ATOMIC_RELEASE);
        __atomic_store_n(&macncheese_cursor_worker_ready, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&macncheese_cursor_worker_started, 0, __ATOMIC_RELEASE);
        return 0;
    }
    write_str("[MacNCheese] XFixes ready for cursor hiding\n");
    void* (*open_display)(const char*) =
        (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    int (*undefine_cursor)(void*, unsigned long) =
        (int (*)(void*, unsigned long))dlsym(RTLD_DEFAULT, "XUndefineCursor");
    int (*query_tree)(void*, unsigned long, unsigned long*, unsigned long*,
                      unsigned long**, unsigned int*) =
        (int (*)(void*, unsigned long, unsigned long*, unsigned long*,
                 unsigned long**, unsigned int*))dlsym(RTLD_DEFAULT, "XQueryTree");
    int (*free_data)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFree");
    int (*sync_display)(void*, int) = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    void* xlib_display = open_display ? open_display(0) : 0;
    MacNCheeseCursorApplyAPI cursor_api = {undefine_cursor, query_tree, free_data, sync_display};
    if (xlib_display && undefine_cursor && query_tree && free_data && sync_display)
        write_str("[MacNCheese] Window cursor worker ready\n");
    __atomic_store_n(&macncheese_cursor_worker_ready, 1, __ATOMIC_RELEASE);
    int applied = 0;
    for (;;) {
        int wanted = __atomic_load_n(&macncheese_cursor_wanted_hidden, __ATOMIC_ACQUIRE);
        MacNCheeseCursorSelection selected = {0};
        macncheese_lock(&macncheese_window_cursor_lock);
        int changed = macncheese_cursor_selection_take(&macncheese_window_cursor_selection, &selected);
        macncheese_unlock(&macncheese_window_cursor_lock);
        if (changed) {
            if (macncheese_cursor_selection_apply(&cursor_api, xlib_display, selected.window)) {
                static volatile long defined;
                if (__sync_add_and_fetch(&defined, 1) <= 3) {
                    write_str("[MacNCheese Cursor] Applied selected cursor; rendering children inherit it\n");
                }
            }
        }
        unsigned long lock_window = __atomic_load_n(&macncheese_cursor_lock_window, __ATOMIC_ACQUIRE);
        if (!macncheese_cursor_overlay_update(wanted, lock_window,
                __atomic_load_n(&macncheese_cursor_hide_depth, __ATOMIC_ACQUIRE) == 0)) {
            static int reported;
            if (!reported) {
                reported = 1;
                write_str("[MacNCheese Cursor] Visible locked-cursor overlay unavailable\n");
            }
        }
        if (wanted != applied) {
            if (macncheese_raw_xfixes_set_hidden(wanted))
                applied = wanted;
        }
        char bytes[64];
        if (read(macncheese_cursor_wake[0], bytes, sizeof bytes) <= 0)
            macncheese_sleep_us(5000); // no pipe: poll, but without darlingserver
    }
    return 0;
}

static void macncheese_start_xfixes_worker(void) {
    if (macncheese_wayland_enabled())
        return;
    if (macncheese_input_now_ns() < __atomic_load_n(&macncheese_cursor_retry_after, __ATOMIC_ACQUIRE) ||
        !__sync_bool_compare_and_swap(&macncheese_cursor_worker_started, 0, 1))
        return;
    if (macncheese_cursor_wake[0] < 0)
        macncheese_wake_pipe(macncheese_cursor_wake);
    void* thread;
    if (pthread_create(&thread, 0, macncheese_xfixes_worker, 0) == 0) {
        pthread_detach(thread);
        macncheese_wake_worker(macncheese_cursor_wake[1]);
    } else {
        __atomic_store_n(&macncheese_cursor_retry_after, macncheese_input_now_ns() + 1000000000ULL, __ATOMIC_RELEASE);
        __atomic_store_n(&macncheese_cursor_worker_started, 0, __ATOMIC_RELEASE);
    }
}

static void macncheese_set_x_cursor_hidden(int hidden) {
    __atomic_store_n(&macncheese_cursor_wanted_hidden, hidden, __ATOMIC_RELEASE);
    macncheese_start_xfixes_worker();
    if (__atomic_load_n(&macncheese_cursor_worker_ready, __ATOMIC_ACQUIRE))
        macncheese_wake_worker(macncheese_cursor_wake[1]);
}


static void macncheese_cursor_changed(void) {
    if (__atomic_load_n(&macncheese_cursor_worker_ready, __ATOMIC_ACQUIRE))
        macncheese_wake_worker(macncheese_cursor_wake[1]);
}
static void (*orig_cursor_hide)(id, SEL);
static void hooked_cursor_hide(id self, SEL cmd) {
    __atomic_add_fetch(&macncheese_cursor_hide_depth, 1, __ATOMIC_RELEASE);
    orig_cursor_hide(self, cmd);
    macncheese_cursor_changed();
}
static void (*orig_cursor_unhide)(id, SEL);
static void hooked_cursor_unhide(id self, SEL cmd) {
    orig_cursor_unhide(self, cmd);
    int depth = __atomic_load_n(&macncheese_cursor_hide_depth, __ATOMIC_ACQUIRE);
    while (depth > 0 && !__atomic_compare_exchange_n(&macncheese_cursor_hide_depth,
            &depth, depth - 1, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {}
    macncheese_cursor_changed();
}

// Raw motion for the lock (raw_mouse.c). With XInput 2 the camera deltas
// come from the mouse itself: no pointer acceleration, no merged motion, and
// the warps that keep the hidden pointer inside the window need no
// recognising, since warps produce no raw events. While it is active the
// game gets no pointer motion at all during the lock: raw deltas are summed
// within each bounded X event batch, then posted as one mouse event. Button,
// keyboard and focus transitions flush the sum to preserve their ordering.
// and the real MotionNotify events only serve to keep the pointer near its
// anchor. The selection changes on the event loop's own thread and X
// connection (the game thread only asks). MACNCHEESE_RAW_MOUSE=0 keeps the
// pointer-delta lock.
typedef struct objc_ivar* Ivar; // also declared with the cursor code below
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);
extern int macncheese_raw_mouse_select(void* display, int enabled);
extern int macncheese_raw_mouse_event(void* display, void* event, double* dx, double* dy, int* used_raw);
static id macncheese_event_queue(id display);
static void macncheese_lock_event_queue(void);
static void macncheese_unlock_event_queue(void);
static unsigned long macncheese_event_type(id event);
static double (*orig_mouse_event_delta_x)(id, SEL);
static double (*orig_mouse_event_delta_y)(id, SEL);
static volatile int macncheese_raw_mouse_wanted;   // the lock state, set by the game thread
static int macncheese_raw_mouse_selected;          // what the event loop applied last
static volatile int macncheese_raw_mouse_active;   // raw events selected: deltas come from them
static unsigned int macncheese_raw_buttons;        // X buttons held, bit 1..3
static int macncheese_raw_have_anchor;
static int macncheese_raw_anchor_x, macncheese_raw_anchor_y; // X window coordinates, y down
static int macncheese_raw_start_x, macncheese_raw_start_y;   // where the pointer was when the lock began
static int macncheese_raw_last_x, macncheese_raw_last_y;     // the last position seen
static long macncheese_raw_events, macncheese_raw_posted;
static int macncheese_raw_motions_without_raw; // pointer motion seen while no raw event came
static int macncheese_raw_accelerated_streak; // raw cookies carrying only accelerated values
static unsigned long macncheese_x_modifier_flags;
static unsigned char macncheese_x_modifier_masks[256], macncheese_x_modifier_keys_down[256];
static void* macncheese_x_modifier_display;
static volatile unsigned int macncheese_x_event_draining;
static id macncheese_raw_pending_window;
static double macncheese_raw_pending_dx, macncheese_raw_pending_dy;
static unsigned long macncheese_raw_pending_type, macncheese_raw_pending_flags;
static unsigned int macncheese_raw_pending_button;
static MacNCheesePoint macncheese_raw_pending_location;
/* Darling classifies Button2 (middle) as right-drag. Correct the generated
 * event at postEvent:, on the same thread, without changing its X state. */
static __thread unsigned long macncheese_core_motion_type;
static __thread unsigned int macncheese_core_motion_button;
static __thread int macncheese_x_batch_last;

static int macncheese_raw_mouse_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACNCHEESE_RAW_MOUSE");
        enabled = !(value && value[0] == '0');
    }
    return enabled;
}

static void* macncheese_x11_display_connection(id display) {
    static long offset = -2;
    if (offset == -2) {
        Ivar ivar = class_getInstanceVariable(object_getClass(display), "_display");
        offset = ivar ? (long)ivar_getOffset(ivar) : -1;
    }
    return offset >= 0 ? *(void**)((char*)display + offset) : (void*)0;
}

static void macncheese_warp_on_display(void* display, int dx, int dy) {
    static int (*warp)(void*, unsigned long, unsigned long, int, int, unsigned int, unsigned int, int, int);
    static int (*flush)(void*);
    if (!warp) {
        warp = (int (*)(void*, unsigned long, unsigned long, int, int, unsigned int, unsigned int, int, int))
            dlsym(RTLD_DEFAULT, "XWarpPointer");
        flush = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFlush");
    }
    if (!warp || !display || (!dx && !dy))
        return;
    warp(display, 0, 0, 0, 0, 0, 0, dx, dy);
    if (flush)
        flush(display);
}

// One mouse event with the raw deltas, on the lock window. Darling's deltaY
// is computed upward and hooked_mouse_event_delta_y flips it for the game,
// so the raw y (downward, as macOS reports it) is stored flipped.
static unsigned long macncheese_motion_type(unsigned int buttons, unsigned int* button) {
    if (buttons & (1u << 1)) { *button = 1; return 6; }
    if (buttons & (1u << 3)) { *button = 3; return 7; }
    if (buttons & (1u << 2)) { *button = 2; return 27; }
    *button = 0;
    return 5;
}

static void macncheese_flush_raw_motion(id display) {
    id window = macncheese_raw_pending_window;
    if (!window) return;
    double dx = macncheese_raw_pending_dx, dy = macncheese_raw_pending_dy;
    macncheese_raw_pending_window = 0;
    macncheese_raw_pending_dx = macncheese_raw_pending_dy = 0;
    if (!macncheese_pointer_grabbed || (!dx && !dy)) {
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("release"));
        return;
    }
    id event_class = (id)objc_getClass("NSEvent");
    id event = ((id (*)(id, SEL, unsigned long, MacNCheesePoint, unsigned long, id, long, double, double))objc_msgSend)(
        event_class, sel_registerName("mouseEventWithType:location:modifierFlags:window:clickCount:deltaX:deltaY:"),
        macncheese_raw_pending_type, macncheese_raw_pending_location, macncheese_raw_pending_flags,
        window, 1, dx, -dy);
    if (event) {
        ((void (*)(id, SEL, long))objc_msgSend)(event, sel_registerName("_setButtonNumber:"),
                                               (long)macncheese_raw_pending_button);
        ((void (*)(id, SEL, id, signed char))objc_msgSend)(display, sel_registerName("postEvent:atStart:"), event, 0);
        macncheese_raw_posted++;
    }
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("release"));
}

static void macncheese_accumulate_raw_motion(id display, double dx, double dy) {
    id window = macncheese_lock_window();
    if (!window) return;
    unsigned int button;
    unsigned long type = macncheese_motion_type(macncheese_raw_buttons, &button);
    if (macncheese_raw_pending_window &&
        (macncheese_raw_pending_window != window || macncheese_raw_pending_type != type ||
         macncheese_raw_pending_flags != macncheese_x_modifier_flags || macncheese_raw_pending_button != button))
        macncheese_flush_raw_motion(display);
    if (!macncheese_raw_pending_window) {
        macncheese_raw_pending_window = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("retain"));
        macncheese_raw_pending_type = type;
        macncheese_raw_pending_button = button;
        macncheese_raw_pending_flags = macncheese_x_modifier_flags;
        macncheese_raw_pending_location = macncheese_frozen_window_location;
    }
    macncheese_raw_pending_dx += dx;
    macncheese_raw_pending_dy += dy;
    /* Direct postXEvent: callers also get their event without needing a drain. */
    if (!__atomic_load_n(&macncheese_x_event_draining, __ATOMIC_ACQUIRE))
        macncheese_flush_raw_motion(display);
}

static unsigned long macncheese_modifiers_for_x_state(unsigned int state) {
    unsigned long flags = 0;
    if (state & 1u) flags |= 1UL << 17;       // Shift
    if (state & 2u) flags |= 1UL << 16;       // Caps Lock
    if (state & 4u) flags |= 1UL << 18;       // Control
    if (state & 8u) flags |= 1UL << 19;       // Alt
    if (state & 64u) flags |= 1UL << 20;      // Super/Command
    if (state & 128u) flags |= 1UL << 23;     // AltGr/Function
    return flags;
}

static unsigned int macncheese_buttons_for_x_state(unsigned int state) {
    return ((state & (1u << 8)) ? 1u << 1 : 0) |
           ((state & (1u << 9)) ? 1u << 2 : 0) |
           ((state & (1u << 10)) ? 1u << 3 : 0);
}

static void macncheese_refresh_x_modifier_mapping(id self, int seed_keys) {
    struct modifier_map { int keys_per_modifier; unsigned char* keycodes; };
    static struct modifier_map* (*get_mapping)(void*);
    static int (*free_mapping)(struct modifier_map*);
    static int (*query_keys)(void*, char*);
    if (!get_mapping) {
        get_mapping = (struct modifier_map* (*)(void*))dlsym(RTLD_DEFAULT, "XGetModifierMapping");
        free_mapping = (int (*)(struct modifier_map*))dlsym(RTLD_DEFAULT, "XFreeModifiermap");
        query_keys = (int (*)(void*, char*))dlsym(RTLD_DEFAULT, "XQueryKeymap");
    }
    void* display = macncheese_x11_display_connection(self);
    if (!display || !get_mapping || !free_mapping) return;
    struct modifier_map* map = get_mapping(display);
    if (map && map->keycodes && map->keys_per_modifier >= 0 && map->keys_per_modifier <= 256) {
        for (int key = 0; key < 256; key++) macncheese_x_modifier_masks[key] = 0;
        for (int modifier = 0; modifier < 8; modifier++)
            for (int index = 0; index < map->keys_per_modifier; index++) {
                unsigned int key = map->keycodes[modifier * map->keys_per_modifier + index];
                if (key) macncheese_x_modifier_masks[key] |= 1u << modifier;
            }
        macncheese_x_modifier_display = display;
    }
    if (map) free_mapping(map);
    if (seed_keys && query_keys) {
        char down[32] = {0};
        if (query_keys(display, down))
            for (int key = 0; key < 256; key++)
                macncheese_x_modifier_keys_down[key] = ((unsigned char)down[key / 8] >> (key % 8)) & 1;
    }
}

static void macncheese_update_x_input_state(id display, void* event) {
    int type = *(int*)event;
    if (type < 2 || type > 6) return;
    unsigned int state = *(unsigned int*)((char*)event + 80);
    if (type == 2 || type == 3) {
        if (macncheese_x_modifier_display != macncheese_x11_display_connection(display))
            macncheese_refresh_x_modifier_mapping(display, 1);
        state = macncheese_x_modifier_transition(state,
            *(unsigned int*)((char*)event + 84), type == 2,
            macncheese_x_modifier_masks, macncheese_x_modifier_keys_down);
    }
    unsigned long flags = macncheese_modifiers_for_x_state(state);
    unsigned int buttons = macncheese_buttons_for_x_state(state);
    if (type == 4 || type == 5) {
        unsigned int button = *(unsigned int*)((char*)event + 84);
        if (button >= 1 && button <= 3) {
            if (type == 4) buttons |= 1u << button;
            else buttons &= ~(1u << button);
        }
    }
    if (flags != macncheese_x_modifier_flags || buttons != macncheese_raw_buttons)
        macncheese_flush_raw_motion(display);
    macncheese_x_modifier_flags = flags;
    macncheese_raw_buttons = buttons;
}

static void macncheese_update_pointer_baseline(id display, void* event) {
    id platform = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        display, sel_registerName("windowForID:"), *(unsigned long*)((char*)event + 32));
    if (platform) {
        MacNCheesePoint point = {*(int*)((char*)event + 64), *(int*)((char*)event + 68)};
        point = ((MacNCheesePoint (*)(id, SEL, MacNCheesePoint))objc_msgSend)(
            platform, sel_registerName("transformPoint:"), point);
        ((void (*)(id, SEL, MacNCheesePoint))objc_msgSend)(
            platform, sel_registerName("setLastKnownCursorPosition:"), point);
    }
}

// X events of the event loop, before Darling sees them. Returns 1 when the
// event is consumed here.
static int macncheese_raw_mouse_x_event(id self, void* event) {
    if (!macncheese_raw_mouse_enabled())
        return 0;
    void* display = macncheese_x11_display_connection(self);
    if (!display)
        return 0;
    int wanted = macncheese_raw_mouse_wanted;
    static volatile int trace_events = -1;
    if (macncheese_pointer_grabbed && macncheese_env_cached("MACNCHEESE_TRACE_LOCK", &trace_events)) {
        static long traced;
        if (traced++ < 40) {
            write_str("[MacNCheese Lock] X event type=");
            print_num(*(int*)event);
            write_str(wanted ? " wanted=1" : " wanted=0");
            write_str(macncheese_raw_mouse_active ? " active=1\n" : " active=0\n");
        }
    }
    if (wanted != macncheese_raw_mouse_selected) {
        int selected = macncheese_raw_mouse_select(display, wanted);
        macncheese_raw_mouse_selected = wanted;
        macncheese_raw_mouse_active = wanted && selected;
        if (macncheese_raw_mouse_active)
            macncheese_drop_next_motion = 0;
        macncheese_raw_have_anchor = 0;
        macncheese_raw_events = macncheese_raw_posted = 0;
        macncheese_raw_motions_without_raw = 0;
        macncheese_raw_accelerated_streak = 0;
        static int reported;
        if (wanted && !reported) {
            reported = 1;
            write_str(selected ? "[MacNCheese Input] mouse lock uses raw motion (XInput 2)\n"
                               : "[MacNCheese Input] no raw motion, mouse lock uses pointer deltas\n");
        }
    }
    int type = *(int*)event;
    double dx, dy;
    int used_raw = 0;
    if (macncheese_raw_mouse_event(display, event, &dx, &dy, &used_raw)) {
        if (macncheese_raw_mouse_active && macncheese_pointer_grabbed && (dx != 0 || dy != 0)) {
            macncheese_raw_events++;
            macncheese_raw_motions_without_raw = 0;
            if (used_raw) {
                macncheese_raw_accelerated_streak = 0;
            } else if (++macncheese_raw_accelerated_streak == 50) {
                /* The server sends raw-motion cookies without device
                 * values: every delta here is pointer-accelerated, which
                 * bends fast flicks into spins. Stop pretending this is
                 * raw motion and fall back to pointer deltas openly. */
                write_str("[MacNCheese Input] raw motion has no device values, mouse lock uses pointer deltas\n");
                macncheese_flush_raw_motion(self);
                macncheese_raw_mouse_active = 0;
                macncheese_raw_mouse_select(display, 0);
                return 0;
            }
            macncheese_accumulate_raw_motion(self, dx, dy);
            static volatile int trace = -1;
            if (macncheese_env_cached("MACNCHEESE_TRACE_LOCK", &trace) && macncheese_raw_events <= 200) {
                write_str("[MacNCheese Lock] raw dx=");
                print_num((long long)dx);
                write_str(" dy=");
                print_num((long long)dy);
                write_str("\n");
            }
        }
        return 1;
    }
    if (type == 6 && macncheese_raw_mouse_active && macncheese_pointer_grabbed) {
        /* XMotionEvent: x/y at 64/68. The pointer stays near its anchor;
         * the game gets no pointer motion during the lock. */
        int x = *(int*)((char*)event + 64), y = *(int*)((char*)event + 68);
        // The pointer moves but raw events stopped: back to pointer deltas
        // for this lock, so the camera keeps working.
        if (++macncheese_raw_motions_without_raw > 25) {
            macncheese_flush_raw_motion(self);
            macncheese_raw_mouse_active = 0;
            macncheese_raw_mouse_select(display, 0);
            write_str("[MacNCheese Input] no raw motion arrived, mouse lock uses pointer deltas\n");
            return 0;
        }
        macncheese_raw_last_x = x;
        macncheese_raw_last_y = y;
        if (!macncheese_raw_have_anchor) {
            macncheese_raw_have_anchor = 1;
            macncheese_raw_start_x = macncheese_raw_anchor_x = x;
            macncheese_raw_start_y = macncheese_raw_anchor_y = y;
            id window = macncheese_lock_window();
            if (window) {
                // A lock that begins near the window edge: anchor inward, so
                // the pointer cannot leave the window before it drifts far
                // enough to be pulled back.
                MacNCheesePoint center = macncheese_window_center(window);
                int width = (int)(center.x * 2), height = (int)(center.y * 2);
                int margin = (int)MACNCHEESE_LOCK_RADIUS + 20;
                if (width > margin * 2) {
                    if (macncheese_raw_anchor_x < margin) macncheese_raw_anchor_x = margin;
                    if (macncheese_raw_anchor_x > width - margin) macncheese_raw_anchor_x = width - margin;
                } else {
                    macncheese_raw_anchor_x = width / 2;
                }
                if (height > margin * 2) {
                    if (macncheese_raw_anchor_y < margin) macncheese_raw_anchor_y = margin;
                    if (macncheese_raw_anchor_y > height - margin) macncheese_raw_anchor_y = height - margin;
                } else {
                    macncheese_raw_anchor_y = height / 2;
                }
            }
        }
        int ox = x - macncheese_raw_anchor_x, oy = y - macncheese_raw_anchor_y;
        if (ox > MACNCHEESE_LOCK_RADIUS || ox < -MACNCHEESE_LOCK_RADIUS ||
            oy > MACNCHEESE_LOCK_RADIUS || oy < -MACNCHEESE_LOCK_RADIUS ||
            (macncheese_raw_anchor_x != macncheese_raw_start_x && x == macncheese_raw_start_x && y == macncheese_raw_start_y) ||
            (macncheese_raw_anchor_y != macncheese_raw_start_y && x == macncheese_raw_start_x && y == macncheese_raw_start_y)) {
            macncheese_warp_on_display(display, -ox, -oy);
            macncheese_raw_last_x = macncheese_raw_anchor_x;
            macncheese_raw_last_y = macncheese_raw_anchor_y;
        }
        /* Keep Darling's previous position current even when its NSEvent is
         * suppressed, so releasing lock or falling back cannot jump. */
        macncheese_update_pointer_baseline(self, event);
        return 1;
    }
    return 0;
}

static int macncheese_apply_mouse_capture(int grab) {
    if (grab == macncheese_pointer_grabbed) {
        if (grab && !__atomic_load_n(&macncheese_cursor_worker_ready, __ATOMIC_ACQUIRE))
            macncheese_start_xfixes_worker();
        return 0;
    }
    if (__sync_add_and_fetch(&macncheese_associate_mouse_count, 1) <= 20)
        write_str(grab ? "[MacNCheese Input] mouse lock on\n"
                       : "[MacNCheese Input] mouse lock off\n");
    macncheese_drop_warp_motion = 0;
    macncheese_raw_mouse_wanted = grab;
    if (grab) {
        id window = macncheese_lock_window();
        SEL screen_selector = sel_registerName("mouseLocation");
        id event_class = (id)objc_getClass("NSEvent");
        macncheese_frozen_screen_location = orig_event_mouse_location
            ? orig_event_mouse_location(event_class, screen_selector)
            : ((MacNCheesePoint (*)(id, SEL))objc_msgSend)(event_class, screen_selector);
        if (window)
            macncheese_frozen_window_location = macncheese_real_window_mouse_location(window);
    }
    if (grab) {
        // The pointer stays where the button was pressed. Recentering starts
        // from there; only a press close to the window edge moves the anchor
        // inward, and that first move waits for the first motion event, when
        // the cursor is surely hidden (a warp before that is not emulated by
        // Xwayland and the camera would jump).
        id window = macncheese_lock_window();
        macncheese_lock_anchor = macncheese_frozen_window_location;
        macncheese_lock_anchor_pending = 0;
        if (window) {
            MacNCheesePoint center = macncheese_window_center(window);
            double margin = MACNCHEESE_LOCK_RADIUS + 20;
            double width = center.x * 2, height = center.y * 2;
            MacNCheesePoint anchor = macncheese_lock_anchor;
            if (width > margin * 2) {
                if (anchor.x < margin) anchor.x = margin;
                if (anchor.x > width - margin) anchor.x = width - margin;
            } else {
                anchor.x = center.x;
            }
            if (height > margin * 2) {
                if (anchor.y < margin) anchor.y = margin;
                if (anchor.y > height - margin) anchor.y = height - margin;
            } else {
                anchor.y = center.y;
            }
            macncheese_lock_anchor_pending = anchor.x != macncheese_lock_anchor.x ||
                                           anchor.y != macncheese_lock_anchor.y;
            macncheese_lock_anchor = anchor;
        }
        unsigned long handle = macncheese_native_window_handle(window);
        __atomic_store_n(&macncheese_cursor_lock_window, handle, __ATOMIC_RELEASE);
        macncheese_pointer_grabbed = 1;
        macncheese_set_x_cursor_hidden(1);
    } else {
        // Put the pointer back where the button was pressed, while it is
        // still hidden, then show it.
        macncheese_pointer_grabbed = 0;
        if (macncheese_raw_mouse_active && macncheese_raw_have_anchor) {
            // Darling saw no pointer motion during the lock; the event loop
            // did (X coordinates, y down; the warp takes Cocoa's y up).
            macncheese_warp_pointer_by(macncheese_raw_start_x - macncheese_raw_last_x,
                                     macncheese_raw_last_y - macncheese_raw_start_y);
        }
        // In delta mode, no restore warp: the pointer already sits near the anchor
        // (recentered within 100px), and Darling's mouseLocationOutsideOfEventStream
        // speaks a broken coordinate space that threw the cursor at the screen edge
        // and turned the camera. Unhide it where it is.
        macncheese_drop_warp_motion = 0;
        macncheese_set_x_cursor_hidden(0);
    }
    return 0;
}
static int macncheese_CGAssociateMouseAndMouseCursorPosition(unsigned int connected) {
    if (macncheese_wayland_enabled())
        return macncheese_wayland_associate(connected);
    /* Capture intent survives focus loss. An explicit unlock while suspended
     * still cancels it, even though capture is already inactive. */
    __atomic_store_n(&macncheese_mouse_lock_requested, !connected, __ATOMIC_RELEASE);
    return macncheese_apply_mouse_capture(!connected &&
        __atomic_load_n(&macncheese_input_focused, __ATOMIC_ACQUIRE));
}
DYLD_INTERPOSE(macncheese_CGAssociateMouseAndMouseCursorPosition,
               CGAssociateMouseAndMouseCursorPosition);

static int macncheese_CGWarpMouseCursorPosition(MacNCheesePoint position) {
    extern int macncheese_wayland_warp(MacNCheesePoint);
    if (macncheese_wayland_enabled())
        return macncheese_wayland_warp(position);
    if (macncheese_pointer_grabbed)
        return 0; // Roblox warps every frame during the lock
    return CGWarpMouseCursorPosition(position);
}
DYLD_INTERPOSE(macncheese_CGWarpMouseCursorPosition, CGWarpMouseCursorPosition);

// Returns 1 if the motion event must be dropped (it only reflects our warp).
static int macncheese_filter_locked_motion_inner(id event, double dx, double dy);
static double (*orig_mouse_event_delta_x)(id, SEL);
static double (*orig_mouse_event_delta_y)(id, SEL);
// MACNCHEESE_TRACE_LOCK=1: log every motion event seen during mouse lock.
static void macncheese_trace_lock_motion(id event, double dx, double dy, const char* action) {
    static volatile int enabled = -1;
    if (!macncheese_env_cached("MACNCHEESE_TRACE_LOCK", &enabled))
        return;
    MacNCheesePoint location = macncheese_real_event_location(event);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
    write_str("[MacNCheese Lock] type=");
    print_num((long long)type);
    write_str(" dx=");
    print_num((long long)dx);
    write_str(" dy=");
    print_num((long long)dy);
    write_str(" at=");
    print_num((long long)location.x);
    write_str(",");
    print_num((long long)location.y);
    write_str(" ");
    write_str(action);
    write_str("\n");
}

static int macncheese_filter_locked_motion(id event) {
    if (!macncheese_pointer_grabbed || macncheese_raw_mouse_active)
        return 0;
    // Raw Darling deltas (Cocoa axes), without sign flip or sensitivity.
    SEL delta_x = sel_registerName("deltaX"), delta_y = sel_registerName("deltaY");
    double dx = orig_mouse_event_delta_x ? orig_mouse_event_delta_x(event, delta_x)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_x);
    double dy = orig_mouse_event_delta_y ? orig_mouse_event_delta_y(event, delta_y)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_y);
    int dropping = macncheese_drop_warp_motion;
    int dropped = macncheese_filter_locked_motion_inner(event, dx, dy);
    macncheese_trace_lock_motion(event, dx, dy,
                               dropped ? "DROPPED" : (dropping && !macncheese_drop_warp_motion ? "" :
                               (macncheese_drop_warp_motion && !dropping ? "RECENTER" : "")));
    return dropped;
}

static int macncheese_filter_locked_motion_inner(id event, double dx, double dy) {
    if (macncheese_drop_warp_motion) {
        double ex = macncheese_expected_warp_delta.x, ey = macncheese_expected_warp_delta.y;
        double diff_sq = (dx - ex) * (dx - ex) + (dy - ey) * (dy - ey);
        double ex_sq = ex * ex + ey * ey;
        // The warp was a recentering jump of ~100px. If this motion carries the warp's jump
        // (within generous tolerance, or in the warp direction with >20% magnitude), drop it
        // so it never leaks to the camera.
        int is_warp = (diff_sq < (0.64 * ex_sq + 16.0)) ||
                      (ex != 0 && (dx * ex > 0) && (dx * dx >= 0.04 * ex * ex)) ||
                      (ey != 0 && (dy * ey > 0) && (dy * dy >= 0.04 * ey * ey));
        if (is_warp) {
            macncheese_drop_warp_motion = 0;
            return 1;
        }
        // After 2 events, the warp has surely arrived or passed. Never wait 8 events,
        // which stalled recentering and let the pointer reach the screen edge.
        if (++macncheese_warp_wait_events > 2)
            macncheese_drop_warp_motion = 0;
    }
    if (!macncheese_drop_warp_motion) {
        MacNCheesePoint location = macncheese_real_event_location(event);
        double ox = location.x - macncheese_lock_anchor.x, oy = location.y - macncheese_lock_anchor.y;
        if (macncheese_lock_anchor_pending) {
            macncheese_lock_anchor_pending = 0;
            macncheese_warp_pointer_by(-ox, -oy);
        } else if (ox > MACNCHEESE_LOCK_RADIUS || ox < -MACNCHEESE_LOCK_RADIUS ||
                   oy > MACNCHEESE_LOCK_RADIUS || oy < -MACNCHEESE_LOCK_RADIUS) {
            macncheese_warp_pointer_by(-ox, -oy);
        }
    }
    return 0;
}

// macOS reports mouse motion deltaY positive downward; Darling computes it in
// Cocoa window coordinates (positive upward). Scroll events keep their sign.
// MACNCHEESE_MOUSE_SENSITIVITY scales camera motion during mouse lock.
static double macncheese_mouse_sensitivity(void) {
    static double value = -1;
    if (value < 0) {
        const char* text = getenv("MACNCHEESE_MOUSE_SENSITIVITY");
        double parsed = 0;
        if (text && text[0]) {
            double scale = 1;
            int fraction = 0;
            for (const char* c = text; *c; c++) {
                if (*c >= '0' && *c <= '9') {
                    if (fraction) { scale /= 10; parsed += (*c - '0') * scale; }
                    else parsed = parsed * 10 + (*c - '0');
                } else if (*c == '.' || *c == ',') {
                    fraction = 1;
                }
            }
        }
        value = parsed > 0.05 && parsed < 20 ? parsed : 1.0;
    }
    return value;
}
// MACNCHEESE_SCROLL_SENSITIVITY scales wheel delta for UI menus and scrolling.
static double macncheese_scroll_sensitivity(void) {
    static double value = -1;
    if (value < 0) {
        const char* text = getenv("MACNCHEESE_SCROLL_SENSITIVITY");
        double parsed = 0;
        if (text && text[0]) {
            double scale = 1;
            int fraction = 0;
            for (const char* c = text; *c; c++) {
                if (*c >= '0' && *c <= '9') {
                    if (fraction) { scale /= 10; parsed += (*c - '0') * scale; }
                    else parsed = parsed * 10 + (*c - '0');
                } else if (*c == '.' || *c == ',') {
                    fraction = 1;
                }
            }
        }
        value = parsed > 0.1 && parsed < 30 ? parsed : 1.5;
    }
    return value;
}
static int macncheese_is_motion_type(id event) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    return type == 5 || type == 6 || type == 7 || type == 27;
}
static int macncheese_is_scroll_type(id event) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    return type == 22; // NSScrollWheel
}
static double (*orig_mouse_event_delta_x)(id, SEL) = 0;
static double hooked_mouse_event_delta_x(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_x(self, cmd);
    if ((macncheese_pointer_grabbed || macncheese_wayland_captured()) && macncheese_is_motion_type(self))
        return delta * macncheese_mouse_sensitivity();
    if (macncheese_is_scroll_type(self))
        return delta * macncheese_scroll_sensitivity();
    return delta;
}
static double (*orig_mouse_event_delta_y)(id, SEL) = 0;
static double hooked_mouse_event_delta_y(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_y(self, cmd);
    if (macncheese_is_scroll_type(self))
        return delta * macncheese_scroll_sensitivity();
    if (!macncheese_is_motion_type(self))
        return delta;
    delta = -delta;
    return (macncheese_pointer_grabbed || macncheese_wayland_captured()) ? delta * macncheese_mouse_sensitivity() : delta;
}

// Scroll wheel APIs missing from Darling's NSEvent. X11 wheels report coarse
// line deltas; macOS reports pixels for the same events (about 10 px per
// line). Roblox's Universal App menu scrolls on the pixel deltas only, so
// with line-scale values the wheel appeared dead there.
#define MACNCHEESE_SCROLL_LINE_PIXELS 25.0
static MacNCheeseBool event_has_precise_scrolling_deltas(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 1;
}
static MacNCheeseBool event_is_direction_inverted(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static double event_scrolling_delta_x(id self, SEL cmd) {
    (void)cmd;
    double d = ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaX"));
    return d * MACNCHEESE_SCROLL_LINE_PIXELS;
}
static double event_scrolling_delta_y(id self, SEL cmd) {
    (void)cmd;
    double d = ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaY"));
    return d * MACNCHEESE_SCROLL_LINE_PIXELS;
}

// Darling's -[X11Cursor initWithImage:hotPoint:] copies each pixel row with a
// wrong source offset, so custom cursors show shifted rows and bytes read past
// the bitmap (the bright pink/blue fringe). Rebuild the Xcursor image here.
typedef struct {
    unsigned int version, size, width, height, xhot, yhot, delay;
    unsigned int* pixels;
} MacNCheeseXcursorImage;
typedef struct objc_ivar* Ivar;
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);
extern void* objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void*);
extern void* CGColorSpaceCreateDeviceRGB(void);
extern void CGColorSpaceRelease(void*);
extern void* CGBitmapContextCreate(void*, unsigned long, unsigned long,
                                   unsigned long, unsigned long, void*,
                                   unsigned int);
extern void* CGBitmapContextGetData(void*);
extern unsigned long CGBitmapContextGetBytesPerRow(void*);
extern void CGContextRelease(void*);

extern unsigned long CGImageGetWidth(void*);
extern unsigned long CGImageGetHeight(void*);
extern unsigned long CGImageGetBitsPerComponent(void*);
extern unsigned long CGImageGetBitsPerPixel(void*);
extern unsigned long CGImageGetBytesPerRow(void*);
extern unsigned int CGImageGetBitmapInfo(void*);
extern void* CGImageGetDataProvider(void*);
extern void* CGDataProviderCopyData(void*);
extern const unsigned char* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(const void*);

// Read the cursor image's own pixels instead of drawing it through Darling,
// whose compositing corrupts channels of semi-transparent pixels. Returns an
// Xcursor-style premultiplied ARGB buffer (caller frees), or 0 if the format
// is not a plain 8-bit RGB(A) layout.
static unsigned int* macncheese_cursor_pixels_from_image(
    id image, unsigned long* width_out, unsigned long* height_out) {
    id reps = ((id (*)(id, SEL))objc_msgSend)(image, sel_registerName("representations"));
    unsigned long rep_count = reps
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(reps, sel_registerName("count")) : 0;
    void* cg_image = 0;
    for (unsigned long index = 0; index < rep_count && !cg_image; index++) {
        id rep = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            reps, sel_registerName("objectAtIndex:"), index);
        if (((MacNCheeseBool (*)(id, SEL, SEL))objc_msgSend)(
                rep, sel_registerName("respondsToSelector:"), sel_registerName("CGImage")))
            cg_image = ((void* (*)(id, SEL))objc_msgSend)(rep, sel_registerName("CGImage"));
    }
    if (!cg_image)
        return 0;
    unsigned long width = CGImageGetWidth(cg_image);
    unsigned long height = CGImageGetHeight(cg_image);
    unsigned long bits_per_pixel = CGImageGetBitsPerPixel(cg_image);
    unsigned long bytes_per_row = CGImageGetBytesPerRow(cg_image);
    unsigned int info = CGImageGetBitmapInfo(cg_image);
    unsigned int alpha_info = info & 0x1FU;
    unsigned int byte_order = info & 0x7000U;
    static volatile long described;
    if (__sync_add_and_fetch(&described, 1) <= 4) {
        write_str("[MacNCheese Cursor] source ");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(" bpp=");
        print_num((long long)bits_per_pixel);
        write_str(" bpc=");
        print_num((long long)CGImageGetBitsPerComponent(cg_image));
        write_str(" alpha-info=");
        print_num(alpha_info);
        write_str(" byte-order=");
        print_hex(byte_order);
        write_str("\n");
    }
    if (!width || !height || width > 512 || height > 512 ||
        CGImageGetBitsPerComponent(cg_image) != 8 ||
        (bits_per_pixel != 32 && bits_per_pixel != 24) ||
        (byte_order != 0 && byte_order != 0x2000U && byte_order != 0x4000U))
        return 0;
    void* provider = CGImageGetDataProvider(cg_image);
    void* data = provider ? CGDataProviderCopyData(provider) : 0;
    if (!data)
        return 0;
    const unsigned char* bytes = CFDataGetBytePtr(data);
    if ((unsigned long)CFDataGetLength(data) < bytes_per_row * (height - 1) +
                                                   width * (bits_per_pixel / 8)) {
        CFRelease(data);
        return 0;
    }
    unsigned int* pixels = (unsigned int*)malloc(width * height * 4);
    if (!pixels) {
        CFRelease(data);
        return 0;
    }
    int alpha_first = alpha_info == 2 || alpha_info == 4 || alpha_info == 6;
    int has_alpha = alpha_info >= 1 && alpha_info <= 4;
    int premultiplied = alpha_info == 1 || alpha_info == 2;
    for (unsigned long row = 0; row < height; row++) {
        const unsigned char* source = bytes + row * bytes_per_row;
        for (unsigned long column = 0; column < width; column++) {
            unsigned int c[4] = {0, 0, 0, 0};
            if (bits_per_pixel == 24) {
                c[0] = source[column * 3];
                c[1] = source[column * 3 + 1];
                c[2] = source[column * 3 + 2];
                c[3] = 255;
            } else {
                const unsigned char* pixel = source + column * 4;
                // Logical component order, most significant first.
                unsigned char word[4];
                if (byte_order == 0x2000U) {
                    word[0] = pixel[3]; word[1] = pixel[2];
                    word[2] = pixel[1]; word[3] = pixel[0];
                } else {
                    word[0] = pixel[0]; word[1] = pixel[1];
                    word[2] = pixel[2]; word[3] = pixel[3];
                }
                if (alpha_first) {
                    c[3] = word[0]; c[0] = word[1]; c[1] = word[2]; c[2] = word[3];
                } else {
                    c[0] = word[0]; c[1] = word[1]; c[2] = word[2]; c[3] = word[3];
                }
                if (!has_alpha)
                    c[3] = 255;
            }
            if (!premultiplied) {
                for (int channel = 0; channel < 3; channel++)
                    c[channel] = c[channel] * c[3] / 255;
            }
            pixels[row * width + column] =
                (c[3] << 24) | (c[0] << 16) | (c[1] << 8) | c[2];
        }
    }
    CFRelease(data);
    *width_out = width;
    *height_out = height;
    return pixels;
}

static id (*orig_x11_cursor_init_image)(id, SEL, id, MacNCheesePoint) = 0;
static id hooked_x11_cursor_init_image(id self, SEL cmd, id image,
                                       MacNCheesePoint hot) {
    MacNCheeseXcursorImage* (*image_create)(int, int) =
        (MacNCheeseXcursorImage* (*)(int, int))
            dlsym(RTLD_DEFAULT, "XcursorImageCreate");
    void (*image_destroy)(MacNCheeseXcursorImage*) =
        (void (*)(MacNCheeseXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageDestroy");
    unsigned long (*load_cursor)(void*, const MacNCheeseXcursorImage*) =
        (unsigned long (*)(void*, const MacNCheeseXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageLoadCursor");
    Ivar cursor_ivar = class_getInstanceVariable(object_getClass(self), "_cursor");
    MacNCheeseSize size = image
        ? ((MacNCheeseSize (*)(id, SEL))objc_msgSend)(image, sel_registerName("size"))
        : (MacNCheeseSize){0, 0};
    unsigned long width = (unsigned long)size.width;
    unsigned long height = (unsigned long)size.height;
    if (!image_create || !image_destroy || !load_cursor || !cursor_ivar ||
        !width || !height || width > 512 || height > 512)
        return orig_x11_cursor_init_image(self, cmd, image, hot);

    unsigned long source_width = 0, source_height = 0;
    unsigned int* source_pixels =
        macncheese_cursor_pixels_from_image(image, &source_width, &source_height);
    if (source_pixels) {
        id direct_display_object = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
        void* direct_display = direct_display_object
            ? ((void* (*)(id, SEL))objc_msgSend)(direct_display_object,
                                                  sel_registerName("display"))
            : 0;
        MacNCheeseXcursorImage* direct = direct_display
            ? image_create((int)source_width, (int)source_height) : 0;
        if (direct) {
            for (unsigned long index = 0; index < source_width * source_height; index++)
                direct->pixels[index] = source_pixels[index];
            // The hot spot is given in image points; the bitmap may be larger.
            double scale_x = (double)source_width / (double)width;
            double scale_y = (double)source_height / (double)height;
            double hot_x = hot.x * scale_x, hot_y = hot.y * scale_y;
            direct->xhot = hot_x < 0 ? 0 : (hot_x >= source_width ? source_width - 1 : (unsigned int)hot_x);
            direct->yhot = hot_y < 0 ? 0 : (hot_y >= source_height ? source_height - 1 : (unsigned int)hot_y);
            unsigned long direct_cursor = load_cursor(direct_display, direct);
            image_destroy(direct);
            if (direct_cursor) {
                free(source_pixels);
                *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = direct_cursor;
                return self;
            }
        }
        free(source_pixels);
    }

    id display_object = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
    void* display = display_object
        ? ((void* (*)(id, SEL))objc_msgSend)(display_object, sel_registerName("display"))
        : 0;
    MacNCheeseXcursorImage* ximage = display ? image_create((int)width, (int)height) : 0;
    void* color_space = ximage ? CGColorSpaceCreateDeviceRGB() : 0;
    // Premultiplied ARGB in host byte order, the XcursorPixel format.
    void* bitmap = color_space
        ? CGBitmapContextCreate(0, width, height, 8, 0, color_space,
                                2U /* PremultipliedFirst */ | 0x2000U /* 32Little */)
        : 0;
    if (color_space)
        CGColorSpaceRelease(color_space);
    if (!bitmap) {
        if (ximage)
            image_destroy(ximage);
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    }

    void* pool = objc_autoreleasePoolPush();
    id context_class = (id)objc_getClass("NSGraphicsContext");
    id graphics = ((id (*)(id, SEL, void*, MacNCheeseBool))objc_msgSend)(
        context_class, sel_registerName("graphicsContextWithGraphicsPort:flipped:"),
        bitmap, 0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("saveGraphicsState"));
    ((void (*)(id, SEL, id))objc_msgSend)(
        context_class, sel_registerName("setCurrentContext:"), graphics);
    MacNCheeseRect destination = {{0, 0}, {(double)width, (double)height}};
    MacNCheeseRect whole_image = {{0, 0}, {0, 0}};
    ((void (*)(id, SEL, MacNCheeseRect, MacNCheeseRect, unsigned long, double))objc_msgSend)(
        image, sel_registerName("drawInRect:fromRect:operation:fraction:"),
        destination, whole_image, 1UL /* NSCompositeCopy */, 1.0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("restoreGraphicsState"));
    objc_autoreleasePoolPop(pool);

    const unsigned char* rows = (const unsigned char*)CGBitmapContextGetData(bitmap);
    unsigned long bytes_per_row = CGBitmapContextGetBytesPerRow(bitmap);
    for (unsigned long row = 0; row < height; row++) {
        const unsigned int* source = (const unsigned int*)(rows + row * bytes_per_row);
        for (unsigned long column = 0; column < width; column++)
            ximage->pixels[row * width + column] = source[column];
    }
    CGContextRelease(bitmap);

    // Xcursor expects premultiplied ARGB. Darling's image drawing can leave
    // straight alpha, which shows up as a bright fringe on soft edges. A
    // channel above its alpha is impossible when premultiplied, so use that
    // to detect the format and premultiply only in that case.
    unsigned long pixel_count = width * height;
    int straight_alpha = 0;
    for (unsigned long index = 0; index < pixel_count && !straight_alpha; index++) {
        unsigned int pixel = ximage->pixels[index];
        unsigned int alpha = pixel >> 24;
        if (((pixel >> 16) & 255) > alpha || ((pixel >> 8) & 255) > alpha ||
            (pixel & 255) > alpha)
            straight_alpha = 1;
    }
    if (straight_alpha) {
        for (unsigned long index = 0; index < pixel_count; index++) {
            unsigned int pixel = ximage->pixels[index];
            unsigned int alpha = pixel >> 24;
            unsigned int red = ((pixel >> 16) & 255) * alpha / 255;
            unsigned int green = ((pixel >> 8) & 255) * alpha / 255;
            unsigned int blue = (pixel & 255) * alpha / 255;
            ximage->pixels[index] = (alpha << 24) | (red << 16) | (green << 8) | blue;
        }
    }
    static volatile long dumped_cursors;
    long dump_index = __sync_add_and_fetch(&dumped_cursors, 1) - 1;
    if (dump_index < 4) {
        write_str("[MacNCheese Cursor] #");
        print_num(dump_index);
        write_str(" size=");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(straight_alpha ? " straight-alpha (premultiplied now)\n"
                                 : " already premultiplied\n");
    }

    ximage->xhot = hot.x < 0 ? 0 : (hot.x >= width ? width - 1 : (unsigned int)hot.x);
    ximage->yhot = hot.y < 0 ? 0 : (hot.y >= height ? height - 1 : (unsigned int)hot.y);
    unsigned long cursor = load_cursor(display, ximage);
    image_destroy(ximage);
    if (!cursor)
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = cursor;

    return self;
}

/* Creating a cursor does not select it. This backend setter is reached by
 * NSCursor set/push/pop, hide/unhide and cursor-rectangle resets, so both
 * image construction paths and named/blank cursors follow the same policy. */
static void (*orig_x11_display_set_cursor)(id, SEL, id);
static void hooked_x11_display_set_cursor(id self, SEL cmd, id cursor) {
    unsigned long handle = macncheese_native_window_handle(macncheese_lock_window());
    orig_x11_display_set_cursor(self, cmd, cursor);
    if (!handle)
        return;
    Ivar cursor_ivar = cursor ? class_getInstanceVariable(object_getClass(cursor), "_cursor") : 0;
    if (cursor && !cursor_ivar)
        return;
    unsigned long selected_cursor = cursor
        ? *(unsigned long*)((char*)cursor + ivar_getOffset(cursor_ivar)) : 0;
    if (cursor)
        ((id (*)(id, SEL))objc_msgSend)(cursor, sel_registerName("retain"));
    macncheese_lock(&macncheese_window_cursor_lock);
    id previous = (id)macncheese_window_cursor_selection.owner;
    int changed = macncheese_cursor_selection_set(&macncheese_window_cursor_selection,
                                                handle, selected_cursor, cursor);
    int pending = macncheese_window_cursor_selection.dirty;
    macncheese_unlock(&macncheese_window_cursor_lock);
    id release = changed ? previous : cursor;
    if (release)
        ((void (*)(id, SEL))objc_msgSend)(release, sel_registerName("release"));
    if (pending) {
        macncheese_start_xfixes_worker();
        if (__atomic_load_n(&macncheese_cursor_worker_ready, __ATOMIC_ACQUIRE))
            macncheese_wake_worker(macncheese_cursor_wake[1]);
    }
}

// Darling stubs +[NSEvent addLocalMonitorForEventsMatchingMask:handler:].
// Roblox installs local monitors for its input, so implement them the macOS
// way: -[NSApplication sendEvent:] passes each matching event to the handlers
// first; a handler may replace the event or return nil to consume it.
struct MacNCheeseBlock {
    void* isa;
    int flags;
    int reserved;
    id (*invoke)(void*, id);
};
extern void* _Block_copy(const void*);
extern void _Block_release(const void*);
#define MACNCHEESE_MAX_MONITORS 32
static struct {
    unsigned long long mask;
    struct MacNCheeseBlock* block;
} macncheese_monitors[MACNCHEESE_MAX_MONITORS];
static volatile int macncheese_monitor_lock;

static id event_add_local_monitor(id cls, SEL cmd, unsigned long long mask,
                                  void* handler) {
    (void)cls; (void)cmd;
    if (!handler)
        return 0;
    struct MacNCheeseBlock* block = (struct MacNCheeseBlock*)_Block_copy(handler);
    while (!__sync_bool_compare_and_swap(&macncheese_monitor_lock, 0, 1)) {}
    int stored = 0;
    for (int index = 0; index < MACNCHEESE_MAX_MONITORS && !stored; index++) {
        if (!macncheese_monitors[index].block) {
            macncheese_monitors[index].mask = mask;
            macncheese_monitors[index].block = block;
            stored = 1;
        }
    }
    __sync_lock_release(&macncheese_monitor_lock);
    write_str("[MacNCheese Input] addLocalMonitorForEventsMatchingMask mask=");
    print_hex(mask);
    write_str(stored ? "\n" : " (table full, ignored)\n");
    if (!stored) {
        _Block_release(block);
        return 0;
    }
    return (id)block;
}

static void event_remove_monitor(id cls, SEL cmd, id monitor) {
    (void)cls; (void)cmd;
    if (!monitor)
        return;
    while (!__sync_bool_compare_and_swap(&macncheese_monitor_lock, 0, 1)) {}
    for (int index = 0; index < MACNCHEESE_MAX_MONITORS; index++) {
        if (macncheese_monitors[index].block == (struct MacNCheeseBlock*)monitor) {
            macncheese_monitors[index].block = 0;
            macncheese_monitors[index].mask = 0;
            __sync_lock_release(&macncheese_monitor_lock);
            _Block_release(monitor);
            return;
        }
    }
    __sync_lock_release(&macncheese_monitor_lock);
}

// Keyboard state for CGEventSourceKeyState, which Darling lacks and Roblox
// polls in game. Built from the key events AppKit dispatches, and cleared
// when the window loses the keyboard (hooked_post_x_event): X sends the key
// releases to whoever has it then, so a key held during Alt+Tab stayed
// "down" (the character kept walking).
static volatile unsigned char macncheese_key_down[128];
static void macncheese_track_key_event(id event, unsigned long type) {
    if (type != 10 && type != 11 && type != 12) // keyDown, keyUp, flagsChanged
        return;
    unsigned short key = ((unsigned short (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("keyCode"));
    if (key >= 128)
        return;
    if (type != 12) {
        macncheese_key_down[key] = type == 10;
        return;
    }
    unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("modifierFlags"));
    unsigned long bit = 0;
    switch (key) {
    case 56: case 60: bit = 1UL << 17; break; // shift
    case 59: case 62: bit = 1UL << 18; break; // control
    case 58: case 61: bit = 1UL << 19; break; // option
    case 55: case 54: bit = 1UL << 20; break; // command
    case 57: bit = 1UL << 16; break;          // caps lock
    default: return;
    }
    macncheese_key_down[key] = (flags & bit) != 0;
}
unsigned char CGEventSourceKeyState(int state_id, unsigned short key) {
    (void)state_id;
    return key < 128 ? macncheese_key_down[key] : 0;
}

static int macncheese_trace_keys_enabled(void);
static void (*orig_app_send_event)(id, SEL, id) = 0;
static void hooked_app_send_event(id self, SEL cmd, id event) {
    if (event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        macncheese_track_key_event(event, type);
        if ((type == 10 || type == 11) && macncheese_trace_keys_enabled()) {
            write_str(type == 10 ? "[MacNCheese Keys] game keyDown code=" : "[MacNCheese Keys] game keyUp   code=");
            print_num(((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode")));
            write_str(((signed char (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat")) ? " repeat\n" : "\n");
        }
        if ((type == 5 || type == 6 || type == 7 || type == 27) &&
            macncheese_filter_locked_motion(event))
            return;
        unsigned long long event_mask = type < 64 ? 1ULL << type : 0;
        struct MacNCheeseBlock* handlers[MACNCHEESE_MAX_MONITORS];
        int handler_count = 0;
        while (!__sync_bool_compare_and_swap(&macncheese_monitor_lock, 0, 1)) {}
        for (int index = 0; index < MACNCHEESE_MAX_MONITORS; index++) {
            if (macncheese_monitors[index].block &&
                (macncheese_monitors[index].mask & event_mask))
                // A reference of our own: a handler may remove a monitor
                // (and free its block) while the others still run.
                handlers[handler_count++] = (struct MacNCheeseBlock*)_Block_copy(macncheese_monitors[index].block);
        }
        __sync_lock_release(&macncheese_monitor_lock);
        for (int index = 0; index < handler_count; index++) {
            if (event)
                event = handlers[index]->invoke(handlers[index], event);
            _Block_release(handlers[index]);
        }
        if (!event)
            return;
    }
    orig_app_send_event(self, cmd, event);
}

// Darling drops pointer motion unless the window accepts mouse-moved events.
// On macOS Roblox receives motion through tracking areas instead, which
// Darling does not deliver here, so the Roblox window always accepts them.
static MacNCheeseBool (*orig_window_accepts_mouse_moved)(id, SEL) = 0;
static MacNCheeseBool hooked_window_accepts_mouse_moved(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 1;
}

// The launcher ends the session as soon as the user asks to quit (the quit
// sentinel; see macncheese_write_quit_sentinel). Closing the game window is
// that ask: Roblox's own teardown would otherwise keep the process alive
// for seconds after the window is gone, with the launcher still waiting.
static void (*orig_window_close)(id, SEL) = 0;
static void hooked_window_close(id self, SEL cmd) {
    const char* class_name = object_getClassName(self);
    if (class_name && ascii_strings_equal(class_name, "RBXWindow"))
        macncheese_write_quit_sentinel();
    if (orig_window_close)
        orig_window_close(self, cmd);
}
static void (*orig_window_perform_close)(id, SEL, id) = 0;
static void hooked_window_perform_close(id self, SEL cmd, id sender) {
    const char* class_name = object_getClassName(self);
    if (class_name && ascii_strings_equal(class_name, "RBXWindow"))
        macncheese_write_quit_sentinel();
    if (orig_window_perform_close)
        orig_window_perform_close(self, cmd, sender);
}

// MACNCHEESE_TRACE_EVENTS=1: log mouse events as AppKit dispatches them.
// Movement is sampled; button, enter/exit and scroll events are all logged.
static void (*orig_window_send_event)(id, SEL, id) = 0;
static volatile long macncheese_traced_motion_events;
static void hooked_window_send_event(id self, SEL cmd, id event) {
    static volatile int enabled = -1;
    macncheese_env_cached("MACNCHEESE_TRACE_EVENTS", &enabled);
    if (enabled && event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        int is_button = type == 1 || type == 2 || type == 3 || type == 4 ||
                        type == 25 || type == 26;
        int is_motion = type == 5 || type == 6 || type == 7 || type == 27;
        int is_other = type == 8 || type == 9 || type == 22;
        int log = is_button || is_other;
        if (is_motion) {
            long count = __sync_add_and_fetch(&macncheese_traced_motion_events, 1);
            log = count <= 20 || count % 50 == 0;
        }
        if (log) {
            MacNCheesePoint location = ((MacNCheesePoint (*)(id, SEL))objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            write_str("[MacNCheese Event] type=");
            print_num((long long)type);
            write_str(" window=");
            write_str(object_getClassName(self));
            write_str(" x=");
            print_num((long long)location.x);
            write_str(" y=");
            print_num((long long)location.y);
            if (is_button) {
                write_str(" button=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("buttonNumber")));
                write_str(" clicks=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("clickCount")));
                id content = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("contentView"));
                id superview = content ? ((id (*)(id, SEL))objc_msgSend)(
                    content, sel_registerName("superview")) : 0;
                id root = superview ? superview : content;
                id hit = root ? ((id (*)(id, SEL, MacNCheesePoint))objc_msgSend)(
                    root, sel_registerName("hitTest:"), location) : 0;
                write_str(" hit=");
                write_str(hit ? object_getClassName(hit) : "(nil)");
                id responder = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("firstResponder"));
                write_str(" first-responder=");
                write_str(responder ? object_getClassName(responder) : "(nil)");
            }
            if (is_motion) {
                write_str(" sample=");
                print_num(macncheese_traced_motion_events);
            }
            write_str("\n");
        }
    }
    orig_window_send_event(self, cmd, event);
}

// Log where Roblox tries to send the user: an in-app WKWebView page or an
// external URL. Darling's WebKit is a stub, so both currently show nothing.
static void macncheese_log_url(const char* prefix, id url) {
    id text = url ? ((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")) : 0;
    const char* utf8 = text ? ((const char* (*)(id, SEL))objc_msgSend)(
                                  text, sel_registerName("UTF8String")) : 0;
    write_str(prefix);
    write_str(utf8 ? utf8 : "(nil)");
    write_str("\n");
}
static id (*orig_web_view_init)(id, SEL, MacNCheeseRect, id) = 0;
static id hooked_web_view_init(id self, SEL cmd, MacNCheeseRect frame, id configuration) {
    write_str("[MacNCheese Web] WKWebView initWithFrame:configuration:\n");
    return orig_web_view_init(self, cmd, frame, configuration);
}
static id (*orig_web_view_load_request)(id, SEL, id) = 0;
static id hooked_web_view_load_request(id self, SEL cmd, id request) {
    id url = request ? ((id (*)(id, SEL))objc_msgSend)(request, sel_registerName("URL")) : 0;
    macncheese_log_url("[MacNCheese Web] WKWebView loadRequest: ", url);
    return orig_web_view_load_request(self, cmd, request);
}
// Links open in the launcher's browser window when it is there
// (web_bridge.m); roblox:// links go to the client's own URL handler.
extern int macncheese_web_open_url(id url);
static MacNCheeseBool (*orig_workspace_open_url)(id, SEL, id) = 0;
static MacNCheeseBool hooked_workspace_open_url(id self, SEL cmd, id url) {
    if (url && macncheese_web_open_url(url)) {
        write_str("[MacNCheese Web] NSWorkspace openURL: shown by the launcher\n");
        return 1;
    }
    MacNCheeseBool result = orig_workspace_open_url(self, cmd, url);
    macncheese_log_url(result ? "[MacNCheese Web] NSWorkspace openURL: (ok) "
                            : "[MacNCheese Web] NSWorkspace openURL: (failed) ", url);
    return result;
}

// Darling stores the X11 button number (left 1, middle 2, right 3, back 8,
// forward 9) in -[NSEvent buttonNumber]. macOS numbers them left 0, right 1,
// middle 2, then 3 and 4. Roblox therefore saw every left click as the right
// button: GUI hover and press states still worked, but Activated (left button
// only) never fired, and the "right button" started camera mouse capture.
static long (*orig_mouse_event_button_number)(id, SEL) = 0;
static long hooked_mouse_event_button_number(id self, SEL cmd) {
    long x11_button = orig_mouse_event_button_number(self, cmd);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        self, sel_registerName("type"));
    switch (type) {
    case 1: case 2: case 6:   // left down, up, dragged
        return 0;
    case 3: case 4: case 7:   // right down, up, dragged
        return 1;
    default:
        break;
    }
    if (x11_button == 2)
        return 2;
    if (x11_button >= 8)
        return x11_button - 5;
    return x11_button;
}

// NSTextInputClient methods that macOS NSTextView provides and Darling's
// lacks. Roblox's InputMethodHandler (an NSTextView subclass) queries them
// when a text box gains focus; the missing hasMarkedText was fatal. These
// report "no IME composition in progress", matching a plain text field.
typedef struct { unsigned long location, length; } MacNCheeseRange;
static MacNCheeseBool text_view_has_marked_text(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static MacNCheeseRange text_view_marked_range(id self, SEL cmd) {
    (void)self; (void)cmd;
    MacNCheeseRange range = {0x7FFFFFFFFFFFFFFFUL /* NSNotFound */, 0};
    return range;
}
static void text_view_unmark_text(id self, SEL cmd) {
    (void)self; (void)cmd;
}
static id text_view_valid_marked_attributes(id self, SEL cmd) {
    (void)self; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSArray"),
                                           sel_registerName("array"));
}
static id text_view_attributed_substring(id self, SEL cmd, MacNCheeseRange range,
                                         MacNCheeseRange* actual) {
    (void)self; (void)cmd; (void)range;
    if (actual) {
        actual->location = 0x7FFFFFFFFFFFFFFFUL;
        actual->length = 0;
    }
    return 0;
}

// Convenience constructors from macOS 10.12 missing in Darling's AppKit.
// Roblox builds its web challenge window with them.
static id macncheese_new_view(const char* class_name) {
    id object = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass(class_name),
                                                sel_registerName("alloc"));
    MacNCheeseRect zero = {{0, 0}, {0, 0}};
    object = ((id (*)(id, SEL, MacNCheeseRect))objc_msgSend)(
        object, sel_registerName("initWithFrame:"), zero);
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName("autorelease"));
}
static id button_with_image_target_action(id cls, SEL cmd, id image, id target,
                                          SEL action) {
    (void)cls; (void)cmd;
    id button = macncheese_new_view("NSButton");
    if (!button)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setImage:"), image);
    ((void (*)(id, SEL, unsigned long))objc_msgSend)(
        button, sel_registerName("setImagePosition:"), 1UL /* NSImageOnly */);
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setTarget:"), target);
    ((void (*)(id, SEL, SEL))objc_msgSend)(button, sel_registerName("setAction:"), action);
    ((void (*)(id, SEL))objc_msgSend)(button, sel_registerName("sizeToFit"));
    return button;
}
static id text_field_label_with_string(id cls, SEL cmd, id string) {
    (void)cls; (void)cmd;
    id label = macncheese_new_view("NSTextField");
    if (!label)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setStringValue:"), string);
    ((void (*)(id, SEL, MacNCheeseBool))objc_msgSend)(label, sel_registerName("setEditable:"), 0);
    ((void (*)(id, SEL, MacNCheeseBool))objc_msgSend)(label, sel_registerName("setSelectable:"), 0);
    ((void (*)(id, SEL, MacNCheeseBool))objc_msgSend)(label, sel_registerName("setBezeled:"), 0);
    ((void (*)(id, SEL, MacNCheeseBool))objc_msgSend)(label, sel_registerName("setBordered:"), 0);
    ((void (*)(id, SEL, MacNCheeseBool))objc_msgSend)(label, sel_registerName("setDrawsBackground:"), 0);
    ((void (*)(id, SEL))objc_msgSend)(label, sel_registerName("sizeToFit"));
    return label;
}

// Darling's Contacts framework is an empty stub. Roblox's home page asks for
// contacts permission (friend finding); report access as denied so it never
// tries to read contacts.
static long contact_store_authorization_denied(id cls, SEL cmd, long entity_type) {
    (void)cls; (void)cmd; (void)entity_type;
    return 2; // CNAuthorizationStatusDenied
}
struct MacNCheeseAccessBlock {
    void* isa;
    int flags;
    int reserved;
    void (*invoke)(void*, MacNCheeseBool, id);
};
static void contact_store_request_access(id self, SEL cmd, long entity_type,
                                         void* completion) {
    (void)self; (void)cmd; (void)entity_type;
    if (completion)
        ((struct MacNCheeseAccessBlock*)completion)->invoke(completion, 0, 0);
}

// Darling's Keychain does not persist SecItemAdd, so Roblox's login (a
// generic password item keyed by kSecAttrAccount) was gone after every
// restart. Keep generic password items as files instead:
// ~/Library/MacNCheese/Keychain/<hex account>, mode 0600.
// Other item classes still go to Darling's Security framework.
extern int SecItemAdd(id attributes, id* result);
extern int SecItemCopyMatching(id query, id* result);
extern int SecItemDelete(id query);
extern const id kSecClass;
extern const id kSecClassGenericPassword;
extern const id kSecAttrAccount;
extern const id kSecValueData;
extern const id kSecReturnData;
extern int chmod(const char*, unsigned short);
#define MACNCHEESE_ERR_SEC_ITEM_NOT_FOUND (-25300)

static id macncheese_keychain_path(id query) {
    id item_class = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecClass);
    id account = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecAttrAccount);
    if (!item_class || !account ||
        !((MacNCheeseBool (*)(id, SEL, id))objc_msgSend)(item_class, sel_registerName("isEqual:"),
                                                        kSecClassGenericPassword))
        return 0;
    const char* name = ((const char* (*)(id, SEL))objc_msgSend)(account, sel_registerName("UTF8String"));
    if (!name)
        return 0;
    // The account in hex; past 100 bytes, the first 100 and a hash of the
    // rest's whole (a file name holds 255 bytes).
    static const char digits[] = "0123456789abcdef";
    char hex[260];
    int length = 0;
    unsigned long long hash = 1469598103934665603ULL; // FNV-1a
    unsigned long bytes = 0;
    for (const unsigned char* c = (const unsigned char*)name; *c; c++, bytes++) {
        hash = (hash ^ *c) * 1099511628211ULL;
        if (bytes < 100) {
            hex[length++] = digits[*c >> 4];
            hex[length++] = digits[*c & 15];
        }
    }
    if (bytes > 100) {
        hex[length++] = '-';
        for (int shift = 60; shift >= 0; shift -= 4)
            hex[length++] = digits[(hash >> shift) & 15];
    }
    hex[length] = 0;
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    id directory = ((id (*)(id, SEL, id))objc_msgSend)(
        home, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Library/MacNCheese/Keychain"));
    ((MacNCheeseBool (*)(id, SEL, id, MacNCheeseBool, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    chmod(((const char* (*)(id, SEL))objc_msgSend)(directory, sel_registerName("fileSystemRepresentation")), 0700);
    return ((id (*)(id, SEL, id))objc_msgSend)(
        directory, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), hex));
}

static int macncheese_SecItemAdd(id attributes, id* result) {
    id path = attributes ? macncheese_keychain_path(attributes) : 0;
    if (!path)
        return SecItemAdd(attributes, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)(attributes, sel_registerName("objectForKey:"), kSecValueData);
    if (!data)
        data = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSData"), sel_registerName("data"));
    // Created 0600 before the secret is in it (the write keeps the mode).
    extern int open(const char*, int, ...);
    extern int close(int);
    const char* file = ((const char* (*)(id, SEL))objc_msgSend)(path, sel_registerName("fileSystemRepresentation"));
    int fd = file ? open(file, 0x1 /* O_WRONLY */ | 0x200 /* O_CREAT */, 0600) : -1;
    if (fd >= 0)
        close(fd);
    chmod(file, 0600);
    MacNCheeseBool written = fd >= 0 && ((MacNCheeseBool (*)(id, SEL, id, MacNCheeseBool))objc_msgSend)(
        data, sel_registerName("writeToFile:atomically:"), path, 0); // atomic writes are broken in Darling
    if (result)
        *result = 0;
    if (!written) {
        write_str("[MacNCheese Keychain] could not store generic password item\n");
        return -36; // errSecIO
    }
    write_str("[MacNCheese Keychain] stored generic password item\n");
    return 0;
}
DYLD_INTERPOSE(macncheese_SecItemAdd, SecItemAdd);

static int macncheese_SecItemCopyMatching(id query, id* result) {
    id path = query ? macncheese_keychain_path(query) : 0;
    if (!path)
        return SecItemCopyMatching(query, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("NSData"),
                                                 sel_registerName("dataWithContentsOfFile:"), path);
    if (!data)
        return MACNCHEESE_ERR_SEC_ITEM_NOT_FOUND;
    id wants_data = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecReturnData);
    if (result)
        *result = wants_data && ((MacNCheeseBool (*)(id, SEL))objc_msgSend)(wants_data, sel_registerName("boolValue"))
            ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain"))  // caller owns (+1)
            : 0;
    return 0;
}
DYLD_INTERPOSE(macncheese_SecItemCopyMatching, SecItemCopyMatching);

static int macncheese_SecItemDelete(id query) {
    id path = query ? macncheese_keychain_path(query) : 0;
    if (!path)
        return SecItemDelete(query);
    MacNCheeseBool removed = ((MacNCheeseBool (*)(id, SEL, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("removeItemAtPath:error:"), path, 0);
    return removed ? 0 : MACNCHEESE_ERR_SEC_ITEM_NOT_FOUND;
}
DYLD_INTERPOSE(macncheese_SecItemDelete, SecItemDelete);

// Records the requested OpenGL profile (gl_profile.c); MACNCHEESE_TRACE_CGL
// logs the attributes (Darling's CGL pixel format keeps almost none of them).
static id (*orig_pixel_format_init)(id, SEL, const unsigned int*) = 0;
static id hooked_pixel_format_init(id self, SEL cmd, const unsigned int* attributes) {
    if (macncheese_trace_cgl_enabled()) {
        // Up to the terminating 0 (the array may be on the caller's stack).
        write_str("[MacNCheese CGL] NSOpenGLPixelFormat attributes:");
        for (int index = 0; attributes && index < 64; index++) {
            write_str(" ");
            print_num(attributes[index]);
            if (!attributes[index])
                break;
        }
        write_str("\n");
    }
    id result = orig_pixel_format_init(self, cmd, attributes);
    macncheese_note_pixel_format(result, attributes);
    return result;
}

// Darling's event queue (NSDisplay) fixed to behave like macOS.
//
// -nextEventMatchingMask:untilDate:inMode:dequeue: removed every queued
// event that did not match the mask while looking for one that did. macOS
// leaves them queued. When the game asked for mouse events during a camera
// drag, key releases waiting in front were thrown away: keys stuck ("W
// stayed pressed") or presses were lost. -discardEventsMatchingMask:
// beforeEvent: tested the reference event's type instead of each queued
// event's. The queue (an NSMutableArray) is also shared with the rendering
// thread (shared_current_display), so all three take a lock.
static volatile unsigned int macncheese_event_queue_lock;
extern const void *CFRunLoopGetMain(void);
extern const void *kCFRunLoopCommonModes;
extern const void *CFRunLoopSourceCreate(const void *, long, void *);
extern void CFRunLoopAddSource(const void *, const void *, const void *);
extern void CFRunLoopSourceSignal(const void *);
extern void CFRunLoopWakeUp(const void *);
extern int pthread_main_np(void);
static const void *macncheese_event_queue_source;
static volatile unsigned int macncheese_event_queue_wake_pending;
static void macncheese_event_queue_source_perform(void *info) {
    (void)info;
    __atomic_store_n(&macncheese_event_queue_wake_pending, 0, __ATOMIC_RELEASE);
}
static void macncheese_install_event_queue_source(void) {
    struct {
        long version; void *info;
        const void *(*retain)(const void *); void (*release)(const void *);
        const void *(*description)(const void *);
        unsigned char (*equal)(const void *, const void *); unsigned long (*hash)(const void *);
        void (*schedule)(void *, const void *, const void *);
        void (*cancel)(void *, const void *, const void *); void (*perform)(void *);
    } context = {.perform = macncheese_event_queue_source_perform};
    const void *source = CFRunLoopSourceCreate(0, 0, &context);
    if (!source) {
        write_str("[MacNCheese] Could not create event queue wake source\n");
        return;
    }
    /* Retained for the installed hooks' lifetime. AppKit adds its modal and
     * tracking modes to the main loop's common modes during initialization. */
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    __atomic_store_n(&macncheese_event_queue_source, source, __ATOMIC_RELEASE);
}
static void macncheese_wake_event_queue(void) {
    const void *source = __atomic_load_n(&macncheese_event_queue_source, __ATOMIC_ACQUIRE);
    if (!source || __atomic_exchange_n(&macncheese_event_queue_wake_pending, 1, __ATOMIC_ACQ_REL))
        return;
    /* NSRunLoop returns after a handled source. A wake by itself can resume
     * waiting with an NSEvent still queued, including when a timer posts it.
     * Collapse repeated posts into one signal; main-thread input needs no IPC. */
    CFRunLoopSourceSignal(source);
    if (!pthread_main_np())
        CFRunLoopWakeUp(CFRunLoopGetMain());
}
static void macncheese_lock_event_queue(void) {
    macncheese_lock(&macncheese_event_queue_lock);
}
static void macncheese_unlock_event_queue(void) {
    macncheese_unlock(&macncheese_event_queue_lock);
}
static id macncheese_event_queue(id display) {
    static Ivar queue_ivar;
    if (!queue_ivar)
        queue_ivar = class_getInstanceVariable(objc_getClass("NSDisplay"), "_eventQueue");
    return queue_ivar ? *(id*)((char*)display + ivar_getOffset(queue_ivar)) : (id)0;
}
static unsigned long macncheese_event_type(id event) {
    return ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
}
static int macncheese_mask_matches(unsigned long long mask, unsigned long type) {
    return type < 64 && (mask & (1ULL << type));
}

static id hooked_display_next_event(id self, SEL cmd, unsigned long long mask, id until, id mode,
                                    signed char dequeue) {
    (void)cmd;
    id queue = macncheese_event_queue(self);
    SEL count = sel_registerName("count"), object_at = sel_registerName("objectAtIndex:");
    // No waiting when a matching event is queued. Events of other types may
    // wait there for someone else: they must not turn every wait into a spin.
    int matching = 0;
    if (queue) {
        macncheese_lock_event_queue();
        unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count);
        for (unsigned long index = 0; index < total && !matching; index++)
            matching = macncheese_mask_matches(mask, macncheese_event_type(
                ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, object_at, index)));
        macncheese_unlock_event_queue();
    }
    if (matching)
        until = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSDate"), sel_registerName("date"));
    id run_loop = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSRunLoop"),
                                                  sel_registerName("currentRunLoop"));
    ((signed char (*)(id, SEL, id, id))objc_msgSend)(run_loop, sel_registerName("runMode:beforeDate:"),
                                                     mode, until);
    id result = (id)0;
    if (queue) {
        macncheese_lock_event_queue();
        unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count);
        for (unsigned long index = 0; index < total; index++) {
            id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, object_at, index);
            if (!macncheese_mask_matches(mask, macncheese_event_type(event)))
                continue;
            result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("retain"));
            if (dequeue)
                ((void (*)(id, SEL, unsigned long))objc_msgSend)(
                    queue, sel_registerName("removeObjectAtIndex:"), index);
            break;
        }
        /* Nobody may ever ask for some event types; keep the queue bounded. */
        while (((unsigned long (*)(id, SEL))objc_msgSend)(queue, count) > 4096)
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), 0);
        macncheese_unlock_event_queue();
        if (result)
            result = ((id (*)(id, SEL))objc_msgSend)(result, sel_registerName("autorelease"));
    }
    if (!result) {
        /* As Darling: its "no event" placeholder, type 100, which
         * -[NSApplication nextEventMatchingMask:...] recognizes and keeps
         * waiting (checked in Darling's AppKit). The type 13 used before is a
         * real NSEventTypeAppKitDefined event at (0,0): the run loop sent it
         * to the app and to event monitors, and tracking loops (buttons in
         * alerts) took it as a mouse event outside and gave up. */
        id event = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSEvent"), sel_registerName("alloc"));
        event = ((id (*)(id, SEL, unsigned long, MacNCheesePoint, unsigned long, id))objc_msgSend)(
            event, sel_registerName("initWithType:location:modifierFlags:window:"), 100,
            (MacNCheesePoint){0, 0}, 0, (id)0);
        result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("autorelease"));
    }
    return result;
}

static void hooked_display_post_event(id self, SEL cmd, id event, signed char at_start) {
    (void)cmd;
    id queue = macncheese_event_queue(self);
    if (!queue || !event)
        return;
    if (macncheese_core_motion_type && macncheese_is_motion_type(event)) {
        static Ivar type_ivar;
        if (!type_ivar)
            type_ivar = class_getInstanceVariable(objc_getClass("NSEvent"), "_type");
        if (type_ivar)
            *(unsigned long*)((char*)event + ivar_getOffset(type_ivar)) = macncheese_core_motion_type;
        ((void (*)(id, SEL, long))objc_msgSend)(event, sel_registerName("_setButtonNumber:"),
                                              (long)macncheese_core_motion_button);
    }
    macncheese_lock_event_queue();
    if (at_start) {
        ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(queue, sel_registerName("insertObject:atIndex:"),
                                                             event, 0);
    } else {
        unsigned long type = macncheese_event_type(event);
        // Coalesce mouse motion events during mouse lock: accumulate deltas into the last
        // queued event of the same type. This matches macOS AppKit event coalescing, prevents
        // queue backlog from high polling rate mice, and eliminates input lag when releasing the mouse.
        if (macncheese_pointer_grabbed && (type == 5 || type == 6 || type == 7 || type == 27)) {
            unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, sel_registerName("count"));
            if (total > 0) {
                id last = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
                    queue, sel_registerName("objectAtIndex:"), total - 1);
                if (macncheese_event_type(last) == type &&
                    ((long (*)(id, SEL))objc_msgSend)(last, sel_registerName("windowNumber")) ==
                        ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("windowNumber")) &&
                    ((unsigned long (*)(id, SEL))objc_msgSend)(last, sel_registerName("modifierFlags")) ==
                        ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags")) &&
                    ((long (*)(id, SEL))objc_msgSend)(last, sel_registerName("buttonNumber")) ==
                        ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("buttonNumber"))) {
                    static Ivar dx_ivar, dy_ivar;
                    if (!dx_ivar) {
                        Class mouse_cls = objc_getClass("NSEvent_mouse");
                        if (mouse_cls) {
                            dx_ivar = class_getInstanceVariable(mouse_cls, "_deltaX");
                            dy_ivar = class_getInstanceVariable(mouse_cls, "_deltaY");
                        }
                    }
                    if (dx_ivar && dy_ivar) {
                        long off_x = (long)ivar_getOffset(dx_ivar);
                        long off_y = (long)ivar_getOffset(dy_ivar);
                        /* A dequeued=NO caller may still hold the old event:
                         * replace it rather than changing its deltas in place. */
                        *(double*)((char*)event + off_x) += *(double*)((char*)last + off_x);
                        *(double*)((char*)event + off_y) += *(double*)((char*)last + off_y);
                        ((void (*)(id, SEL, unsigned long, id))objc_msgSend)(
                            queue, sel_registerName("replaceObjectAtIndex:withObject:"), total - 1, event);
                        macncheese_unlock_event_queue();
                        macncheese_wake_event_queue();
                        return;
                    }
                }
            }
        }
        ((void (*)(id, SEL, id))objc_msgSend)(queue, sel_registerName("addObject:"), event);
    }
    macncheese_unlock_event_queue();
    macncheese_wake_event_queue();
}

static void hooked_display_discard_events(id self, SEL cmd, unsigned long long mask, id before) {
    (void)cmd;
    id queue = macncheese_event_queue(self);
    if (!queue)
        return;
    macncheese_lock_event_queue();
    unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, sel_registerName("count"));
    unsigned long stop = total;
    for (unsigned long index = 0; index < total; index++)
        if (((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index) == before) {
            stop = index;
            break;
        }
    for (unsigned long index = stop; index-- > 0;) {
        id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index);
        if (macncheese_mask_matches(mask, macncheese_event_type(event)))
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), index);
    }
    macncheese_unlock_event_queue();
}

// X11 events as Darling's AppKit receives them (-[X11Display postXEvent:]).
//
// Motion compression: a 1000 Hz mouse sends a motion event per pixel, and
// Darling turns every one into an NSEvent the game handles. It could not
// keep up; a pointer warp during mouse lock reached the game 180-340 events
// late and the camera lagged and jumped (reported on an RTX 3050 laptop).
// A motion event is skipped when the next queued event is a motion event
// of the same window and buttons: Darling computes deltas from positions,
// so the next one carries the skipped movement. While one of our warps is
// on its way (mouse lock), nothing is merged: the lock logic must see the
// warp's motion alone. (The 48 px limit below did not ensure that: the
// warp's own event was merged into the next one whenever that was close.)
// MACNCHEESE_NO_MOTION_COMPRESSION=1 turns this off.
// MACNCHEESE_TRACE_KEYS=1 logs X key presses/releases here and the key events
// the game gets (sendEvent), to find lost or stuck keys.
static void (*orig_post_x_event)(id, SEL, void*);
static int macncheese_trace_keys_enabled(void) {
    static volatile int enabled = -1;
    return macncheese_env_cached("MACNCHEESE_TRACE_KEYS", &enabled);
}
static int macncheese_game_focus_event(id self, void* event) {
    unsigned long xid = *(unsigned long*)((char*)event + 24);
    unsigned long capture = __atomic_load_n(&macncheese_cursor_lock_window, __ATOMIC_ACQUIRE);
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
                                             sel_registerName("sharedApplication"));
    id main = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    unsigned long main_handle = macncheese_native_window_handle(main);
    if (capture || main_handle)
        return xid == capture || xid == main_handle;
    (void)self;
    return 1; // first activation, before a main window has been established
}
static void macncheese_refresh_pointer_state(id self) {
    static int (*query)(void*, unsigned long, unsigned long*, unsigned long*, int*, int*, int*, int*, unsigned int*);
    if (!query)
        query = (int (*)(void*, unsigned long, unsigned long*, unsigned long*, int*, int*, int*, int*, unsigned int*))
            dlsym(RTLD_DEFAULT, "XQueryPointer");
    void* display = macncheese_x11_display_connection(self);
    unsigned long window = macncheese_native_window_handle(macncheese_lock_window());
    unsigned long root, child;
    int rx, ry, x, y;
    unsigned int state;
    if (query && display && window && query(display, window, &root, &child, &rx, &ry, &x, &y, &state)) {
        macncheese_x_modifier_flags = macncheese_modifiers_for_x_state(state);
        macncheese_raw_buttons = macncheese_buttons_for_x_state(state);
    }
}
static void hooked_post_x_event(id self, SEL cmd, void* event) {
    int type = *(int*)event;
    if (type != 35 /* raw events */ && type != 6 /* their core motion companions */)
        macncheese_flush_raw_motion(self);
    macncheese_update_x_input_state(self, event);
    if (type == 34 /* MappingNotify */)
        macncheese_refresh_x_modifier_mapping(self, 1);
    {
        static volatile int trace_x = -1;
        static long traced_x;
        if (macncheese_env_cached("MACNCHEESE_TRACE_XEVENTS", &trace_x) && traced_x++ < 80) {
            write_str("[MacNCheese X] event type=");
            print_num(type);
            write_str(" display=");
            print_num((long long)(unsigned long)macncheese_x11_display_connection(self));
            static char* (*display_string)(void*);
            if (!display_string)
                display_string = (char* (*)(void*))dlsym(RTLD_DEFAULT, "XDisplayString");
            if (display_string && macncheese_x11_display_connection(self)) {
                write_str(" ");
                write_str(display_string(macncheese_x11_display_connection(self)));
            }
            write_str(macncheese_pointer_grabbed ? " locked\n" : "\n");
        }
    }
    if (macncheese_raw_mouse_x_event(self, event))
        return;
    if (type == 7 /* EnterNotify */ && macncheese_pointer_grabbed && !macncheese_raw_mouse_active)
        /* The pointer drifted out of the window during a mouse lock and came
         * back. The first motion after it reports the whole distance from the
         * exit point, which would fling the game camera: drop that one. */
        macncheese_drop_next_motion = 1;
    if (type == 6 /* MotionNotify */ && macncheese_pointer_grabbed &&
        macncheese_drop_next_motion) {
        macncheese_drop_next_motion = 0;
        return;
    }
    if (type == 33 /* ClientMessage */) {
        /* XClientMessageEvent LP64: window=32, message_type=40, format=48,
         * data.l[0]=56. WM_DELETE_WINDOW is the payload of WM_PROTOCOLS.
         * Only closing the game window should stop the entire client. */
        static unsigned long (*intern_atom)(void*, const char*, int);
        static void* atom_display;
        static unsigned long wm_protocols, wm_delete;
        if (!intern_atom)
            intern_atom = (unsigned long (*)(void*, const char*, int))
                dlsym(RTLD_DEFAULT, "XInternAtom");
        void* display = macncheese_x11_display_connection(self);
        if (display && intern_atom && display != atom_display) {
            wm_protocols = intern_atom(display, "WM_PROTOCOLS", 1);
            wm_delete = intern_atom(display, "WM_DELETE_WINDOW", 1);
            atom_display = display;
        }
        if (display && wm_protocols && wm_delete &&
            *(unsigned long*)((char*)event + 40) == wm_protocols &&
            *(int*)((char*)event + 48) == 32 &&
            *(unsigned long*)((char*)event + 56) == wm_delete) {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
            id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
            unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count"));
            for (unsigned long i = 0; i < count; i++) {
                id window = ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), i);
                const char* name = object_getClassName(window);
                if (!name || !ascii_strings_equal(name, "RBXWindow") ||
                    macncheese_native_window_handle(window) != *(unsigned long*)((char*)event + 32))
                    continue;
                write_str("[MacNCheese] Window close requested (WM_DELETE_WINDOW)\n");
                macncheese_write_quit_sentinel();
                break;
            }
        }
    }
    if (type == 6 /* MotionNotify */) {
        static int compression = -1;
        static int (*queued)(void*, int);
        static int (*peek)(void*, void*);
        static long display_offset = -1;
        if (compression < 0) {
            // XEventsQueued(QueuedAlready): only what Xlib has read already;
            // XPending would flush and read the socket for every motion event.
            queued = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XEventsQueued");
            peek = (int (*)(void*, void*))dlsym(RTLD_DEFAULT, "XPeekEvent");
            Ivar display_ivar = class_getInstanceVariable(object_getClass(self), "_display");
            display_offset = display_ivar ? (long)ivar_getOffset(display_ivar) : -1;
            compression = !macncheese_env_on("MACNCHEESE_NO_MOTION_COMPRESSION") && queued && peek &&
                          display_offset >= 0;
        }
        void* display = compression && !macncheese_drop_warp_motion && !macncheese_x_batch_last
            ? *(void**)((char*)self + display_offset) : 0;
        if (display && queued(display, 0 /* QueuedAlready */) > 0) {
            unsigned char next[192];
            peek(display, next);
            /* XMotionEvent: window at 32, x/y at 64/68, state at 80 */
            int dx = *(int*)(next + 64) - *(int*)((char*)event + 64);
            int dy = *(int*)(next + 68) - *(int*)((char*)event + 68);
            if (*(int*)next == 6 &&
                *(unsigned long*)(next + 32) == *(unsigned long*)((char*)event + 32) &&
                *(unsigned int*)(next + 80) == *(unsigned int*)((char*)event + 80) &&
                dx <= 48 && dx >= -48 && dy <= 48 && dy >= -48)
                return;
        }
    } else if (type == 10 /* FocusOut */) {
        /* XFocusChangeEvent: detail at 44. Focus moving into a child window
         * of ours (NotifyInferior) keeps the keyboard with us. */
        int mode = *(int*)((char*)event + 40);
        if (mode == 1 /* NotifyGrab */ || mode == 2 /* NotifyUngrab */ ||
            *(int*)((char*)event + 44) == 2 /* NotifyInferior */)
            return;
        if (macncheese_game_focus_event(self, event)) {
            for (int key = 0; key < 128; key++)
                macncheese_key_down[key] = 0;
            for (int key = 0; key < 256; key++)
                macncheese_x_modifier_keys_down[key] = 0;
            __atomic_store_n(&macncheese_input_focused, 0, __ATOMIC_RELEASE);
            macncheese_pointer_grabbed = macncheese_raw_mouse_wanted = 0;
            macncheese_raw_mouse_active = 0;
            macncheese_drop_warp_motion = macncheese_drop_next_motion = 0;
            macncheese_raw_buttons = 0;
            macncheese_x_modifier_flags = 0;
            macncheese_set_x_cursor_hidden(0);
        }
    } else if (type == 9 /* FocusIn */) {
        int mode = *(int*)((char*)event + 40);
        if (mode == 1 /* NotifyGrab */ || mode == 2 /* NotifyUngrab */ ||
            *(int*)((char*)event + 44) == 2 /* NotifyInferior */)
            return;
    } else if ((type == 2 || type == 3) && macncheese_trace_keys_enabled()) {
        /* XKeyEvent: time at 56, keycode at 84 */
        write_str(type == 2 ? "[MacNCheese Keys] X press   keycode=" : "[MacNCheese Keys] X release keycode=");
        print_num(*(unsigned int*)((char*)event + 84));
        write_str(" time=");
        print_num((long long)*(unsigned long*)((char*)event + 56));
        /* When Darling handles it, in the same milliseconds scale: if the
         * gap to `time` grows, events wait inside Mac'n Cheese. */
        write_str(" handled=");
        print_num((long long)(mach_absolute_time() / 1000000ULL));
        write_str("\n");
    }
    if (type == 6 /* MotionNotify */)
        macncheese_core_motion_type = macncheese_motion_type(macncheese_raw_buttons, &macncheese_core_motion_button);
    @try {
        orig_post_x_event(self, cmd, event);
    } @finally {
        macncheese_core_motion_type = macncheese_core_motion_button = 0;
    }
    if (type == 9 /* FocusIn */ && macncheese_game_focus_event(self, event)) {
        /* Darling must activate the Cocoa window before we resolve its lock
         * anchor. State is queried once on activation, never per raw report. */
        macncheese_refresh_pointer_state(self);
        macncheese_refresh_x_modifier_mapping(self, 1);
        __atomic_store_n(&macncheese_input_focused, 1, __ATOMIC_RELEASE);
        macncheese_apply_mouse_capture(__atomic_load_n(&macncheese_mouse_lock_requested, __ATOMIC_ACQUIRE));
    }
}

static void (*orig_process_pending_events)(id, SEL);
static void hooked_process_pending_events(id self, SEL cmd) {
    /* XPending inside an unbounded drain can keep importing reports forever.
     * Take one snapshot and give the app a turn after 128 events or 2 ms. */
    unsigned int expected = 0;
    if (!__atomic_compare_exchange_n(&macncheese_x_event_draining, &expected, 1, 0,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
    id pool = 0;
    @try {
        static int (*pending)(void*);
        static int (*next)(void*, void*);
        if (!pending) {
            pending = (int (*)(void*))dlsym(RTLD_DEFAULT, "XPending");
            next = (int (*)(void*, void*))dlsym(RTLD_DEFAULT, "XNextEvent");
        }
        void* display = macncheese_x11_display_connection(self);
        if (!pending || !next || !display) {
            orig_process_pending_events(self, cmd);
        } else {
            pool = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSAutoreleasePool"),
                                                   sel_registerName("new"));
            int total = pending(display);
            if (total > 128) total = 128;
            unsigned long long deadline = macncheese_input_now_ns() + 2000000ULL;
            for (int index = 0; index < total; index++) {
                /* Deliver the final core motion even when more arrive. A
                 * compressor waiting for an empty queue could otherwise
                 * suppress every batch of a continuous stream. */
                macncheese_x_batch_last = index + 1 == total || macncheese_input_now_ns() >= deadline;
                unsigned long event[24]; // XEvent, 192 bytes on x86_64
                if (!next(display, event))
                    ((void (*)(id, SEL, void*))objc_msgSend)(self, sel_registerName("postXEvent:"), event);
                if (macncheese_x_batch_last)
                    break;
            }
            macncheese_x_batch_last = 0;
            macncheese_flush_raw_motion(self);
        }
    } @finally {
        macncheese_core_motion_type = macncheese_core_motion_button = 0;
        macncheese_x_batch_last = 0;
        if (macncheese_raw_pending_window) {
            ((void (*)(id, SEL))objc_msgSend)(macncheese_raw_pending_window, sel_registerName("release"));
            macncheese_raw_pending_window = 0;
            macncheese_raw_pending_dx = macncheese_raw_pending_dy = 0;
        }
        if (pool)
            ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("release"));
        __atomic_store_n(&macncheese_x_event_draining, 0, __ATOMIC_RELEASE);
    }
}

// OpenGL subwindows get the screen's visual (gl_profile.c explains why).
extern unsigned long macncheese_replace_gl_subwindow(void* display, unsigned long parent, unsigned long old);
static id (*orig_x11_subwindow_init)(id, SEL, id, MacNCheeseRect);
static id hooked_x11_subwindow_init(id self, SEL cmd, id parent, MacNCheeseRect frame) {
    id result = orig_x11_subwindow_init(self, cmd, parent, frame);
    if (!result || !parent)
        return result;
    Class cls = object_getClass(result);
    Ivar window_ivar = class_getInstanceVariable(cls, "_window");
    Ivar display_ivar = class_getInstanceVariable(cls, "_display");
    if (!window_ivar || !display_ivar)
        return result;
    unsigned long* window = (unsigned long*)((char*)result + ivar_getOffset(window_ivar));
    void* display = *(void**)((char*)result + ivar_getOffset(display_ivar));
    unsigned long parent_handle =
        ((unsigned long (*)(id, SEL))objc_msgSend)(parent, sel_registerName("windowHandle"));
    *window = macncheese_replace_gl_subwindow(display, parent_handle, *window);
    return result;
}

// Classes from Darling's X11 backend load after this library initializes, so
// hooks on them are installed again once NSApplication finishes launching.
static void macncheese_install_late_hooks(void) {
    macncheese_install_surface_scale_hook();
    static volatile int visibility_hooked;
    Class cursor_class = objc_getClass("NSCursor");
    if (cursor_class && !macncheese_wayland_enabled() && __sync_bool_compare_and_swap(&visibility_hooked, 0, 1)) {
        Method hide = class_getClassMethod(cursor_class, sel_registerName("hide"));
        Method unhide = class_getClassMethod(cursor_class, sel_registerName("unhide"));
        if (hide && unhide) {
            orig_cursor_hide = (void (*)(id, SEL))method_getImplementation(hide);
            orig_cursor_unhide = (void (*)(id, SEL))method_getImplementation(unhide);
            method_setImplementation(hide, (IMP)hooked_cursor_hide);
            method_setImplementation(unhide, (IMP)hooked_cursor_unhide);
        }
    }
    static volatile int cursor_hooked;
    static volatile int window_events_hooked;
    static volatile int event_queue_hooked;
    Class display_class = objc_getClass("NSDisplay");
    if (display_class && __sync_bool_compare_and_swap(&event_queue_hooked, 0, 1)) {
        Method next = class_getInstanceMethod(display_class,
            sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:"));
        Method post = class_getInstanceMethod(display_class, sel_registerName("postEvent:atStart:"));
        Method discard = class_getInstanceMethod(display_class,
            sel_registerName("discardEventsMatchingMask:beforeEvent:"));
        if (next && post && discard && class_getInstanceVariable(display_class, "_eventQueue")) {
            macncheese_install_event_queue_source();
            method_setImplementation(next, (IMP)hooked_display_next_event);
            method_setImplementation(post, (IMP)hooked_display_post_event);
            method_setImplementation(discard, (IMP)hooked_display_discard_events);
            write_str("[MacNCheese] Event queue keeps non-matching events (NSDisplay fix)\n");
        }
    }
    static volatile int x_events_hooked;
    Class x11_display_class = objc_getClass("X11Display");
    if (x11_display_class && __sync_bool_compare_and_swap(&x_events_hooked, 0, 1)) {
        Method cursor = class_getInstanceMethod(x11_display_class, sel_registerName("setCursor:"));
        if (cursor) {
            orig_x11_display_set_cursor = (void (*)(id, SEL, id))method_getImplementation(cursor);
            method_setImplementation(cursor, (IMP)hooked_x11_display_set_cursor);
            write_str("[MacNCheese] X11 cursor selection follows set/hide/unhide and resets\n");
        }
        Method method = class_getInstanceMethod(x11_display_class, sel_registerName("postXEvent:"));
        if (method) {
            orig_post_x_event = (void (*)(id, SEL, void*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_post_x_event);
            write_str("[MacNCheese] Hooked X11Display postXEvent: (motion compression)\n");
        }
        method = class_getInstanceMethod(x11_display_class, sel_registerName("processPendingEvents"));
        if (method) {
            orig_process_pending_events = (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_process_pending_events);
            write_str("[MacNCheese] X11 input drains bounded to 128 events / 2 ms\n");
        }
    }
    static volatile int subwindow_hooked;
    Class x11_subwindow_class = objc_getClass("X11SubWindow");
    if (x11_subwindow_class && __sync_bool_compare_and_swap(&subwindow_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_subwindow_class, sel_registerName("initWithParentWindow:frame:"));
        if (method) {
            orig_x11_subwindow_init =
                (id (*)(id, SEL, id, MacNCheeseRect))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_subwindow_init);
            write_str("[MacNCheese] Hooked X11SubWindow initWithParentWindow:frame: (GL visual)\n");
        }
    }
    Class x11_cursor_class = objc_getClass("X11Cursor");
    if (x11_cursor_class &&
        __sync_bool_compare_and_swap(&cursor_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_cursor_class, sel_registerName("initWithImage:hotPoint:"));
        if (method) {
            orig_x11_cursor_init_image =
                (id (*)(id, SEL, id, MacNCheesePoint))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_cursor_init_image);
            write_str("[MacNCheese] Replaced X11Cursor initWithImage:hotPoint: (row copy fix)\n");
        }
    }
    static volatile int monitors_hooked;
    Class event_class_for_monitors = objc_getClass("NSEvent");
    Class application_class = objc_getClass("NSApplication");
    if (event_class_for_monitors && application_class &&
        __sync_bool_compare_and_swap(&monitors_hooked, 0, 1)) {
        Method add = class_getClassMethod(
            event_class_for_monitors,
            sel_registerName("addLocalMonitorForEventsMatchingMask:handler:"));
        Method remove = class_getClassMethod(
            event_class_for_monitors, sel_registerName("removeMonitor:"));
        Method send = class_getInstanceMethod(
            application_class, sel_registerName("sendEvent:"));
        if (add && remove && send) {
            method_setImplementation(add, (IMP)event_add_local_monitor);
            method_setImplementation(remove, (IMP)event_remove_monitor);
            orig_app_send_event =
                (void (*)(id, SEL, id))method_getImplementation(send);
            method_setImplementation(send, (IMP)hooked_app_send_event);
            write_str("[MacNCheese] Implemented NSEvent local event monitors\n");
        }
        Method accepts = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("acceptsMouseMovedEvents"));
        if (accepts) {
            orig_window_accepts_mouse_moved =
                (MacNCheeseBool (*)(id, SEL))method_getImplementation(accepts);
            method_setImplementation(accepts, (IMP)hooked_window_accepts_mouse_moved);
            write_str("[MacNCheese] RBXWindow always accepts mouse-moved events\n");
        }
        Method wclose = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("close"));
        if (wclose) {
            orig_window_close = (void (*)(id, SEL))method_getImplementation(wclose);
            method_setImplementation(wclose, (IMP)hooked_window_close);
            write_str("[MacNCheese] RBXWindow close writes the quit sentinel\n");
        }
        Method wperform = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("performClose:"));
        if (wperform) {
            orig_window_perform_close =
                (void (*)(id, SEL, id))method_getImplementation(wperform);
            method_setImplementation(wperform, (IMP)hooked_window_perform_close);
        }
    }
    static volatile int button_number_hooked;
    Class mouse_event_class = objc_getClass("NSEvent_mouse");
    if (mouse_event_class &&
        __sync_bool_compare_and_swap(&button_number_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            mouse_event_class, sel_registerName("buttonNumber"));
        if (method) {
            orig_mouse_event_button_number =
                (long (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_button_number);
            write_str("[MacNCheese] NSEvent buttonNumber uses macOS numbering\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaX"));
        if (method) {
            orig_mouse_event_delta_x =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_x);
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaY"));
        if (method) {
            orig_mouse_event_delta_y =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_y);
            write_str("[MacNCheese] NSEvent motion deltaY uses macOS sign\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("locationInWindow"));
        if (method) {
            orig_event_location_in_window =
                (MacNCheesePoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_location_in_window);
        }
        method = class_getInstanceMethod(objc_getClass("NSWindow"),
                                         sel_registerName("mouseLocationOutsideOfEventStream"));
        if (method) {
            orig_window_mouse_location =
                (MacNCheesePoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_mouse_location);
        }
        method = class_getClassMethod(objc_getClass("NSEvent"), sel_registerName("mouseLocation"));
        if (method) {
            orig_event_mouse_location =
                (MacNCheesePoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_mouse_location);
        }
        write_str("[MacNCheese] Mouse location freezes during mouse lock\n");
    }
    static volatile int text_input_added;
    Class text_view_class = objc_getClass("NSTextView");
    if (text_view_class &&
        __sync_bool_compare_and_swap(&text_input_added, 0, 1)) {
        struct { const char* name; IMP imp; const char* types; } methods[] = {
            {"hasMarkedText", (IMP)text_view_has_marked_text, "c@:"},
            {"markedRange", (IMP)text_view_marked_range, "{_NSRange=QQ}@:"},
            {"unmarkText", (IMP)text_view_unmark_text, "v@:"},
            {"validAttributesForMarkedText", (IMP)text_view_valid_marked_attributes, "@@:"},
            {"attributedSubstringForProposedRange:actualRange:",
             (IMP)text_view_attributed_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}"},
        };
        for (unsigned long index = 0; index < sizeof(methods) / sizeof(methods[0]); index++) {
            SEL selector = sel_registerName(methods[index].name);
            if (!class_getInstanceMethod(text_view_class, selector) &&
                class_addMethod(text_view_class, selector, methods[index].imp,
                                methods[index].types)) {
                write_str("[MacNCheese] Added NSTextView ");
                write_str(methods[index].name);
                write_str("\n");
            }
        }
    }
    static volatile int constructors_added;
    if (__sync_bool_compare_and_swap(&constructors_added, 0, 1)) {
        Class button_meta = object_getClass((id)objc_getClass("NSButton"));
        Class text_field_meta = object_getClass((id)objc_getClass("NSTextField"));
        SEL button_selector = sel_registerName("buttonWithImage:target:action:");
        SEL label_selector = sel_registerName("labelWithString:");
        if (button_meta && !class_getInstanceMethod(button_meta, button_selector) &&
            class_addMethod(button_meta, button_selector,
                            (IMP)button_with_image_target_action, "@@:@@:"))
            write_str("[MacNCheese] Added +[NSButton buttonWithImage:target:action:]\n");
        if (text_field_meta && !class_getInstanceMethod(text_field_meta, label_selector) &&
            class_addMethod(text_field_meta, label_selector,
                            (IMP)text_field_label_with_string, "@@:@"))
            write_str("[MacNCheese] Added +[NSTextField labelWithString:]\n");
    }
    static volatile int contacts_added;
    Class contact_store_class = objc_getClass("CNContactStore");
    if (contact_store_class &&
        __sync_bool_compare_and_swap(&contacts_added, 0, 1)) {
        Class contact_store_meta = object_getClass((id)contact_store_class);
        SEL status = sel_registerName("authorizationStatusForEntityType:");
        SEL request = sel_registerName("requestAccessForEntityType:completionHandler:");
        if (!class_getInstanceMethod(contact_store_meta, status) &&
            class_addMethod(contact_store_meta, status,
                            (IMP)contact_store_authorization_denied, "q@:q"))
            write_str("[MacNCheese] Added CNContactStore authorization (denied)\n");
        if (!class_getInstanceMethod(contact_store_class, request))
            class_addMethod(contact_store_class, request,
                            (IMP)contact_store_request_access, "v@:q@?");
    }
    static volatile int pixel_format_hooked;
    Class pixel_format_class = objc_getClass("NSOpenGLPixelFormat");
    if (pixel_format_class && __sync_bool_compare_and_swap(&pixel_format_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(pixel_format_class, sel_registerName("initWithAttributes:"));
        if (method) {
            orig_pixel_format_init = (id (*)(id, SEL, const unsigned int*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_pixel_format_init);
        }
    }
    static volatile int web_hooked;
    Class web_view_class = objc_getClass("WKWebView");
    Class workspace_class = objc_getClass("NSWorkspace");
    if (web_view_class && workspace_class &&
        __sync_bool_compare_and_swap(&web_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            web_view_class, sel_registerName("initWithFrame:configuration:"));
        if (method) {
            orig_web_view_init = (id (*)(id, SEL, MacNCheeseRect, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_init);
        }
        method = class_getInstanceMethod(web_view_class, sel_registerName("loadRequest:"));
        if (method) {
            orig_web_view_load_request = (id (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_load_request);
        }
        method = class_getInstanceMethod(workspace_class, sel_registerName("openURL:"));
        if (method) {
            orig_workspace_open_url = (MacNCheeseBool (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_workspace_open_url);
        }
        write_str("[MacNCheese] Tracing WKWebView and NSWorkspace openURL:\n");
    }
    Class window_class = objc_getClass("NSWindow");
    if (window_class &&
        __sync_bool_compare_and_swap(&window_events_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            window_class, sel_registerName("sendEvent:"));
        if (method) {
            orig_window_send_event =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_send_event);
        }
    }
}

// A direct executable launch has no Apple Event. Darling lacks this selector;
// its generic forwarding path otherwise leaves an invalid object return value.
static id no_current_apple_event(id self, SEL cmd) { (void)self; (void)cmd; return 0; }

// Added in newer Foundation versions than Darling currently implements.
// Build relative file URLs using the older URL and NSString APIs that Darling
// does provide.
static id url_file_with_path_relative_to_url(id cls, SEL cmd, id path, id base_url) {
    (void)cmd;
    if (!path)
        return 0;

    signed char is_absolute = ((signed char (*)(id, SEL))objc_msgSend)(
        path, sel_registerName("isAbsolutePath"));
    if (!base_url || is_absolute)
        return ((id (*)(id, SEL, id))objc_msgSend)(
            cls, sel_registerName("fileURLWithPath:"), path);

    id base_path = ((id (*)(id, SEL))objc_msgSend)(base_url, sel_registerName("path"));
    id combined_path = base_path
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              base_path, sel_registerName("stringByAppendingPathComponent:"), path)
        : path;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, sel_registerName("fileURLWithPath:"), combined_path);
}

static int ascii_equal_case_insensitive(const char* left, const char* right) {
    for (;; left++, right++) {
        char a = *left >= 'A' && *left <= 'Z' ? (char)(*left + 32) : *left;
        char b = *right >= 'A' && *right <= 'Z' ? (char)(*right + 32) : *right;
        if (a != b)
            return 0;
        if (!a)
            return 1;
    }
}

static int ascii_contains_case_insensitive(const char* text, const char* needle) {
    if (!text || !needle || !*needle)
        return 0;
    for (const char* start = text; *start; start++) {
        const char* a = start;
        const char* b = needle;
        while (*a && *b) {
            char ca = (*a >= 'A' && *a <= 'Z') ? *a + ('a' - 'A') : *a;
            char cb = (*b >= 'A' && *b <= 'Z') ? *b + ('a' - 'A') : *b;
            if (ca != cb)
                break;
            a++;
            b++;
        }
        if (!*b)
            return 1;
    }
    return 0;
}

// Cookies. Roblox on macOS keeps the login (.ROBLOSECURITY) in
// NSHTTPCookieStorage: its HTTP goes through libcurl, and it takes cookies
// from the storage (cookies, cookiesForURL:) and puts Set-Cookie results
// back (setCookies:forURL:mainDocumentURL:). Darling gets all of that wrong:
// its cookie parser crashes on a valid host-only Set-Cookie (it copies a
// missing Domain), setCookies:forURL:mainDocumentURL: does nothing,
// cookiesForURL: ignores the URL (every cookie for every URL, login included,
// also over plain http), and nothing is kept on disk. So Set-Cookie headers
// are parsed here (cookies built with +[NSHTTPCookie cookieWithProperties:],
// Domain always set) and the cookies are kept here (macncheese_cookie_store):
// the newest value wins, a URL gets only the cookies whose domain, path,
// Secure flag and expiry fit it, and persistent cookies are saved to
// ~/Library/MacNCheese/Cookies.plist (mode 0600, replaced atomically) and
// loaded back at startup.
#define MSG0(r, o, sel) ((r (*)(id, SEL))objc_msgSend)((id)(o), sel_registerName(sel))
#define MSG1(r, o, sel, a) ((r (*)(id, SEL, id))objc_msgSend)((id)(o), sel_registerName(sel), (a))
#define MSG2(r, o, sel, a, b) ((r (*)(id, SEL, id, id))objc_msgSend)((id)(o), sel_registerName(sel), (a), (b))
static id macncheese_nsstring(const char* text) {
    return ((id (*)(id, SEL, const char*))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), text);
}
static id macncheese_trimmed(id string) {
    id whitespace = MSG0(id, objc_getClass("NSCharacterSet"), "whitespaceAndNewlineCharacterSet");
    return MSG1(id, string, "stringByTrimmingCharactersInSet:", whitespace);
}
static id macncheese_cf_boolean(int value) {
    return ((id (*)(id, SEL, MacNCheeseBool))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), (MacNCheeseBool)(value != 0));
}

static id macncheese_http_date(id text) {
    id formatter = MSG0(id, MSG0(id, objc_getClass("NSDateFormatter"), "alloc"), "init");
    MSG1(void, formatter, "setLocale:",
         MSG1(id, objc_getClass("NSLocale"), "localeWithLocaleIdentifier:", macncheese_nsstring("en_US_POSIX")));
    MSG1(void, formatter, "setTimeZone:",
         MSG1(id, objc_getClass("NSTimeZone"), "timeZoneWithAbbreviation:", macncheese_nsstring("GMT")));
    static const char* formats[] = {"EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                    "EEE, dd-MMM-yy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"};
    id date = 0;
    for (int index = 0; index < 4 && !date; index++) {
        MSG1(void, formatter, "setDateFormat:", macncheese_nsstring(formats[index]));
        date = MSG1(id, formatter, "dateFromString:", text);
    }
    MSG0(void, formatter, "release");
    return date;
}

// Does `host` fall under cookie domain `domain` (both lowercase; a leading
// dot on the domain is ignored)?
static int macncheese_domain_matches(id host, id domain) {
    if (!host || !domain)
        return 0;
    if (MSG1(MacNCheeseBool, domain, "hasPrefix:", macncheese_nsstring(".")))
        domain = ((id (*)(id, SEL, unsigned long))objc_msgSend)(domain, sel_registerName("substringFromIndex:"), 1);
    if (!MSG0(unsigned long, domain, "length"))
        return 0;
    return MSG1(MacNCheeseBool, host, "isEqualToString:", domain) ||
           MSG1(MacNCheeseBool, host, "hasSuffix:", MSG1(id, macncheese_nsstring("."), "stringByAppendingString:", domain));
}

// Build one NSHTTPCookie from a single "name=value; attr; attr=value" string.
static id macncheese_cookie_from_string(id line, id url) {
    id parts = MSG1(id, line, "componentsSeparatedByString:", macncheese_nsstring(";"));
    unsigned long count = MSG0(unsigned long, parts, "count");
    if (!count)
        return 0;
    id first = macncheese_trimmed(MSG1(id, parts, "objectAtIndex:", (id)0));
    unsigned long equals = ((MacNCheeseRange (*)(id, SEL, id))objc_msgSend)(
        first, sel_registerName("rangeOfString:"), macncheese_nsstring("=")).location;
    if (equals == 0x7FFFFFFFFFFFFFFFUL || equals == 0)
        return 0;
    id properties = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
    MSG2(void, properties, "setObject:forKey:",
         macncheese_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringToIndex:"), equals)),
         macncheese_nsstring("Name"));
    MSG2(void, properties, "setObject:forKey:",
         ((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringFromIndex:"), equals + 1),
         macncheese_nsstring("Value"));
    id host = url ? MSG0(id, url, "host") : 0;
    MSG2(void, properties, "setObject:forKey:", host ? host : macncheese_nsstring("roblox.com"),
         macncheese_nsstring("Domain"));
    MSG2(void, properties, "setObject:forKey:", macncheese_nsstring("/"), macncheese_nsstring("Path"));
    // Darling's CFHTTPCookieIsSecure reads Secure with CFBooleanGetValue and
    // crashes when it is missing, so it is always set, as a CFBoolean.
    MSG2(void, properties, "setObject:forKey:", macncheese_cf_boolean(0), macncheese_nsstring("Secure"));
    for (unsigned long index = 1; index < count; index++) {
        id attribute = macncheese_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
            parts, sel_registerName("objectAtIndex:"), index));
        unsigned long split = ((MacNCheeseRange (*)(id, SEL, id))objc_msgSend)(
            attribute, sel_registerName("rangeOfString:"), macncheese_nsstring("=")).location;
        id key = split == 0x7FFFFFFFFFFFFFFFUL ? attribute
            : ((id (*)(id, SEL, unsigned long))objc_msgSend)(attribute, sel_registerName("substringToIndex:"), split);
        id value = split == 0x7FFFFFFFFFFFFFFFUL ? macncheese_nsstring("")
            : macncheese_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
                  attribute, sel_registerName("substringFromIndex:"), split + 1));
        const char* name = MSG0(const char*, MSG0(id, macncheese_trimmed(key), "lowercaseString"), "UTF8String");
        if (!name)
            continue;
        if (ascii_strings_equal(name, "domain") && MSG0(unsigned long, value, "length")) {
            // A server may only set cookies for its own domain (RFC 6265).
            if (host && !macncheese_domain_matches(MSG0(id, host, "lowercaseString"),
                                                 MSG0(id, value, "lowercaseString")))
                return 0;
            MSG2(void, properties, "setObject:forKey:", value, macncheese_nsstring("Domain"));
        } else if (ascii_strings_equal(name, "path") && MSG0(unsigned long, value, "length")) {
            MSG2(void, properties, "setObject:forKey:", value, macncheese_nsstring("Path"));
        } else if (ascii_strings_equal(name, "expires")) {
            id date = macncheese_http_date(value);
            if (date && !MSG1(id, properties, "objectForKey:", macncheese_nsstring("Max-Age")))
                MSG2(void, properties, "setObject:forKey:", date, macncheese_nsstring("Expires"));
        } else if (ascii_strings_equal(name, "max-age")) {
            double seconds = MSG0(double, value, "doubleValue");
            id date = ((id (*)(id, SEL, double))objc_msgSend)(
                (id)objc_getClass("NSDate"), sel_registerName("dateWithTimeIntervalSinceNow:"), seconds);
            MSG2(void, properties, "setObject:forKey:", date, macncheese_nsstring("Expires"));
            MSG2(void, properties, "setObject:forKey:", value, macncheese_nsstring("Max-Age"));
        } else if (ascii_strings_equal(name, "secure")) {
            MSG2(void, properties, "setObject:forKey:", macncheese_cf_boolean(1), macncheese_nsstring("Secure"));
        }
    }
    MSG1(void, properties, "removeObjectForKey:", macncheese_nsstring("Max-Age"));
    return MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", properties);
}

// Split a combined Set-Cookie header ("a=1; Expires=Wed, 21 Oct ...,b=2")
// at commas that start a new "name=" pair, not at commas inside dates.
static id macncheese_split_set_cookie(id header) {
    id result = MSG0(id, objc_getClass("NSMutableArray"), "array");
    const char* text = MSG0(const char*, header, "UTF8String");
    if (!text)
        return result;
    unsigned long start = 0, length = 0;
    while (text[length]) length++;
    for (unsigned long index = 0; index <= length; index++) {
        int boundary = index == length;
        if (!boundary && text[index] == ',') {
            unsigned long probe = index + 1;
            while (text[probe] == ' ') probe++;
            unsigned long name_end = probe;
            while (text[name_end] && text[name_end] != '=' && text[name_end] != ';' &&
                   text[name_end] != ',' && text[name_end] != ' ')
                name_end++;
            boundary = name_end > probe && text[name_end] == '=';
        }
        if (boundary) {
            if (index > start) {
                id piece = ((id (*)(id, SEL, const void*, unsigned long, unsigned long))objc_msgSend)(
                    MSG0(id, objc_getClass("NSString"), "alloc"),
                    sel_registerName("initWithBytes:length:encoding:"), text + start, index - start, 4UL);
                MSG1(void, result, "addObject:", piece);
                MSG0(void, piece, "release");
            }
            start = index + 1;
        }
    }
    return result;
}

static id (*orig_cookies_with_response_headers)(id, SEL, id, id) = 0;
static id cookies_with_response_headers(id cls, SEL cmd, id headers, id url) {
    (void)cls; (void)cmd;
    id cookies = MSG0(id, objc_getClass("NSMutableArray"), "array");
    id keys = headers ? MSG0(id, headers, "allKeys") : 0;
    unsigned long count = keys ? MSG0(unsigned long, keys, "count") : 0;
    for (unsigned long index = 0; index < count; index++) {
        id key = ((id (*)(id, SEL, unsigned long))objc_msgSend)(keys, sel_registerName("objectAtIndex:"), index);
        const char* key_text = key ? MSG0(const char*, key, "UTF8String") : 0;
        if (!key_text || !ascii_equal_case_insensitive(key_text, "set-cookie"))
            continue;
        id value = MSG1(id, headers, "objectForKey:", key);
        id lines = MSG1(MacNCheeseBool, value, "isKindOfClass:", (id)objc_getClass("NSArray"))
            ? value : macncheese_split_set_cookie(value);
        unsigned long line_count = MSG0(unsigned long, lines, "count");
        for (unsigned long line = 0; line < line_count; line++) {
            id cookie = macncheese_cookie_from_string(
                ((id (*)(id, SEL, unsigned long))objc_msgSend)(lines, sel_registerName("objectAtIndex:"), line), url);
            if (cookie)
                MSG1(void, cookies, "addObject:", cookie);
        }
    }
    return cookies;
}

extern int open(const char*, int, ...);
extern int close(int);
extern int rename(const char*, const char*);
extern int unlink(const char*);

// ~/Library/MacNCheese/Cookies.plist, the folder made private (0700).
static id macncheese_cookie_file(void) {
    static id file;
    if (file)
        return file;
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    id directory = MSG1(id, home, "stringByAppendingPathComponent:",
                        macncheese_nsstring("Library/MacNCheese"));
    ((MacNCheeseBool (*)(id, SEL, id, MacNCheeseBool, id, id*))objc_msgSend)(
        MSG0(id, objc_getClass("NSFileManager"), "defaultManager"),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    chmod(MSG0(const char*, directory, "fileSystemRepresentation"), 0700);
    file = MSG0(id, MSG1(id, directory, "stringByAppendingPathComponent:", macncheese_nsstring("Cookies.plist")),
                "retain");
    return file;
}

// The store: domain|path|name -> the cookie's properties (as saved), and
// -> the NSHTTPCookie handed out. Session cookies (no expiry date) are kept
// only in memory. Roblox's HTTP threads use it at the same time, so every
// access holds macncheese_cookie_lock; the NSMutableDictionary is not
// thread-safe.
static id macncheese_cookie_entries, macncheese_cookie_objects;
static volatile int macncheese_cookie_lock_word, macncheese_cookie_write_word;
static void macncheese_cookie_lock(void) {
    while (__sync_lock_test_and_set(&macncheese_cookie_lock_word, 1))
        macncheese_sleep_us(50);
}
static void macncheese_cookie_unlock(void) { __sync_lock_release(&macncheese_cookie_lock_word); }

static void macncheese_cookie_store_init(void) { // with the lock held
    if (!macncheese_cookie_entries) {
        macncheese_cookie_entries = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
        macncheese_cookie_objects = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
    }
}

static id macncheese_cookie_key(id domain, id path, id name) {
    return ((id (*)(id, SEL, id, ...))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithFormat:"),
        macncheese_nsstring("%@|%@|%@"), domain ? MSG0(id, domain, "lowercaseString") : macncheese_nsstring(""),
        path ? path : macncheese_nsstring("/"), name ? name : macncheese_nsstring(""));
}

static int macncheese_cookie_expired(id expires, id now) {
    return expires && MSG1(long, expires, "compare:", now) != 1 /* NSOrderedDescending */;
}

// Write the persistent cookies: to Cookies.plist.tmp, created 0600, then
// renamed over Cookies.plist, so a crash or a kill during the write never
// leaves a cut-off file (which logged the user out). One writer at a time,
// and the snapshot is taken by the writer, so the last write is the newest.
static void macncheese_save_cookies(void) {
    while (__sync_lock_test_and_set(&macncheese_cookie_write_word, 1))
        macncheese_sleep_us(1000);
    @autoreleasepool {
        id now = MSG0(id, objc_getClass("NSDate"), "date");
        id persistent = MSG0(id, objc_getClass("NSMutableArray"), "array");
        macncheese_cookie_lock();
        @try {
            id entries = macncheese_cookie_entries ? MSG0(id, macncheese_cookie_entries, "allValues") : 0;
            unsigned long count = entries ? MSG0(unsigned long, entries, "count") : 0;
            for (unsigned long index = 0; index < count; index++) {
                id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
                id expires = MSG1(id, entry, "objectForKey:", macncheese_nsstring("Expires"));
                if (expires && !macncheese_cookie_expired(expires, now))
                    MSG1(void, persistent, "addObject:", entry);
            }
        } @finally {
            macncheese_cookie_unlock();
        }
        id file = macncheese_cookie_file();
        id temporary = MSG1(id, file, "stringByAppendingString:", macncheese_nsstring(".tmp"));
        const char* temporary_path = MSG0(const char*, temporary, "fileSystemRepresentation");
        const char* file_path = MSG0(const char*, file, "fileSystemRepresentation");
        // Created private before any cookie is in it; the plist write keeps the mode.
        int fd = open(temporary_path, 0x1 /* O_WRONLY */ | 0x200 /* O_CREAT */ | 0x400 /* O_TRUNC */, 0600);
        if (fd >= 0) {
            close(fd);
            chmod(temporary_path, 0600);
            if (((MacNCheeseBool (*)(id, SEL, id, MacNCheeseBool))objc_msgSend)(
                    persistent, sel_registerName("writeToFile:atomically:"), temporary, 0))
                rename(temporary_path, file_path); // Darling leaves atomic writes as .tmpN files
            else
                unlink(temporary_path);
        }
    }
    __sync_lock_release(&macncheese_cookie_write_word);
}

// Put `cookie` into the store (or take it out); 1 if a persistent cookie
// changed, i.e. the file must be written.
static int macncheese_store_cookie(id cookie, int deleted) {
    if (!cookie)
        return 0;
    id name = MSG0(id, cookie, "name");
    id domain = MSG0(id, cookie, "domain");
    id path = MSG0(id, cookie, "path");
    if (!name || !domain)
        return 0;
    if (!path || !MSG0(unsigned long, path, "length"))
        path = macncheese_nsstring("/");
    id key = macncheese_cookie_key(domain, path, name);
    id expires = MSG0(id, cookie, "expiresDate");
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    if (macncheese_cookie_expired(expires, now))
        deleted = 1; // an expired Set-Cookie is how servers delete cookies
    id entry = 0, object = 0;
    if (!deleted) {
        entry = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
        MSG2(void, entry, "setObject:forKey:", name, macncheese_nsstring("Name"));
        id value = MSG0(id, cookie, "value");
        MSG2(void, entry, "setObject:forKey:", value ? value : macncheese_nsstring(""), macncheese_nsstring("Value"));
        MSG2(void, entry, "setObject:forKey:", domain, macncheese_nsstring("Domain"));
        MSG2(void, entry, "setObject:forKey:", path, macncheese_nsstring("Path"));
        if (expires)
            MSG2(void, entry, "setObject:forKey:", expires, macncheese_nsstring("Expires"));
        id properties = MSG0(id, cookie, "properties");
        id secure = properties ? MSG1(id, properties, "objectForKey:", macncheese_nsstring("Secure")) : 0;
        int is_secure = secure && ((MacNCheeseBool (*)(id, SEL, SEL))objc_msgSend)(secure, sel_registerName("respondsToSelector:"), sel_registerName("boolValue"))
            && MSG0(MacNCheeseBool, secure, "boolValue");
        MSG2(void, entry, "setObject:forKey:", macncheese_cf_boolean(is_secure), macncheese_nsstring("Secure"));
        object = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
        if (!object)
            return 0;
    }
    int changed = 0, persistent_changed = 0;
    macncheese_cookie_lock();
    @try {
        macncheese_cookie_store_init();
        id old = MSG1(id, macncheese_cookie_entries, "objectForKey:", key);
        int old_persistent = old && MSG1(id, old, "objectForKey:", macncheese_nsstring("Expires"));
        if (deleted) {
            changed = old != 0;
            persistent_changed = old_persistent;
            MSG1(void, macncheese_cookie_entries, "removeObjectForKey:", key);
            MSG1(void, macncheese_cookie_objects, "removeObjectForKey:", key);
        } else {
            changed = !old || !MSG1(MacNCheeseBool, old, "isEqualToDictionary:", entry);
            persistent_changed = changed && (old_persistent || expires);
            if (changed) {
                MSG2(void, macncheese_cookie_entries, "setObject:forKey:", entry, key);
                MSG2(void, macncheese_cookie_objects, "setObject:forKey:", object, key);
            }
        }
    } @finally {
        macncheese_cookie_unlock();
    }
    if (changed) { // one write per line: HTTP threads log at the same time
        char line[300];
        unsigned long used = 0;
        const char* parts[] = {"[MacNCheese Cookies] ", deleted ? "delete " : "set ",
                               MSG0(const char*, name, "UTF8String"), " domain=",
                               MSG0(const char*, domain, "UTF8String"),
                               deleted ? "\n" : (expires ? " persistent\n" : " session\n")};
        for (unsigned index = 0; index < sizeof parts / sizeof parts[0]; index++)
            for (const char* c = parts[index] ? parts[index] : "?"; *c && used < sizeof line - 2; c++)
                line[used++] = *c;
        if (used && line[used - 1] != '\n')
            line[used++] = '\n';
        write(2, line, used);
    }
    return persistent_changed;
}

// The store's cookies that fit `url` (all of them without a URL), and after
// them Darling's own that fit and that the store has no newer value of.
static id macncheese_cookies_for(id url, id darling_cookies) {
    id host = url ? MSG0(id, MSG0(id, url, "host"), "lowercaseString") : 0;
    if (url && !host)
        return MSG0(id, objc_getClass("NSMutableArray"), "array");
    id url_path = url ? MSG0(id, url, "path") : 0;
    if (!url_path || !MSG0(unsigned long, url_path, "length"))
        url_path = macncheese_nsstring("/");
    id scheme = url ? MSG0(id, MSG0(id, url, "scheme"), "lowercaseString") : 0;
    int secure_url = !url || MSG1(MacNCheeseBool, scheme, "isEqualToString:", macncheese_nsstring("https")) ||
                     MSG1(MacNCheeseBool, scheme, "isEqualToString:", macncheese_nsstring("wss"));
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    id result = MSG0(id, objc_getClass("NSMutableArray"), "array");
    id names = MSG0(id, objc_getClass("NSMutableSet"), "set");
    for (int pass = 0; pass < 2; pass++) {
        id cookies = darling_cookies;
        if (pass == 0) {
            macncheese_cookie_lock();
            @try {
                cookies = macncheese_cookie_objects ? MSG0(id, macncheese_cookie_objects, "allValues") : 0;
            } @finally {
                macncheese_cookie_unlock();
            }
        }
        unsigned long count = cookies ? MSG0(unsigned long, cookies, "count") : 0;
        for (unsigned long index = 0; index < count; index++) {
            id cookie = ((id (*)(id, SEL, unsigned long))objc_msgSend)(cookies, sel_registerName("objectAtIndex:"), index);
            id name = MSG0(id, cookie, "name");
            if (!name || (pass == 1 && MSG1(MacNCheeseBool, names, "containsObject:", name)))
                continue;
            if (macncheese_cookie_expired(MSG0(id, cookie, "expiresDate"), now))
                continue;
            if (url) {
                if (!macncheese_domain_matches(host, MSG0(id, MSG0(id, cookie, "domain"), "lowercaseString")))
                    continue;
                id path = MSG0(id, cookie, "path");
                unsigned long length = path ? MSG0(unsigned long, path, "length") : 0;
                // RFC 6265 path-match: the cookie path, then "/" or the end.
                if (length && !(MSG1(MacNCheeseBool, url_path, "isEqualToString:", path) ||
                                (MSG1(MacNCheeseBool, url_path, "hasPrefix:", path) &&
                                 (MSG1(MacNCheeseBool, path, "hasSuffix:", macncheese_nsstring("/")) ||
                                  ((unsigned short (*)(id, SEL, unsigned long))objc_msgSend)(
                                      url_path, sel_registerName("characterAtIndex:"), length) == '/'))))
                    continue;
                id properties = MSG0(id, cookie, "properties");
                id secure = properties ? MSG1(id, properties, "objectForKey:", macncheese_nsstring("Secure")) : 0;
                if (!secure_url && secure &&
                    ((MacNCheeseBool (*)(id, SEL, SEL))objc_msgSend)(secure, sel_registerName("respondsToSelector:"), sel_registerName("boolValue")) &&
                    MSG0(MacNCheeseBool, secure, "boolValue"))
                    continue;
            }
            MSG1(void, result, "addObject:", cookie);
            MSG1(void, names, "addObject:", name);
        }
    }
    return result;
}

static void (*orig_cookie_storage_set)(id, SEL, id) = 0;
static void hooked_cookie_storage_set(id self, SEL cmd, id cookie) {
    orig_cookie_storage_set(self, cmd, cookie);
    int save;
    @autoreleasepool {
        save = macncheese_store_cookie(cookie, 0);
    }
    if (save)
        macncheese_save_cookies();
}
static void (*orig_cookie_storage_set_many)(id, SEL, id, id, id) = 0;
static void hooked_cookie_storage_set_many(id self, SEL cmd, id cookies, id url, id main_url) {
    orig_cookie_storage_set_many(self, cmd, cookies, url, main_url);
    int save = 0;
    @autoreleasepool {
        unsigned long count = cookies ? MSG0(unsigned long, cookies, "count") : 0;
        for (unsigned long index = 0; index < count; index++)
            save |= macncheese_store_cookie(((id (*)(id, SEL, unsigned long))objc_msgSend)(
                cookies, sel_registerName("objectAtIndex:"), index), 0);
    }
    if (save)
        macncheese_save_cookies(); // once per batch
}
static void (*orig_cookie_storage_delete)(id, SEL, id) = 0;
static void hooked_cookie_storage_delete(id self, SEL cmd, id cookie) {
    orig_cookie_storage_delete(self, cmd, cookie);
    int save;
    @autoreleasepool {
        save = macncheese_store_cookie(cookie, 1);
    }
    if (save)
        macncheese_save_cookies();
}

static id (*orig_cookie_storage_for_url)(id, SEL, id) = 0;
static id hooked_cookie_storage_for_url(id self, SEL cmd, id url) {
    id darling = orig_cookie_storage_for_url(self, cmd, url);
    if (!url)
        return darling;
    id result;
    @autoreleasepool {
        result = MSG0(id, macncheese_cookies_for(url, darling), "copy");
    }
    return MSG0(id, result, "autorelease");
}

static id (*orig_cookie_storage_cookies)(id, SEL) = 0;
static id hooked_cookie_storage_cookies(id self, SEL cmd) {
    id darling = orig_cookie_storage_cookies(self, cmd);
    id result;
    @autoreleasepool {
        result = MSG0(id, macncheese_cookies_for(0, darling), "copy");
    }
    return MSG0(id, result, "autorelease");
}

// Only into this store, not Darling's: Darling hands out every cookie it
// has for every URL.
static void macncheese_load_cookies(void) {
    int loaded = 0;
    @autoreleasepool {
        id entries = MSG1(id, objc_getClass("NSArray"), "arrayWithContentsOfFile:", macncheese_cookie_file());
        unsigned long count = entries ? MSG0(unsigned long, entries, "count") : 0;
        id now = MSG0(id, objc_getClass("NSDate"), "date");
        macncheese_cookie_lock();
        @try {
            macncheese_cookie_store_init();
            for (unsigned long index = 0; index < count; index++) {
                id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
                if (!MSG1(MacNCheeseBool, entry, "isKindOfClass:", (id)objc_getClass("NSDictionary")))
                    continue;
                id expires = MSG1(id, entry, "objectForKey:", macncheese_nsstring("Expires"));
                if (!expires || macncheese_cookie_expired(expires, now))
                    continue;
                id cookie = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
                if (!cookie)
                    continue;
                id key = macncheese_cookie_key(MSG1(id, entry, "objectForKey:", macncheese_nsstring("Domain")),
                                             MSG1(id, entry, "objectForKey:", macncheese_nsstring("Path")),
                                             MSG1(id, entry, "objectForKey:", macncheese_nsstring("Name")));
                MSG2(void, macncheese_cookie_entries, "setObject:forKey:", entry, key);
                MSG2(void, macncheese_cookie_objects, "setObject:forKey:", cookie, key);
                loaded++;
            }
        } @finally {
            macncheese_cookie_unlock();
        }
    }
    write_str("[MacNCheese Cookies] loaded ");
    print_num(loaded);
    write_str(" saved cookies\n");
}

// Cocotron stores NSDisplay in thread-local state. Its X11 backend cannot open
// a second display for Roblox's rendering worker, although the main thread's
// display is already valid. Share the first successfully created display.
static id (*orig_current_display)(id, SEL) = 0;
static void *macncheese_shared_display;
static volatile int macncheese_display_lock;
static id shared_current_display(id cls, SEL cmd) {
    id shared = (id)__atomic_load_n(&macncheese_shared_display, __ATOMIC_ACQUIRE);
    if (shared)
        return shared;
    while (__sync_lock_test_and_set(&macncheese_display_lock, 1))
        macncheese_sleep_us(1000);
    @try {
        shared = (id)__atomic_load_n(&macncheese_shared_display, __ATOMIC_RELAXED);
        if (!shared) {
            id display = macncheese_wayland_enabled() ? macncheese_wayland_display()
                                                    : orig_current_display(cls, cmd);
            if (display) {
                shared = ((id (*)(id, SEL))objc_msgSend)(
                    display, sel_registerName("retain"));
                __atomic_store_n(&macncheese_shared_display, (void *)shared, __ATOMIC_RELEASE);
            }
        }
    } @finally {
        // Backend initialization may raise an exception. Let a caller retry
        // without leaving every display request waiting on this lock.
        __sync_lock_release(&macncheese_display_lock);
    }
    return shared;
}

__attribute__((constructor))
static void install_swizzles(void) {
    extern const char* getprogname(void);
    const char *prog = getprogname();
    if (prog && ascii_strings_equal(prog, "RobloxCrashHandler")) {
        write_str("[MacNCheese] Crashpad handler started.\n");
        return;
    }

    write_str("[MacNCheese] libMacNCheeseShims loaded.\n");
    long slide = _dyld_get_image_vmaddr_slide(0);
    write_str("[MacNCheese] Main executable ASLR slide: ");
    print_hex(slide);
    write_str("\n");

    // Let Darling and Crashpad own signals unless diagnosis is explicitly requested.
    const char *diagnose_signals = getenv("MACNCHEESE_DIAGNOSTIC_SIGNALS");
    if (diagnose_signals && *diagnose_signals == '1') {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        sigaction(11, &debug_action, 0);
    }

    Class eventManager = objc_getClass("NSAppleEventManager");
    SEL currentEvent = sel_registerName("currentAppleEvent");
    if (eventManager && !class_getInstanceMethod(eventManager, currentEvent)) {
        class_addMethod(eventManager, currentEvent, (IMP)no_current_apple_event, "@@:");
        write_str("[MacNCheese] Added currentAppleEvent=nil for direct launch\n");
    }

    Class url_class = objc_getClass("NSURL");
    SEL relative_file_url = sel_registerName("fileURLWithPath:relativeToURL:");
    if (url_class && !class_getClassMethod(url_class, relative_file_url)) {
        Class url_meta_class = object_getClass((id)url_class);
        if (url_meta_class && class_addMethod(url_meta_class, relative_file_url,
                                              (IMP)url_file_with_path_relative_to_url,
                                              "@@:@@"))
            write_str("[MacNCheese] Added NSURL fileURLWithPath:relativeToURL:\n");
    }

    Class event_class = objc_getClass("NSEvent");
    if (event_class) {
        SEL phase = sel_registerName("phase");
        SEL momentum_phase = sel_registerName("momentumPhase");
        if (!class_getInstanceMethod(event_class, phase) &&
            class_addMethod(event_class, phase, (IMP)event_phase_none, "Q@:"))
            write_str("[MacNCheese] Added NSEvent phase=None\n");
        if (!class_getInstanceMethod(event_class, momentum_phase) &&
            class_addMethod(event_class, momentum_phase,
                            (IMP)event_phase_none, "Q@:"))
            write_str("[MacNCheese] Added NSEvent momentumPhase=None\n");
    }

    Class process_info_class = objc_getClass("NSProcessInfo");
    if (process_info_class) {
        SEL thermal_state = sel_registerName("thermalState");
        SEL low_power = sel_registerName("isLowPowerModeEnabled");
        if (!class_getInstanceMethod(process_info_class, thermal_state) &&
            class_addMethod(process_info_class, thermal_state,
                            (IMP)process_info_thermal_state_nominal, "q@:"))
            write_str("[MacNCheese] Added NSProcessInfo thermalState=nominal\n");
        if (!class_getInstanceMethod(process_info_class, low_power) &&
            class_addMethod(process_info_class, low_power,
                            (IMP)process_info_low_power_mode_disabled, "B@:"))
            write_str("[MacNCheese] Added NSProcessInfo lowPowerMode=false\n");
    }

    Class gl_context_class = objc_getClass("NSOpenGLContext");
    if (gl_context_class) {
        Method method = class_getInstanceMethod(
            gl_context_class, sel_registerName("initWithFormat:shareContext:"));
        if (method) {
            orig_gl_context_init =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_init);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("setView:"));
        if (method) {
            orig_gl_context_set_view =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_set_view);
        }
        method = class_getInstanceMethod(
            gl_context_class, sel_registerName("makeCurrentContext"));
        if (method) {
            orig_gl_context_make_current =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_make_current);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("flushBuffer"));
        if (method) {
            orig_gl_context_flush =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_flush);
        }
        write_str("[MacNCheese] Tracing NSOpenGLContext drawable presentation\n");
    }

    Class layer_context_class = objc_getClass("CALayerContext");
    if (layer_context_class) {
        Method method = class_getInstanceMethod(
            layer_context_class, sel_registerName("renderLayer:"));
        if (method) {
            orig_layer_context_render_layer =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_layer_context_render_layer);
            write_str("[MacNCheese] Hooked CALayerContext renderLayer: (restores GL context)\n");
        }
    }

    Class ca_renderer_class = objc_getClass("CARenderer");
    if (ca_renderer_class) {
        Method method = class_getInstanceMethod(
            ca_renderer_class, sel_registerName("_renderLayer:z:currentTime:"));
        if (method) {
            orig_ca_renderer_render_layer =
                (void (*)(id, SEL, id, double, double))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_ca_renderer_render_layer);
            write_str("[MacNCheese] Hooked CARenderer image upload (empty layers remain transparent)\n");
        }
    }

    Class scroll_event_class = objc_getClass("NSEvent");
    if (scroll_event_class) {
        struct { const char* name; IMP imp; const char* types; } event_methods[] = {
            {"hasPreciseScrollingDeltas", (IMP)event_has_precise_scrolling_deltas, "c@:"},
            {"isDirectionInvertedFromDevice", (IMP)event_is_direction_inverted, "c@:"},
            {"scrollingDeltaX", (IMP)event_scrolling_delta_x, "d@:"},
            {"scrollingDeltaY", (IMP)event_scrolling_delta_y, "d@:"},
        };
        for (unsigned long index = 0;
             index < sizeof(event_methods) / sizeof(event_methods[0]); index++) {
            SEL selector = sel_registerName(event_methods[index].name);
            if (!class_getInstanceMethod(scroll_event_class, selector) &&
                class_addMethod(scroll_event_class, selector, event_methods[index].imp,
                                event_methods[index].types)) {
                write_str("[MacNCheese] Added NSEvent ");
                write_str(event_methods[index].name);
                write_str("\n");
            }
        }
    }

    macncheese_install_late_hooks();

    Class archiver_meta = object_getClass((id)objc_getClass("NSKeyedArchiver"));
    Class unarchiver_meta = object_getClass((id)objc_getClass("NSKeyedUnarchiver"));
    SEL archive = sel_registerName("archivedDataWithRootObject:requiringSecureCoding:error:");
    SEL unarchive = sel_registerName("unarchivedObjectOfClass:fromData:error:");
    if (archiver_meta && !class_getInstanceMethod(archiver_meta, archive) &&
        class_addMethod(archiver_meta, archive, (IMP)keyed_archiver_archived_data, "@@:@c^@"))
        write_str("[MacNCheese] Added +[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:]\n");
    if (unarchiver_meta && !class_getInstanceMethod(unarchiver_meta, unarchive) &&
        class_addMethod(unarchiver_meta, unarchive, (IMP)keyed_unarchiver_unarchived_object, "@@:#@^@"))
        write_str("[MacNCheese] Added +[NSKeyedUnarchiver unarchivedObjectOfClass:fromData:error:]\n");

    const char* hide_menu = getenv("MACNCHEESE_HIDE_MENU_BAR");
    Class menu_view_class = objc_getClass("NSMainMenuView");
    if (hide_menu && hide_menu[0] == '1' && menu_view_class) {
        Method method = class_getClassMethod(menu_view_class, sel_registerName("menuHeight"));
        if (method) {
            method_setImplementation(method, (IMP)macncheese_zero_menu_height);
            write_str("[MacNCheese] Menu bar hidden\n");
        }
    }

    Class cookie_class = objc_getClass("NSHTTPCookie");
    if (cookie_class) {
        SEL parse_cookies = sel_registerName("cookiesWithResponseHeaderFields:forURL:");
        Method method = class_getClassMethod(cookie_class, parse_cookies);
        if (method) {
            orig_cookies_with_response_headers =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)cookies_with_response_headers);
            write_str("[MacNCheese] Hooked NSHTTPCookie response parser\n");
        }
        Class storage_class = objc_getClass("NSHTTPCookieStorage");
        Method set_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("setCookie:")) : 0;
        Method delete_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("deleteCookie:")) : 0;
        if (set_method && delete_method) {
            orig_cookie_storage_set = (void (*)(id, SEL, id))method_getImplementation(set_method);
            method_setImplementation(set_method, (IMP)hooked_cookie_storage_set);
            orig_cookie_storage_delete = (void (*)(id, SEL, id))method_getImplementation(delete_method);
            method_setImplementation(delete_method, (IMP)hooked_cookie_storage_delete);
            Method for_url = class_getInstanceMethod(storage_class, sel_registerName("cookiesForURL:"));
            if (for_url) {
                orig_cookie_storage_for_url = (id (*)(id, SEL, id))method_getImplementation(for_url);
                method_setImplementation(for_url, (IMP)hooked_cookie_storage_for_url);
            }
            Method all = class_getInstanceMethod(storage_class, sel_registerName("cookies"));
            if (all) {
                orig_cookie_storage_cookies = (id (*)(id, SEL))method_getImplementation(all);
                method_setImplementation(all, (IMP)hooked_cookie_storage_cookies);
            }
            Method set_many = class_getInstanceMethod(
                storage_class, sel_registerName("setCookies:forURL:mainDocumentURL:"));
            if (set_many) {
                orig_cookie_storage_set_many =
                    (void (*)(id, SEL, id, id, id))method_getImplementation(set_many);
                method_setImplementation(set_many, (IMP)hooked_cookie_storage_set_many);
            }
            macncheese_load_cookies();
        }
    }

    Class display_class = objc_getClass("NSDisplay");
    if (display_class) {
        SEL current_display = sel_registerName("currentDisplay");
        Method method = class_getClassMethod(display_class, current_display);
        if (method) {
            orig_current_display = (id (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)shared_current_display);
            write_str("[MacNCheese] Sharing NSDisplay across rendering threads\n");
        }
    }

    Class web_preferences_class = objc_getClass("WebPreferences");
    if (web_preferences_class) {
        class_addMethod(web_preferences_class, sel_registerName("setPlugInsEnabled:"),
                        (IMP)web_preferences_set_plugins_enabled, "v@:c");
        class_addMethod(web_preferences_class, sel_registerName("plugInsEnabled"),
                        (IMP)web_preferences_plugins_enabled, "c@:");
    }
    SEL standard_preferences = sel_registerName("standardPreferences");
    if (web_preferences_class &&
        !class_getClassMethod(web_preferences_class, standard_preferences)) {
        Class web_preferences_meta_class = object_getClass((id)web_preferences_class);
        if (web_preferences_meta_class &&
            class_addMethod(web_preferences_meta_class, standard_preferences,
                            (IMP)web_preferences_standard_preferences, "@@:"))
            write_str("[MacNCheese] Added WebPreferences standardPreferences\n");
    }

    Class capture_device_class = objc_getClass("AVCaptureDevice");
    if (capture_device_class) {
        Class capture_device_meta_class = object_getClass((id)capture_device_class);
        SEL devices = sel_registerName("devices");
        SEL devices_for_type = sel_registerName("devicesWithMediaType:");
        SEL default_for_type = sel_registerName("defaultDeviceWithMediaType:");
        if (!class_getClassMethod(capture_device_class, devices) &&
            class_addMethod(capture_device_meta_class, devices,
                            (IMP)empty_capture_devices, "@@:"))
            write_str("[MacNCheese] Added empty AVCaptureDevice devices inventory\n");
        if (!class_getClassMethod(capture_device_class, devices_for_type) &&
            class_addMethod(capture_device_meta_class, devices_for_type,
                            (IMP)empty_capture_devices_for_media_type, "@@:@"))
            write_str("[MacNCheese] Added empty AVCaptureDevice devicesWithMediaType:\n");
        if (!class_getClassMethod(capture_device_class, default_for_type) &&
            class_addMethod(capture_device_meta_class, default_for_type,
                            (IMP)no_default_capture_device, "@@:@"))
            write_str("[MacNCheese] Added AVCaptureDevice defaultDeviceWithMediaType:=nil\n");
        // Voice chat asks for microphone permission through these (Darling
        // has neither): granted, the host's own permissions apply.
        SEL authorization = sel_registerName("authorizationStatusForMediaType:");
        SEL request_access = sel_registerName("requestAccessForMediaType:completionHandler:");
        if (!class_getClassMethod(capture_device_class, authorization) &&
            class_addMethod(capture_device_meta_class, authorization,
                            (IMP)capture_authorization_status, "q@:@") &&
            class_addMethod(capture_device_meta_class, request_access,
                            (IMP)capture_request_access, "v@:@@?"))
            write_str("[MacNCheese] Added AVCaptureDevice media permission (granted)\n");
    }

    Class layerCls = objc_getClass("CALayer");
    if (layerCls && !class_getInstanceMethod(layerCls, sel_registerName("setContentsScale:"))
                 && !class_getInstanceMethod(layerCls, sel_registerName("contentsScale"))) {
        class_addMethod(layerCls, sel_registerName("setContentsScale:"), (IMP)layer_set_contents_scale, "v@:d");
        class_addMethod(layerCls, sel_registerName("contentsScale"), (IMP)layer_contents_scale, "d@:");
        write_str("[MacNCheese] Added CALayer contentsScale state (1x rendering only)\n");
    }

    Class viewCls = objc_getClass("NSView");
    if (viewCls && !class_getInstanceMethod(viewCls, sel_registerName("setAllowedTouchTypes:"))
                && !class_getInstanceMethod(viewCls, sel_registerName("allowedTouchTypes"))) {
        class_addMethod(viewCls, sel_registerName("setAllowedTouchTypes:"), (IMP)view_set_allowed_touch_types, "v@:Q");
        class_addMethod(viewCls, sel_registerName("allowedTouchTypes"), (IMP)view_allowed_touch_types, "Q@:");
        write_str("[MacNCheese] Added NSView allowedTouchTypes state (no touch synthesis)\n");
    }
    SEL backingSize = sel_registerName("convertSizeToBacking:");
    if (viewCls && !class_getInstanceMethod(viewCls, backingSize)) {
        class_addMethod(viewCls, backingSize, (IMP)backing_size_1x,
                        "{CGSize=dd}@:{CGSize=dd}");
        write_str("[MacNCheese] Added NSView convertSizeToBacking: (experimental 1x)\n");
    }


    Class window_class = objc_getClass("NSWindow");
    if (window_class) {
        SEL rect_from_screen = sel_registerName("convertRectFromScreen:");
        SEL rect_to_screen = sel_registerName("convertRectToScreen:");
        const char* rect_conversion_types =
            "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}";
        if (!class_getInstanceMethod(window_class, rect_from_screen) &&
            class_addMethod(window_class, rect_from_screen,
                            (IMP)window_convert_rect_from_screen,
                            rect_conversion_types))
            write_str("[MacNCheese] Added NSWindow convertRectFromScreen:\n");
        if (!class_getInstanceMethod(window_class, rect_to_screen) &&
            class_addMethod(window_class, rect_to_screen,
                            (IMP)window_convert_rect_to_screen,
                            rect_conversion_types))
            write_str("[MacNCheese] Added NSWindow convertRectToScreen:\n");
        struct { const char* name; IMP imp; const char* types; } titlebar_methods[] = {
            {"setTitlebarAppearsTransparent:", (IMP)window_set_titlebar_appears_transparent, "v@:c"},
            {"titlebarAppearsTransparent", (IMP)window_titlebar_appears_transparent, "c@:"},
            {"setTitleVisibility:", (IMP)window_set_title_visibility, "v@:q"},
            {"titleVisibility", (IMP)window_title_visibility, "q@:"},
        };
        int titlebar_added = 0;
        for (unsigned long i = 0; i < sizeof titlebar_methods / sizeof titlebar_methods[0]; i++) {
            SEL selector = sel_registerName(titlebar_methods[i].name);
            if (!class_getInstanceMethod(window_class, selector) &&
                class_addMethod(window_class, selector, titlebar_methods[i].imp, titlebar_methods[i].types))
                titlebar_added++;
        }
        if (titlebar_added)
            write_str("[MacNCheese] Added NSWindow title bar options missing in this Darling\n");
        SEL win_at_pt = sel_registerName("windowNumberAtPoint:belowWindowWithWindowNumber:");
        Method mWinAtPt = class_getClassMethod(window_class, win_at_pt);
        if (mWinAtPt) {
            method_setImplementation(mWinAtPt, (IMP)window_number_at_point);
        } else {
            class_addMethod(object_getClass((id)window_class), win_at_pt,
                            (IMP)window_number_at_point, "q@:{CGPoint=dd}q");
        }
        write_str("[MacNCheese] Implemented +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]\n");
    }

    Class ccls = objc_getClass("NSConcreteScanner");
    if (ccls) {
        Method m = class_getInstanceMethod(ccls, sel_registerName("initWithString:"));
        if (m) {
            orig_concrete_initWithString = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_concrete_initWithString);
            write_str("[MacNCheese] Hooked NSConcreteScanner initWithString:\n");
        }
    }

    Class appCls = objc_getClass("NSApplication");
    if (appCls) {
        Method mRun = class_getInstanceMethod(appCls, sel_registerName("run"));
        if (mRun) {
            orig_app_run = (void (*)(id, SEL))method_getImplementation(mRun);
            method_setImplementation(mRun, (IMP)hooked_app_run);
            write_str("[MacNCheese] Hooked NSApplication run\n");
        }
        Method mFinish = class_getInstanceMethod(appCls, sel_registerName("finishLaunching"));
        if (mFinish) {
            orig_app_finish_launching =
                (void (*)(id, SEL))method_getImplementation(mFinish);
            method_setImplementation(mFinish, (IMP)hooked_app_finish_launching);
            write_str("[MacNCheese] Hooked NSApplication finishLaunching\n");
        }
        Method mTerm = class_getInstanceMethod(appCls, sel_registerName("terminate:"));
        if (mTerm) {
            orig_app_terminate = (void (*)(id, SEL, id))method_getImplementation(mTerm);
            method_setImplementation(mTerm, (IMP)hooked_app_terminate);
            write_str("[MacNCheese] Hooked NSApplication terminate:\n");
        }
        Method mCheck = class_getInstanceMethod(appCls, sel_registerName("_checkForTerminate"));
        if (mCheck) {
            method_setImplementation(mCheck, (IMP)hooked_app_check_for_terminate);
            write_str("[MacNCheese] Neutralized NSApplication _checkForTerminate\n");
        }
        Method mDel = class_getInstanceMethod(appCls, sel_registerName("setDelegate:"));
        if (mDel) {
            orig_app_setDelegate = (void (*)(id, SEL, id))method_getImplementation(mDel);
            method_setImplementation(mDel, (IMP)hooked_app_setDelegate);
            write_str("[MacNCheese] Hooked NSApplication setDelegate:\n");
        }
    }

    Class bndlCls = objc_getClass("NSBundle");
    if (bndlCls) {
        Method mNib = class_getClassMethod(bndlCls, sel_registerName("loadNibNamed:owner:"));
        if (mNib) {
            orig_loadNibNamed = (signed char (*)(id, SEL, id, id))method_getImplementation(mNib);
            method_setImplementation(mNib, (IMP)hooked_loadNibNamed);
            write_str("[MacNCheese] Hooked NSBundle loadNibNamed:owner:\n");
        }
    }

    Class nibCls = objc_getClass("NSNib");
    if (nibCls) {
        Method mInst = class_getInstanceMethod(nibCls, sel_registerName("instantiateNibWithExternalNameTable:"));
        if (mInst) {
            orig_instantiateNib = (signed char (*)(id, SEL, id))method_getImplementation(mInst);
            method_setImplementation(mInst, (IMP)hooked_instantiateNib);
            write_str("[MacNCheese] Hooked NSNib instantiateNibWithExternalNameTable:\n");
        }
    }

    Class unarchCls = objc_getClass("NSKeyedUnarchiver");
    if (unarchCls) {
        Method m = class_getInstanceMethod(unarchCls, sel_registerName("decodeObjectForKey:"));
        if (m) {
            orig_decodeObjectForKey = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_decodeObjectForKey);
            write_str("[MacNCheese] Hooked NSKeyedUnarchiver decodeObjectForKey:\n");
        }
    }

    Class wtCls = objc_getClass("NSWindowTemplate");
    if (wtCls) {
        Method mWT = class_getInstanceMethod(wtCls, sel_registerName("initWithCoder:"));
        if (mWT) {
            orig_wt_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mWT);
            method_setImplementation(mWT, (IMP)hooked_wt_initWithCoder);
            write_str("[MacNCheese] Hooked NSWindowTemplate initWithCoder:\n");
        }
    }

    Class odCls = objc_getClass("NSIBObjectData");
    if (odCls) {
        Method mOD = class_getInstanceMethod(odCls, sel_registerName("initWithCoder:"));
        if (mOD) {
            orig_od_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mOD);
            method_setImplementation(mOD, (IMP)hooked_od_initWithCoder);
            write_str("[MacNCheese] Hooked NSIBObjectData initWithCoder:\n");
        }
        Method mODE = class_getInstanceMethod(odCls, sel_registerName("establishConnections"));
        if (mODE) {
            orig_od_establish = (void (*)(id, SEL))method_getImplementation(mODE);
            method_setImplementation(mODE, (IMP)hooked_od_establish);
            write_str("[MacNCheese] Hooked NSIBObjectData establishConnections\n");
        }
    }

    Class connCls = objc_getClass("NSNibConnector");
    if (connCls) {
        Method mC = class_getInstanceMethod(connCls, sel_registerName("establishConnection"));
        if (mC) {
            orig_conn_establish = (void (*)(id, SEL))method_getImplementation(mC);
            method_setImplementation(mC, (IMP)hooked_conn_establish);
            write_str("[MacNCheese] Hooked NSNibConnector establishConnection\n");
        }
    }

    Class winCls = objc_getClass("NSWindow");
    if (winCls) {
        Method mW = class_getInstanceMethod(winCls, sel_registerName("initWithContentRect:styleMask:backing:defer:"));
        if (mW) {
            orig_win_init = (id (*)(id, SEL, MacNCheeseRect, unsigned long, unsigned long, MacNCheeseBool))method_getImplementation(mW);
            method_setImplementation(mW, (IMP)hooked_win_init);
            write_str("[MacNCheese] Hooked NSWindow initWithContentRect:...\n");
        }
    }
}

__attribute__((objc_root_class))
@interface NSObject { Class isa; }
@end

// Foundation Objective-C classes
@interface NSBackgroundActivityScheduler : NSObject @end
@implementation NSBackgroundActivityScheduler @end

// Foundation constants
const void* NSHTTPCookieDomain = @"Domain";
const void* NSHTTPCookieExpires = @"Expires";
const void* NSHTTPCookieName = @"Name";
const void* NSHTTPCookiePath = @"Path";
const void* NSHTTPCookieSecure = @"Secure";
const void* NSHTTPCookieValue = @"Value";
const void* NSHTTPCookieVersion = @"Version";
// Foundation's value (Darling's CoreFoundation exports the same string; with
// a flat namespace this definition wins, so it must be equal).
const void* NSLocalizedDescriptionKey = @"NSLocalizedDescription";
const void* NSProcessInfoThermalStateDidChangeNotification = @"NSProcessInfoThermalStateDidChangeNotification";
const void* NSProcessInfoPowerStateDidChangeNotification = @"NSProcessInfoPowerStateDidChangeNotification";

// Carbon constants
const void* kTISNotifySelectedKeyboardInputSourceChanged = @"kTISNotifySelectedKeyboardInputSourceChanged";
const void* kTISPropertyInputSourceLanguages = @"kTISPropertyInputSourceLanguages";
const void* kTISPropertyUnicodeKeyLayoutData = @"kTISPropertyUnicodeKeyLayoutData";

// The original Carbon compatibility framework returned NULL for the current
// keyboard source and all of its properties. Roblox copies the Unicode layout
// data during startup, so that placeholder becomes CFDataCreateCopy(NULL) and
// crashes in CFDataGetLength. Keep real Objective-C objects alive for the
// process and interpose the three Text Input Source entry points.
static id macncheese_keyboard_source;
static id macncheese_keyboard_layout_data;
static id macncheese_keyboard_languages;

// Built by one thread; the source is published last, so a thread that sees
// it also sees the layout data (another thread used to get a NULL layout,
// the very crash this avoids).
static void macncheese_initialize_keyboard_source(void) {
    static volatile int state; // 0 new, 1 building, 2 done
    if (state == 2)
        return;
    if (!__sync_bool_compare_and_swap(&state, 0, 1)) {
        while (state != 2)
            macncheese_sleep_us(100);
        return;
    }
    Class object_class = objc_getClass("NSObject");
    Class data_class = objc_getClass("NSMutableData");
    Class array_class = objc_getClass("NSArray");
    if (object_class && data_class && array_class) {
        id data = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            (id)data_class, sel_registerName("dataWithLength:"), 4096UL);
        macncheese_keyboard_layout_data = data
            ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain")) : 0;
        id languages = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)array_class, sel_registerName("arrayWithObject:"), @"en");
        macncheese_keyboard_languages = languages
            ? ((id (*)(id, SEL))objc_msgSend)(languages, sel_registerName("retain")) : 0;
        id source = ((id (*)(id, SEL))objc_msgSend)((id)object_class, sel_registerName("new"));
        __sync_synchronize();
        macncheese_keyboard_source = source;
    }
    __sync_synchronize();
    state = 2;
}

void* TISCopyCurrentKeyboardInputSource(void) {
    macncheese_initialize_keyboard_source();
    return macncheese_keyboard_source
        ? ((id (*)(id, SEL))objc_msgSend)(macncheese_keyboard_source, sel_registerName("retain")) : 0;
}

void* TISCopyCurrentKeyboardLayoutInputSource(void) {
    return TISCopyCurrentKeyboardInputSource();
}

const void* TISGetInputSourceProperty(void* source, const void* key) {
    (void)source;
    macncheese_initialize_keyboard_source();
    if (key == kTISPropertyInputSourceLanguages)
        return macncheese_keyboard_languages;
    if (key == kTISPropertyUnicodeKeyLayoutData)
        return macncheese_keyboard_layout_data;
    return 0;
}

// The zero-filled CFData above is only a non-null compatibility token. Avoid
// parsing it as a UCKeyboardLayout until Darling provides a real Carbon layout.
int UCKeyTranslate(const void* layout, unsigned short key_code,
                   unsigned short key_action, unsigned int modifiers,
                   unsigned int keyboard_type, unsigned int options,
                   unsigned int* dead_key_state,
                   unsigned long max_length,
                   unsigned long* actual_length,
                   unsigned short* unicode_string) {
    (void)layout; (void)key_code; (void)key_action; (void)modifiers;
    (void)keyboard_type; (void)options; (void)max_length; (void)unicode_string;
    if (dead_key_state)
        *dead_key_state = 0;
    if (actual_length)
        *actual_length = 0;
    return 0;
}

// CoreServices constants
const void* kUTTagClassFilenameExtension = @"public.filename-extension";
const void* kUTTypeImage = @"public.image";
const void* kUTTypeMovie = @"public.movie";

// CoreVideo constants
const void* kCVPixelBufferCGBitmapContextCompatibilityKey = @"kCVPixelBufferCGBitmapContextCompatibilityKey";
const void* kCVPixelBufferCGImageCompatibilityKey = @"kCVPixelBufferCGImageCompatibilityKey";

// GameController constants
const void* GCControllerDidConnectNotification = @"GCControllerDidConnectNotification";
const void* GCControllerDidDisconnectNotification = @"GCControllerDidDisconnectNotification";

// SystemConfiguration constants
const void* kSCNetworkInterfaceTypeEthernet = @"Ethernet";
const void* kSCNetworkInterfaceTypeIEEE80211 = @"IEEE80211";

// VideoToolbox constants
const void* kVTDecompressionPropertyKey_RealTime = @"RealTime";
const void* kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = @"RequireHardwareAcceleratedVideoDecoder";
const void* kVTVideoEncoderList_CodecType = @"CodecType";
const void* kVTVideoEncoderList_EncoderName = @"EncoderName";

#ifndef MACNCHEESE_GRAPHICS_CONTEXT_H
#define MACNCHEESE_GRAPHICS_CONTEXT_H

/* EGL outcomes are recorded before Darling discards them in its CGL layer. */
typedef struct {
    void *previous;
    unsigned long binding_serial;
    void **surface_slot;
    void *previous_surface;
} macncheese_context_change;

int macncheese_begin_context_change(macncheese_context_change *change);
int macncheese_finish_context_change(const macncheese_context_change *change, int cgl_error);
void macncheese_record_egl_binding(unsigned int succeeded, void *context);
void macncheese_register_egl_context(void *context);
void macncheese_forget_egl_context(void *context);
int macncheese_graphics_first_draw(void);
void macncheese_record_egl_swap(unsigned int succeeded);
unsigned long macncheese_egl_swap_serial(void);
int macncheese_finish_cgl_swap(unsigned long serial, int cgl_error);
int macncheese_bind_desktop_gl(void);
int macncheese_egl_binding_error(void);
int macncheese_capture_egl_error(void);
int macncheese_graphics_get_error(void);

/* Return an owned, terminated copy, or NULL on allocation/invalid input. */
int *macncheese_copy_pixel_attributes(const int *attributes);

#endif

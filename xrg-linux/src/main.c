#include <gtk/gtk.h>
#include <glib.h>
#include <stdio.h>
#include <gdk/gdkkeysyms.h>
#include "core/preferences.h"
#include "core/dataset.h"
#include "core/utils.h"
#include "collectors/cpu_collector.h"
#include "collectors/memory_collector.h"
#include "collectors/network_collector.h"
#include "collectors/disk_collector.h"
#include "collectors/gpu_collector.h"
#include "collectors/battery_collector.h"
#include "collectors/sensors_collector.h"
#include "collectors/aitoken_collector.h"
#include "collectors/aitoken_pricing.h"
#include "collectors/process_collector.h"
#include "collectors/tpu_collector.h"
#include "ui/preferences_window.h"

#define SNAP_DISTANCE 20  /* Pixels from edge to snap */
#define TITLE_BAR_HEIGHT 20
/* Width of the left-clickable "menu dots" hit zone at the title bar's right edge */
#define MENU_DOTS_HIT_WIDTH 40

/* Application state */
typedef struct {
    GtkWidget *window;
    GtkWidget *vbox;
    GtkWidget *title_bar;
    GtkWidget *resize_grip;
    GtkWidget *cpu_box;
    GtkWidget *cpu_drawing_area;
    GtkWidget *memory_box;
    GtkWidget *memory_drawing_area;
    GtkWidget *network_box;
    GtkWidget *network_drawing_area;
    GtkWidget *disk_box;
    GtkWidget *disk_drawing_area;
    GtkWidget *gpu_box;
    GtkWidget *gpu_drawing_area;
    GtkWidget *battery_box;
    GtkWidget *battery_drawing_area;
    GtkWidget *sensors_box;
    GtkWidget *sensors_drawing_area;
    GtkWidget *aitoken_box;
    GtkWidget *aitoken_drawing_area;
    GtkWidget *process_box;
    GtkWidget *process_drawing_area;
    GtkWidget *tpu_box;
    GtkWidget *tpu_drawing_area;
    XRGPreferences *prefs;
    XRGCPUCollector *cpu_collector;
    XRGMemoryCollector *memory_collector;
    XRGNetworkCollector *network_collector;
    XRGDiskCollector *disk_collector;
    XRGGPUCollector *gpu_collector;
    XRGBatteryCollector *battery_collector;
    XRGSensorsCollector *sensors_collector;
    XRGAITokenCollector *aitoken_collector;
    XRGProcessCollector *process_collector;
    XRGTPUCollector *tpu_collector;
    XRGPreferencesWindow *prefs_window;
    guint update_timer_id;

    /* Dragging state */
    gboolean is_dragging;
    gint drag_start_x;
    gint drag_start_y;
    gint window_start_x;
    gint window_start_y;

    /* Resizing state */
    gboolean is_resizing;
    gint resize_start_x;
    gint resize_start_y;
    gint resize_start_width;
    gint resize_start_height;

    /* Layout state */
    XRGLayoutOrientation current_layout_orientation;
    GtkWidget *overlay;  /* Parent of vbox for easy recreation */

    /* Debounced save state */
    guint save_timeout_id;  /* Timer for debounced preferences save */
} AppState;

/* Forward declarations */
static void on_activate(GtkApplication *app, gpointer user_data);
static GtkWidget* create_title_bar(AppState *state);
static GtkWidget* create_resize_grip(AppState *state);
static void on_title_bar_realize(GtkWidget *widget, gpointer user_data);
static void on_resize_grip_realize(GtkWidget *widget, gpointer user_data);
static gboolean on_window_configure(GtkWidget *widget, GdkEventConfigure *event, gpointer user_data);
static gboolean on_title_bar_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_title_bar_button_release(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_title_bar_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_title_bar_context_menu(AppState *state, GdkEventButton *event);
static void on_menu_preferences(GtkMenuItem *item, gpointer user_data);
static void on_menu_aitoken_settings(GtkMenuItem *item, gpointer user_data);
static void on_menu_tpu_settings(GtkMenuItem *item, gpointer user_data);
static void on_menu_always_on_top(GtkCheckMenuItem *item, gpointer user_data);
static void on_menu_reset_position(GtkMenuItem *item, gpointer user_data);
static void on_menu_about(GtkMenuItem *item, gpointer user_data);
static void on_menu_quit(GtkMenuItem *item, gpointer user_data);
static gboolean on_draw_title_bar(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_draw_cpu(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_cpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_cpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_cpu_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_memory(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_memory_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_memory_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_memory_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_network(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_network_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_network_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_network_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_disk(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_disk_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_disk_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_disk_context_menu(AppState *state, GdkEventButton *event);

/* Helper function to get gradient color for activity bars based on position */
static void get_activity_bar_gradient_color(gdouble position, XRGPreferences *prefs, GdkRGBA *out_color) {
    /* position: 0.0 = bottom (start), 1.0 = top (end) */
    /* Gradient: fg1 (cyan) -> fg2 (purple) -> fg3 (amber) */

    GdkRGBA *fg1 = &prefs->graph_fg1_color;
    GdkRGBA *fg2 = &prefs->graph_fg2_color;
    GdkRGBA *fg3 = &prefs->graph_fg3_color;

    if (position < 0.33) {
        /* Bottom third: interpolate from fg1 to fg2 */
        gdouble t = position / 0.33;
        out_color->red = fg1->red + t * (fg2->red - fg1->red);
        out_color->green = fg1->green + t * (fg2->green - fg1->green);
        out_color->blue = fg1->blue + t * (fg2->blue - fg1->blue);
        out_color->alpha = 0.8;
    } else if (position < 0.67) {
        /* Middle third: interpolate from fg2 to fg3 */
        gdouble t = (position - 0.33) / 0.34;
        out_color->red = fg2->red + t * (fg3->red - fg2->red);
        out_color->green = fg2->green + t * (fg3->green - fg2->green);
        out_color->blue = fg2->blue + t * (fg3->blue - fg2->blue);
        out_color->alpha = 0.8;
    } else {
        /* Top third: use fg3 */
        out_color->red = fg3->red;
        out_color->green = fg3->green;
        out_color->blue = fg3->blue;
        out_color->alpha = 0.8;
    }
}
static gboolean on_draw_gpu(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_gpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_gpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_gpu_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_battery(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_battery_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_battery_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_battery_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_sensors(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_sensors_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_sensors_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_sensors_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_aitoken(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_aitoken_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_aitoken_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_aitoken_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_draw_process(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_process_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_process_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_process_context_menu(AppState *state, GdkEventButton *event);
static void on_process_sort_cpu(GtkMenuItem *item, gpointer user_data);
static void on_process_sort_memory(GtkMenuItem *item, gpointer user_data);
static gboolean on_draw_tpu(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_tpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_tpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static void show_tpu_context_menu(AppState *state, GdkEventButton *event);
static gboolean on_key_press(GtkWidget *widget, GdkEventKey *event, gpointer user_data);
static gboolean on_resize_grip_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_resize_grip_button_release(GtkWidget *widget, GdkEventButton *event, gpointer user_data);
static gboolean on_resize_grip_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data);
static gboolean on_draw_resize_grip(GtkWidget *widget, cairo_t *cr, gpointer user_data);
static gboolean on_update_timer(gpointer user_data);
static void on_window_destroy(GtkWidget *widget, gpointer user_data);
static void on_preferences_applied(gpointer user_data);
static void snap_to_edge(GtkWindow *window, gint *x, gint *y);

/**
 * Main entry point
 */
int main(int argc, char *argv[]) {
    GtkApplication *app;
    int status;

    app = gtk_application_new("com.gaucho.xrg-linux", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);

    return status;
}

/**
 * Create draggable title bar
 */
static GtkWidget* create_title_bar(AppState *state) {
    GtkWidget *event_box = gtk_event_box_new();
    GtkWidget *drawing_area = gtk_drawing_area_new();

    gtk_widget_set_size_request(drawing_area, -1, TITLE_BAR_HEIGHT);
    gtk_container_add(GTK_CONTAINER(event_box), drawing_area);

    /* Make event box visible for events */
    gtk_event_box_set_visible_window(GTK_EVENT_BOX(event_box), FALSE);
    gtk_event_box_set_above_child(GTK_EVENT_BOX(event_box), TRUE);

    /* Enable events on BOTH event box and drawing area */
    gtk_widget_add_events(event_box,
                         GDK_BUTTON_PRESS_MASK |
                         GDK_BUTTON_RELEASE_MASK |
                         GDK_POINTER_MOTION_MASK |
                         GDK_LEAVE_NOTIFY_MASK);

    gtk_widget_add_events(drawing_area,
                         GDK_BUTTON_PRESS_MASK |
                         GDK_BUTTON_RELEASE_MASK |
                         GDK_POINTER_MOTION_MASK);

    /* Connect signals */
    g_signal_connect(event_box, "realize", G_CALLBACK(on_title_bar_realize), NULL);
    g_signal_connect(event_box, "button-press-event", G_CALLBACK(on_title_bar_button_press), state);
    g_signal_connect(event_box, "button-release-event", G_CALLBACK(on_title_bar_button_release), state);
    g_signal_connect(event_box, "motion-notify-event", G_CALLBACK(on_title_bar_motion_notify), state);
    g_signal_connect(drawing_area, "draw", G_CALLBACK(on_draw_title_bar), state);

    return event_box;
}

/**
 * Create resize grip widget (bottom-right corner)
 */
static GtkWidget* create_resize_grip(AppState *state) {
    GtkWidget *event_box = gtk_event_box_new();
    GtkWidget *drawing_area = gtk_drawing_area_new();

    /* Fixed size 20x20 pixels for grip */
    gtk_widget_set_size_request(drawing_area, 20, 20);
    gtk_container_add(GTK_CONTAINER(event_box), drawing_area);

    /* Position in bottom-right corner */
    gtk_widget_set_halign(event_box, GTK_ALIGN_END);
    gtk_widget_set_valign(event_box, GTK_ALIGN_END);

    /* Make event box transparent */
    gtk_event_box_set_visible_window(GTK_EVENT_BOX(event_box), FALSE);
    gtk_event_box_set_above_child(GTK_EVENT_BOX(event_box), TRUE);

    /* Enable events */
    gtk_widget_add_events(event_box,
                         GDK_BUTTON_PRESS_MASK |
                         GDK_BUTTON_RELEASE_MASK |
                         GDK_POINTER_MOTION_MASK |
                         GDK_LEAVE_NOTIFY_MASK);

    gtk_widget_add_events(drawing_area,
                         GDK_BUTTON_PRESS_MASK |
                         GDK_BUTTON_RELEASE_MASK |
                         GDK_POINTER_MOTION_MASK);

    /* Connect signals */
    g_signal_connect(event_box, "realize", G_CALLBACK(on_resize_grip_realize), NULL);
    g_signal_connect(event_box, "button-press-event", G_CALLBACK(on_resize_grip_button_press), state);
    g_signal_connect(event_box, "button-release-event", G_CALLBACK(on_resize_grip_button_release), state);
    g_signal_connect(event_box, "motion-notify-event", G_CALLBACK(on_resize_grip_motion_notify), state);
    g_signal_connect(drawing_area, "draw", G_CALLBACK(on_draw_resize_grip), state);

    return event_box;
}

/**
 * Title bar realize (set cursor)
 */
static void on_title_bar_realize(GtkWidget *widget, gpointer user_data) {
    GdkCursor *cursor = gdk_cursor_new_for_display(gdk_display_get_default(), GDK_HAND2);
    gdk_window_set_cursor(gtk_widget_get_window(widget), cursor);
    g_object_unref(cursor);
}

/**
 * Draw title bar
 */
static gboolean on_draw_title_bar(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);
    
    gint width = allocation.width;
    gint height = allocation.height;
    
    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->background_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);
    
    /* Draw title text */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 10);
    
    cairo_move_to(cr, 5, 14);
    cairo_show_text(cr, "XRG-ng for Linux");
    
    /* Draw the menu button (three "kebab" dots, top-right). Left-clicking this
     * region opens the context menu; see on_title_bar_button_press. */
    gdouble dot_y = height / 2.0;
    for (gint i = 0; i < 3; i++) {
        gdouble dot_x = width - 30 + (i * 8);
        cairo_arc(cr, dot_x, dot_y, 2.0, 0, 2 * G_PI);
        cairo_fill(cr);
    }
    
    return FALSE;
}

/**
 * Debounced save callback - actually saves preferences after delay
 */
static gboolean debounced_save_preferences(gpointer user_data) {
    AppState *state = (AppState *)user_data;
    state->save_timeout_id = 0;  /* Mark as no longer pending */
    xrg_preferences_save(state->prefs);
    return G_SOURCE_REMOVE;  /* Don't repeat */
}

/**
 * Window configure event - fired when window is moved or resized
 * Uses debouncing to avoid saving on every event during drag/resize
 */
static gboolean on_window_configure(GtkWidget *widget, GdkEventConfigure *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    (void)event;  /* Unused - we query actual position instead */

    /* Get actual window position (event->x/y don't work on Wayland) */
    gint x, y, width, height;
    gtk_window_get_position(GTK_WINDOW(widget), &x, &y);
    gtk_window_get_size(GTK_WINDOW(widget), &width, &height);

    /* Only update if changed */
    gint adj_height = height - TITLE_BAR_HEIGHT;
    if (state->prefs->window_x == x &&
        state->prefs->window_y == y &&
        state->prefs->window_width == width &&
        state->prefs->window_height == adj_height) {
        return FALSE;  /* No change */
    }

    /* Save new position and size to prefs struct */
    state->prefs->window_x = x;
    state->prefs->window_y = y;
    state->prefs->window_width = width;
    state->prefs->window_height = adj_height;

    /* Debounce: cancel pending save and schedule a new one */
    if (state->save_timeout_id > 0) {
        g_source_remove(state->save_timeout_id);
    }
    /* Save after 500ms of inactivity */
    state->save_timeout_id = g_timeout_add(500, debounced_save_preferences, state);

    return FALSE;  /* Let other handlers process this event too */
}

/**
 * Title bar button press (start dragging)
 */
static gboolean on_title_bar_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 1) {  /* Left click */
        /* If the click landed on the menu dots (the kebab indicator drawn in
         * the top-right corner, see on_draw_title_bar), open the menu instead
         * of starting a drag. The dots span x in [width-30, width-14]; use a
         * slightly wider hit zone so they are easy to hit. */
        GtkAllocation alloc;
        gtk_widget_get_allocation(widget, &alloc);
        if (event->x >= alloc.width - MENU_DOTS_HIT_WIDTH) {
            show_title_bar_context_menu(state, event);
            return TRUE;
        }

        /* Otherwise drag: hand the drag to the compositor. Manual
         * gtk_window_move() is a no-op on Wayland, and the WM-native drag is
         * smoother on X11 too. No modifier/hotkey required. */
        gtk_window_begin_move_drag(GTK_WINDOW(state->window),
                                   event->button,
                                   (gint)event->x_root, (gint)event->y_root,
                                   event->time);
        return TRUE;
    } else if (event->button == 3) {  /* Right click */
        show_title_bar_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Fallback drag: left-dragging any non-interactive area moves the window
 * (graph areas only consume right-clicks, so left presses bubble up here)
 */
static gboolean on_window_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    (void)user_data;

    if (event->button == 1) {
        gtk_window_begin_move_drag(GTK_WINDOW(widget),
                                   event->button,
                                   (gint)event->x_root, (gint)event->y_root,
                                   event->time);
        return TRUE;
    }

    return FALSE;
}

/**
 * Title bar button release (stop dragging with snap)
 */
static gboolean on_title_bar_button_release(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 1 && state->is_dragging) {
        state->is_dragging = FALSE;

        /* Get current position and snap to edge */
        gint x, y;
        gtk_window_get_position(GTK_WINDOW(state->window), &x, &y);
        snap_to_edge(GTK_WINDOW(state->window), &x, &y);
        gtk_window_move(GTK_WINDOW(state->window), x, y);

        /* Save new position */
        state->prefs->window_x = x;
        state->prefs->window_y = y;
        xrg_preferences_save(state->prefs);

        return TRUE;
    }

    return FALSE;
}

/**
 * Title bar motion (update window position while dragging)
 */
static gboolean on_title_bar_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (state->is_dragging) {
        gint delta_x = event->x_root - state->drag_start_x;
        gint delta_y = event->y_root - state->drag_start_y;

        gint new_x = state->window_start_x + delta_x;
        gint new_y = state->window_start_y + delta_y;

        gtk_window_move(GTK_WINDOW(state->window), new_x, new_y);

        return TRUE;
    }

    return FALSE;
}

/**
 * Menu item callbacks
 */
static void on_menu_preferences(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    xrg_preferences_window_show(state->prefs_window);
}

static void on_menu_aitoken_settings(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    xrg_preferences_window_show_tab(state->prefs_window, XRG_PREFS_TAB_AITOKEN);
}

static void on_menu_tpu_settings(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    xrg_preferences_window_show_tab(state->prefs_window, XRG_PREFS_TAB_TPU);
}

static void on_menu_always_on_top(GtkCheckMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    gboolean active = gtk_check_menu_item_get_active(item);

    gtk_window_set_keep_above(GTK_WINDOW(state->window), active);
    state->prefs->window_always_on_top = active;
    xrg_preferences_save(state->prefs);

    g_message("Always on top: %s", active ? "enabled" : "disabled");
}

static void on_menu_reset_position(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Reset to top-right corner with some padding */
    GdkScreen *screen = gtk_window_get_screen(GTK_WINDOW(state->window));
    gint screen_width = gdk_screen_get_width(screen);
    gint window_width = state->prefs->window_width;

    gint new_x = screen_width - window_width - 20;
    gint new_y = 20;

    gtk_window_move(GTK_WINDOW(state->window), new_x, new_y);

    state->prefs->window_x = new_x;
    state->prefs->window_y = new_y;
    xrg_preferences_save(state->prefs);

    g_message("Window position reset to (%d, %d)", new_x, new_y);
}

static void on_menu_about(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    GtkWidget *dialog = gtk_about_dialog_new();
    gtk_about_dialog_set_program_name(GTK_ABOUT_DIALOG(dialog), "XRG-ng for Linux");
    gtk_about_dialog_set_version(GTK_ABOUT_DIALOG(dialog), "1.0.0");
    gtk_about_dialog_set_comments(GTK_ABOUT_DIALOG(dialog),
                                  "System Resource Graph Monitor\n\n"
                                  "Real-time monitoring for CPU, Memory, Network,\n"
                                  "Disk, GPU, Temperature, Battery, and AI Tokens");
    gtk_about_dialog_set_website(GTK_ABOUT_DIALOG(dialog), "https://gaucho.software/xrg/");
    gtk_about_dialog_set_website_label(GTK_ABOUT_DIALOG(dialog), "Visit Website");
    gtk_about_dialog_set_license_type(GTK_ABOUT_DIALOG(dialog), GTK_LICENSE_GPL_3_0);

    const gchar *authors[] = {"Mike Piatek-Jimenez (original XRG)", "Marc Shade", "Stephen de la Vega", NULL};
    gtk_about_dialog_set_copyright(GTK_ABOUT_DIALOG(dialog),
        "Copyright © 2002–2024 Mike Piatek-Jimenez / Gaucho Software, LLC\n"
        "Copyright © 2025–2026 Marc Shade\nCopyright © 2026 Stephen de la Vega");
    gtk_about_dialog_set_authors(GTK_ABOUT_DIALOG(dialog), authors);

    gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(state->window));
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static void on_menu_quit(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    g_application_quit(G_APPLICATION(gtk_window_get_application(GTK_WINDOW(state->window))));
}

/**
 * Show title bar context menu
 */
static void show_title_bar_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Preferences */
    GtkWidget *preferences_item = gtk_menu_item_new_with_label("Preferences...");
    g_signal_connect(preferences_item, "activate", G_CALLBACK(on_menu_preferences), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), preferences_item);

    /* Separator */
    GtkWidget *separator1 = gtk_separator_menu_item_new();
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), separator1);

    /* Always on Top */
    GtkWidget *always_on_top_item = gtk_check_menu_item_new_with_label("Always on Top");
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(always_on_top_item),
                                   state->prefs->window_always_on_top);
    g_signal_connect(always_on_top_item, "toggled", G_CALLBACK(on_menu_always_on_top), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), always_on_top_item);

    /* Reset Window Position */
    GtkWidget *reset_position_item = gtk_menu_item_new_with_label("Reset Window Position");
    g_signal_connect(reset_position_item, "activate", G_CALLBACK(on_menu_reset_position), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), reset_position_item);

    /* Separator */
    GtkWidget *separator2 = gtk_separator_menu_item_new();
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), separator2);

    /* About */
    GtkWidget *about_item = gtk_menu_item_new_with_label("About XRG-ng");
    g_signal_connect(about_item, "activate", G_CALLBACK(on_menu_about), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), about_item);

    /* Separator */
    GtkWidget *separator3 = gtk_separator_menu_item_new();
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), separator3);

    /* Quit */
    GtkWidget *quit_item = gtk_menu_item_new_with_label("Quit");
    g_signal_connect(quit_item, "activate", G_CALLBACK(on_menu_quit), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_item);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Resize grip realize (set cursor)
 */
static void on_resize_grip_realize(GtkWidget *widget, gpointer user_data) {
    GdkCursor *cursor = gdk_cursor_new_for_display(gdk_display_get_default(), GDK_BOTTOM_RIGHT_CORNER);
    gdk_window_set_cursor(gtk_widget_get_window(widget), cursor);
    g_object_unref(cursor);
}

/**
 * Draw resize grip
 */
static gboolean on_draw_resize_grip(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw three diagonal lines for grip indicator */
    GdkRGBA *color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, color->red, color->green, color->blue, 0.7);
    cairo_set_line_width(cr, 1.5);

    for (gint i = 0; i < 3; i++) {
        gint offset = i * 5 + 5;
        cairo_move_to(cr, offset, height);
        cairo_line_to(cr, width, offset);
        cairo_stroke(cr);
    }

    return FALSE;
}

/**
 * Resize grip button press - start resize
 */
static gboolean on_resize_grip_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 1) {  /* Left click */
        /* Compositor-native resize: works on Wayland where manual
         * x_root/y_root deltas are unreliable */
        gtk_window_begin_resize_drag(GTK_WINDOW(state->window),
                                     GDK_WINDOW_EDGE_SOUTH_EAST,
                                     event->button,
                                     (gint)event->x_root, (gint)event->y_root,
                                     event->time);
        return TRUE;
    }

    return FALSE;
}

/**
 * Resize grip button release - stop resize
 */
static gboolean on_resize_grip_button_release(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 1 && state->is_resizing) {
        state->is_resizing = FALSE;

        /* Save new size */
        gint width, height;
        gtk_window_get_size(GTK_WINDOW(state->window), &width, &height);
        state->prefs->window_width = width;
        state->prefs->window_height = height - TITLE_BAR_HEIGHT;
        xrg_preferences_save(state->prefs);

        return TRUE;
    }

    return FALSE;
}

/**
 * Resize grip motion - perform resize
 */
static gboolean on_resize_grip_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (state->is_resizing) {
        gint delta_x = event->x_root - state->resize_start_x;
        gint delta_y = event->y_root - state->resize_start_y;

        gint new_width = state->resize_start_width + delta_x;
        gint new_height = state->resize_start_height + delta_y;

        /* Enforce minimum size */
        if (new_width < 150) new_width = 150;
        if (new_height < 100) new_height = 100;

        gtk_window_resize(GTK_WINDOW(state->window), new_width, new_height);

        return TRUE;
    }

    return FALSE;
}

/**
 * Snap window to screen edges
 */
static void snap_to_edge(GtkWindow *window, gint *x, gint *y) {
    GdkScreen *screen = gtk_window_get_screen(window);
    GdkWindow *gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
    GdkMonitor *monitor = gdk_display_get_monitor_at_window(
        gdk_screen_get_display(screen), gdk_window);
    
    GdkRectangle workarea;
    gdk_monitor_get_workarea(monitor, &workarea);
    
    gint window_width, window_height;
    gtk_window_get_size(window, &window_width, &window_height);
    
    /* Snap to left edge */
    if (*x < workarea.x + SNAP_DISTANCE) {
        *x = workarea.x;
    }
    /* Snap to right edge */
    else if (*x + window_width > workarea.x + workarea.width - SNAP_DISTANCE) {
        *x = workarea.x + workarea.width - window_width;
    }
    
    /* Snap to top edge */
    if (*y < workarea.y + SNAP_DISTANCE) {
        *y = workarea.y;
    }
    /* Snap to bottom edge */
    else if (*y + window_height > workarea.y + workarea.height - SNAP_DISTANCE) {
        *y = workarea.y + workarea.height - window_height;
    }
}

/**
 * Application activation (create window and initialize)
 */
static void on_activate(GtkApplication *app, gpointer user_data) {
    AppState *state = g_new0(AppState, 1);

    /* Load preferences */
    state->prefs = xrg_preferences_new();
    if (!xrg_preferences_load(state->prefs)) {
        g_message("Using default preferences (first run)");
    }

    /* Sanity check: prevent loading black colors (corrupted config) */
    if (state->prefs->graph_fg1_color.red < 0.01 &&
        state->prefs->graph_fg1_color.green < 0.01 &&
        state->prefs->graph_fg1_color.blue < 0.01) {
        g_warning("Config file has corrupted black colors! Restoring Cyberpunk theme defaults...");
        xrg_preferences_apply_theme(state->prefs, "Cyberpunk");
        xrg_preferences_save(state->prefs);  /* Save immediately to fix config file */
    }

    /* Initialize collectors */
    state->cpu_collector = xrg_cpu_collector_new(200);  /* 200 data points */
    state->memory_collector = xrg_memory_collector_new(200);
    state->network_collector = xrg_network_collector_new(200);
    state->disk_collector = xrg_disk_collector_new(200);
    state->gpu_collector = xrg_gpu_collector_new(200);
    state->battery_collector = xrg_battery_collector_new();
    state->sensors_collector = xrg_sensors_collector_new();
    state->aitoken_collector = xrg_aitoken_collector_new(200);
    state->process_collector = xrg_process_collector_new(10);  /* Top 10 processes */
    state->tpu_collector = xrg_tpu_collector_new(200);  /* TPU/Coral monitoring */

    /* Create main window */
    state->window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(state->window), "XRG-ng for Linux");
    gtk_window_set_default_size(GTK_WINDOW(state->window),
                                state->prefs->window_width,
                                state->prefs->window_height + TITLE_BAR_HEIGHT);
    gtk_window_move(GTK_WINDOW(state->window),
                    state->prefs->window_x,
                    state->prefs->window_y);

    /* Make window frameless and always-on-top */
    gtk_window_set_decorated(GTK_WINDOW(state->window), FALSE);
    if (state->prefs->window_always_on_top) {
        gtk_window_set_keep_above(GTK_WINDOW(state->window), TRUE);
    }

    /* Set window transparency */
    GdkScreen *screen = gtk_widget_get_screen(state->window);
    GdkVisual *visual = gdk_screen_get_rgba_visual(screen);
    if (visual != NULL && gdk_screen_is_composited(screen)) {
        gtk_widget_set_visual(state->window, visual);
        gtk_widget_set_opacity(state->window, state->prefs->window_opacity);
    }

    /* Create overlay for resize grip */
    state->overlay = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(state->window), state->overlay);

    /* Store current orientation */
    state->current_layout_orientation = state->prefs->layout_orientation;

    /* Create box container with orientation from preferences */
    GtkOrientation gtk_orientation = (state->prefs->layout_orientation == XRG_LAYOUT_VERTICAL)
        ? GTK_ORIENTATION_VERTICAL
        : GTK_ORIENTATION_HORIZONTAL;
    state->vbox = gtk_box_new(gtk_orientation, 0);
    gtk_container_add(GTK_CONTAINER(state->overlay), state->vbox);

    /* Add title bar */
    state->title_bar = create_title_bar(state);
    gtk_box_pack_start(GTK_BOX(state->vbox), state->title_bar, FALSE, FALSE, 0);

    /* Add resize grip as overlay */
    state->resize_grip = create_resize_grip(state);
    gtk_overlay_add_overlay(GTK_OVERLAY(state->overlay), state->resize_grip);

    /* Create CPU module container */
    state->cpu_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create CPU graph */
    state->cpu_drawing_area = gtk_drawing_area_new();
    /* In horizontal mode, use square graphs (width = height = graph_width) */
    gint cpu_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                      ? state->prefs->graph_width
                      : state->prefs->graph_height_cpu;
    gtk_widget_set_size_request(state->cpu_drawing_area,
                                state->prefs->graph_width,
                                cpu_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->cpu_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->cpu_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->cpu_drawing_area, "draw", G_CALLBACK(on_draw_cpu), state);
    g_signal_connect(state->cpu_drawing_area, "button-press-event", G_CALLBACK(on_cpu_button_press), state);
    g_signal_connect(state->cpu_drawing_area, "motion-notify-event", G_CALLBACK(on_cpu_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->cpu_box), state->cpu_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->cpu_box, TRUE, TRUE, 0);

    /* Create Memory module container */
    state->memory_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Memory graph */
    state->memory_drawing_area = gtk_drawing_area_new();
    gint memory_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                         ? state->prefs->graph_width
                         : state->prefs->graph_height_memory;
    gtk_widget_set_size_request(state->memory_drawing_area,
                                state->prefs->graph_width,
                                memory_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->memory_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->memory_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->memory_drawing_area, "draw", G_CALLBACK(on_draw_memory), state);
    g_signal_connect(state->memory_drawing_area, "button-press-event", G_CALLBACK(on_memory_button_press), state);
    g_signal_connect(state->memory_drawing_area, "motion-notify-event", G_CALLBACK(on_memory_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->memory_box), state->memory_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->memory_box, TRUE, TRUE, 0);

    /* Create Network module container */
    state->network_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Network graph */
    state->network_drawing_area = gtk_drawing_area_new();
    gint network_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                          ? state->prefs->graph_width
                          : state->prefs->graph_height_network;
    gtk_widget_set_size_request(state->network_drawing_area,
                                state->prefs->graph_width,
                                network_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->network_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->network_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->network_drawing_area, "draw", G_CALLBACK(on_draw_network), state);
    g_signal_connect(state->network_drawing_area, "button-press-event", G_CALLBACK(on_network_button_press), state);
    g_signal_connect(state->network_drawing_area, "motion-notify-event", G_CALLBACK(on_network_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->network_box), state->network_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->network_box, TRUE, TRUE, 0);

    /* Create Disk module container */
    state->disk_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Disk graph */
    state->disk_drawing_area = gtk_drawing_area_new();
    gint disk_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                       ? state->prefs->graph_width
                       : state->prefs->graph_height_disk;
    gtk_widget_set_size_request(state->disk_drawing_area,
                                state->prefs->graph_width,
                                disk_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->disk_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->disk_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->disk_drawing_area, "draw", G_CALLBACK(on_draw_disk), state);
    g_signal_connect(state->disk_drawing_area, "button-press-event", G_CALLBACK(on_disk_button_press), state);
    g_signal_connect(state->disk_drawing_area, "motion-notify-event", G_CALLBACK(on_disk_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->disk_box), state->disk_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->disk_box, TRUE, TRUE, 0);

    /* Create GPU module container */
    state->gpu_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create GPU graph */
    state->gpu_drawing_area = gtk_drawing_area_new();
    gint gpu_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                      ? state->prefs->graph_width
                      : state->prefs->graph_height_gpu;
    gtk_widget_set_size_request(state->gpu_drawing_area,
                                state->prefs->graph_width,
                                gpu_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->gpu_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->gpu_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->gpu_drawing_area, "draw", G_CALLBACK(on_draw_gpu), state);
    g_signal_connect(state->gpu_drawing_area, "button-press-event", G_CALLBACK(on_gpu_button_press), state);
    g_signal_connect(state->gpu_drawing_area, "motion-notify-event", G_CALLBACK(on_gpu_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->gpu_box), state->gpu_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->gpu_box, TRUE, TRUE, 0);

    /* Create Battery module container */
    state->battery_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Battery graph */
    state->battery_drawing_area = gtk_drawing_area_new();
    gint battery_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                          ? state->prefs->graph_width
                          : state->prefs->graph_height_battery;
    gtk_widget_set_size_request(state->battery_drawing_area,
                                state->prefs->graph_width,
                                battery_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->battery_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->battery_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->battery_drawing_area, "draw", G_CALLBACK(on_draw_battery), state);
    g_signal_connect(state->battery_drawing_area, "button-press-event", G_CALLBACK(on_battery_button_press), state);
    g_signal_connect(state->battery_drawing_area, "motion-notify-event", G_CALLBACK(on_battery_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->battery_box), state->battery_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->battery_box, TRUE, TRUE, 0);

    /* Create Sensors/Temperature module container */
    state->sensors_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Sensors graph */
    state->sensors_drawing_area = gtk_drawing_area_new();
    gint sensors_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                          ? state->prefs->graph_width
                          : state->prefs->graph_height_temperature;
    gtk_widget_set_size_request(state->sensors_drawing_area,
                                state->prefs->graph_width,
                                sensors_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->sensors_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->sensors_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->sensors_drawing_area, "draw", G_CALLBACK(on_draw_sensors), state);
    g_signal_connect(state->sensors_drawing_area, "button-press-event", G_CALLBACK(on_sensors_button_press), state);
    g_signal_connect(state->sensors_drawing_area, "motion-notify-event", G_CALLBACK(on_sensors_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->sensors_box), state->sensors_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->sensors_box, TRUE, TRUE, 0);

    /* Create AI Token module container */
    state->aitoken_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create AI Token graph */
    state->aitoken_drawing_area = gtk_drawing_area_new();
    gint aitoken_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                          ? state->prefs->graph_width
                          : state->prefs->graph_height_aitoken;
    gtk_widget_set_size_request(state->aitoken_drawing_area,
                                state->prefs->graph_width,
                                aitoken_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->aitoken_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->aitoken_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->aitoken_drawing_area, "draw", G_CALLBACK(on_draw_aitoken), state);
    g_signal_connect(state->aitoken_drawing_area, "button-press-event", G_CALLBACK(on_aitoken_button_press), state);
    g_signal_connect(state->aitoken_drawing_area, "motion-notify-event", G_CALLBACK(on_aitoken_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->aitoken_box), state->aitoken_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->aitoken_box, TRUE, TRUE, 0);

    /* Create Process module container */
    state->process_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create Process list */
    state->process_drawing_area = gtk_drawing_area_new();
    gint process_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                          ? state->prefs->graph_width
                          : state->prefs->graph_height_process;
    gtk_widget_set_size_request(state->process_drawing_area,
                                state->prefs->graph_width,
                                process_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->process_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->process_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->process_drawing_area, "draw", G_CALLBACK(on_draw_process), state);
    g_signal_connect(state->process_drawing_area, "button-press-event", G_CALLBACK(on_process_button_press), state);
    g_signal_connect(state->process_drawing_area, "motion-notify-event", G_CALLBACK(on_process_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->process_box), state->process_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->process_box, TRUE, TRUE, 0);

    /* Create TPU module container */
    state->tpu_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    /* Create TPU drawing area */
    state->tpu_drawing_area = gtk_drawing_area_new();
    gint tpu_height = (state->prefs->layout_orientation == XRG_LAYOUT_HORIZONTAL)
                      ? state->prefs->graph_width
                      : state->prefs->graph_height_tpu;
    gtk_widget_set_size_request(state->tpu_drawing_area,
                                state->prefs->graph_width,
                                tpu_height);

    /* Enable tooltips */
    gtk_widget_set_has_tooltip(state->tpu_drawing_area, TRUE);

    /* Enable button press and motion events */
    gtk_widget_add_events(state->tpu_drawing_area,
                         GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(state->tpu_drawing_area, "draw", G_CALLBACK(on_draw_tpu), state);
    g_signal_connect(state->tpu_drawing_area, "button-press-event", G_CALLBACK(on_tpu_button_press), state);
    g_signal_connect(state->tpu_drawing_area, "motion-notify-event", G_CALLBACK(on_tpu_motion_notify), state);
    gtk_box_pack_start(GTK_BOX(state->tpu_box), state->tpu_drawing_area, TRUE, TRUE, 0);

    gtk_box_pack_start(GTK_BOX(state->vbox), state->tpu_box, TRUE, TRUE, 0);

    /* Set initial visibility based on preferences */
    gtk_widget_set_visible(state->cpu_box, state->prefs->show_cpu);
    gtk_widget_set_visible(state->memory_box, state->prefs->show_memory);
    gtk_widget_set_visible(state->network_box, state->prefs->show_network);
    gtk_widget_set_visible(state->disk_box, state->prefs->show_disk);
    gtk_widget_set_visible(state->gpu_box, state->prefs->show_gpu);
    gtk_widget_set_visible(state->battery_box, state->prefs->show_battery);
    gtk_widget_set_visible(state->sensors_box, state->prefs->show_temperature);
    gtk_widget_set_visible(state->aitoken_box, state->prefs->show_aitoken);
    gtk_widget_set_visible(state->process_box, state->prefs->show_process);
    gtk_widget_set_visible(state->tpu_box, state->prefs->show_tpu);

    g_message("Initial module visibility - Battery: %s (prefs value: %d)",
              state->prefs->show_battery ? "SHOWN" : "HIDDEN",
              state->prefs->show_battery);

    /* Connect keyboard events */
    g_signal_connect(state->window, "key-press-event", G_CALLBACK(on_key_press), state);

    /* Connect configure event (window moved or resized) */
    g_signal_connect(state->window, "configure-event", G_CALLBACK(on_window_configure), state);

    /* Grab-anywhere window dragging (unhandled left presses bubble up here) */
    gtk_widget_add_events(state->window, GDK_BUTTON_PRESS_MASK);
    g_signal_connect(state->window, "button-press-event", G_CALLBACK(on_window_button_press), state);

    /* Connect destroy signal */
    g_signal_connect(state->window, "destroy", G_CALLBACK(on_window_destroy), state);

    /* Create preferences window */
    state->prefs_window = xrg_preferences_window_new(GTK_WINDOW(state->window), state->prefs);
    xrg_preferences_window_set_applied_callback(state->prefs_window, on_preferences_applied, state);

    /* Start update timer (1 second) */
    state->update_timer_id = g_timeout_add(state->prefs->normal_update_interval,
                                           on_update_timer, state);

    /* Show window */
    gtk_widget_show_all(state->window);

    /* Re-apply visibility settings after show_all (which shows everything) */
    gtk_widget_set_visible(state->cpu_box, state->prefs->show_cpu);
    gtk_widget_set_visible(state->memory_box, state->prefs->show_memory);
    gtk_widget_set_visible(state->network_box, state->prefs->show_network);
    gtk_widget_set_visible(state->disk_box, state->prefs->show_disk);
    gtk_widget_set_visible(state->gpu_box, state->prefs->show_gpu);
    gtk_widget_set_visible(state->battery_box, state->prefs->show_battery);
    gtk_widget_set_visible(state->sensors_box, state->prefs->show_temperature);
    gtk_widget_set_visible(state->aitoken_box, state->prefs->show_aitoken);
    gtk_widget_set_visible(state->process_box, state->prefs->show_process);

    g_message("XRG-ng for Linux started - Monitoring %d CPU cores",
              xrg_cpu_collector_get_num_cpus(state->cpu_collector));
}

/**
 * CPU module button press (context menu)
 */
static gboolean on_cpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    
    if (event->button == 3) {  /* Right click */
        show_cpu_context_menu(state, event);
        return TRUE;
    }
    
    return FALSE;
}

/**
 * Show CPU context menu
 */
static void show_cpu_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();
    
    /* CPU Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("CPU Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);
    
    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    
    /* Stats */
    gchar *stats_text = g_strdup_printf("Cores: %d | Usage: %.1f%% | Load: %.2f",
                                       xrg_cpu_collector_get_num_cpus(state->cpu_collector),
                                       xrg_cpu_collector_get_total_usage(state->cpu_collector),
                                       xrg_cpu_collector_get_load_average_1min(state->cpu_collector));
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);
    
    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * CPU motion notify (tooltip)
 */
static gboolean on_cpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *user_dataset = xrg_cpu_collector_get_user_dataset(state->cpu_collector);
    XRGDataset *system_dataset = xrg_cpu_collector_get_system_dataset(state->cpu_collector);
    gint count = xrg_dataset_get_count(user_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "CPU: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index */
    gdouble user_val = xrg_dataset_get_value(user_dataset, index);
    gdouble system_val = xrg_dataset_get_value(system_dataset, index);
    gdouble total_val = user_val + system_val;

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("CPU Usage: %.1f%%\nUser: %.1f%% | System: %.1f%%",
                                     total_val, user_val, system_val);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Memory module button press (context menu)
 */
static gboolean on_memory_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_memory_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show Memory context menu
 */
static void show_memory_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Memory Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("Memory Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    guint64 total_mem = xrg_memory_collector_get_total_memory(state->memory_collector);
    guint64 used_mem = xrg_memory_collector_get_used_memory(state->memory_collector);
    guint64 swap_used = xrg_memory_collector_get_swap_used(state->memory_collector);

    gdouble total_gb = total_mem / (1024.0 * 1024.0 * 1024.0);
    gdouble used_gb = used_mem / (1024.0 * 1024.0 * 1024.0);
    gdouble swap_gb = swap_used / (1024.0 * 1024.0 * 1024.0);

    gchar *stats_text = g_strdup_printf("Used: %.1f/%.1f GB | Swap: %.1f GB",
                                       used_gb, total_gb, swap_gb);
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Memory motion notify (tooltip)
 */
static gboolean on_memory_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *used_dataset = xrg_memory_collector_get_used_dataset(state->memory_collector);
    XRGDataset *wired_dataset = xrg_memory_collector_get_wired_dataset(state->memory_collector);
    XRGDataset *cached_dataset = xrg_memory_collector_get_cached_dataset(state->memory_collector);
    gint count = xrg_dataset_get_count(used_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "Memory: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index (percentages) */
    gdouble used_val = xrg_dataset_get_value(used_dataset, index);
    gdouble wired_val = xrg_dataset_get_value(wired_dataset, index);
    gdouble cached_val = xrg_dataset_get_value(cached_dataset, index);
    gdouble total_pct = used_val + wired_val + cached_val;

    /* Calculate absolute values in GB */
    guint64 total_mem = xrg_memory_collector_get_total_memory(state->memory_collector);
    gdouble total_gb = total_mem / (1024.0 * 1024.0 * 1024.0);
    gdouble used_gb = (used_val / 100.0) * total_gb;
    gdouble wired_gb = (wired_val / 100.0) * total_gb;
    gdouble cached_gb = (cached_val / 100.0) * total_gb;

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("Memory Usage: %.1f%% (%.1f GB)\nUsed: %.1f GB | Wired: %.1f GB | Cached: %.1f GB",
                                     total_pct, (total_pct / 100.0) * total_gb,
                                     used_gb, wired_gb, cached_gb);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Network module button press (context menu)
 */
static gboolean on_network_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_network_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show Network context menu
 */
static void show_network_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Network Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("Network Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    const gchar *iface = xrg_network_collector_get_primary_interface(state->network_collector);
    gdouble download = xrg_network_collector_get_download_rate(state->network_collector);
    gdouble upload = xrg_network_collector_get_upload_rate(state->network_collector);

    gchar *stats_text = g_strdup_printf("%s | ↓ %.2f MB/s | ↑ %.2f MB/s",
                                       iface, download, upload);
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Network motion notify (tooltip)
 */
static gboolean on_network_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *download_dataset = xrg_network_collector_get_download_dataset(state->network_collector);
    XRGDataset *upload_dataset = xrg_network_collector_get_upload_dataset(state->network_collector);
    gint count = xrg_dataset_get_count(download_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "Network: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index (MB/s) */
    gdouble download_val = xrg_dataset_get_value(download_dataset, index);
    gdouble upload_val = xrg_dataset_get_value(upload_dataset, index);

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("Network Traffic\nDownload: %.2f MB/s\nUpload: %.2f MB/s",
                                     download_val, upload_val);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Handle button press on Disk drawing area (for context menu)
 */
static gboolean on_disk_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_disk_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show Disk context menu
 */
static void show_disk_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Disk Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("Disk Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    const gchar *device = xrg_disk_collector_get_primary_device(state->disk_collector);
    gdouble read_rate = xrg_disk_collector_get_read_rate(state->disk_collector);
    gdouble write_rate = xrg_disk_collector_get_write_rate(state->disk_collector);

    gchar *stats_text = g_strdup_printf("%s | Read: %.2f MB/s | Write: %.2f MB/s",
                                       device, read_rate, write_rate);
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Disk motion notify (tooltip)
 */
static gboolean on_disk_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *read_dataset = xrg_disk_collector_get_read_dataset(state->disk_collector);
    XRGDataset *write_dataset = xrg_disk_collector_get_write_dataset(state->disk_collector);
    gint count = xrg_dataset_get_count(read_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "Disk: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index (MB/s) */
    gdouble read_val = xrg_dataset_get_value(read_dataset, index);
    gdouble write_val = xrg_dataset_get_value(write_dataset, index);

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("Disk Activity\nRead: %.2f MB/s\nWrite: %.2f MB/s",
                                     read_val, write_val);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Draw Disk graph
 */
static gboolean on_draw_disk(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->disk_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get disk datasets */
    XRGDataset *read_dataset = xrg_disk_collector_get_read_dataset(state->disk_collector);
    XRGDataset *write_dataset = xrg_disk_collector_get_write_dataset(state->disk_collector);

    gint count = xrg_dataset_get_count(read_dataset);
    if (count < 2) {
        /* Not enough data yet */
        return FALSE;
    }

    /* Find maximum rate for auto-scaling */
    gdouble max_rate = 0.1;  /* Minimum 0.1 MB/s */
    for (gint i = 0; i < count; i++) {
        gdouble read_val = xrg_dataset_get_value(read_dataset, i);
        gdouble write_val = xrg_dataset_get_value(write_dataset, i);
        if (read_val > max_rate) max_rate = read_val;
        if (write_val > max_rate) max_rate = write_val;
    }

    /* Draw read rate (cyan - FG1) */
    GdkRGBA *fg1_color = &state->prefs->disk_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->disk_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(read_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(read_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(read_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(read_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw write rate (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->disk_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(write_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(write_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(write_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(write_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    gdouble read_rate = xrg_disk_collector_get_read_rate(state->disk_collector);
    gdouble write_rate = xrg_disk_collector_get_write_rate(state->disk_collector);

    /* Line 1: Disk I/O label */
    gchar *line1 = g_strdup_printf("Disk I/O");
    cairo_move_to(cr, 5, 15);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: Read rate */
    gchar *line2 = g_strdup_printf("Read: %.2f MB/s", read_rate);
    cairo_move_to(cr, 5, 27);
    cairo_show_text(cr, line2);
    g_free(line2);

    /* Line 3: Write rate */
    gchar *line3 = g_strdup_printf("Write: %.2f MB/s", write_rate);
    cairo_move_to(cr, 5, 39);
    cairo_show_text(cr, line3);
    g_free(line3);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Draw filled bar representing current read rate */
        gdouble current_value = read_rate / max_rate;
        if (current_value > 1.0) current_value = 1.0;  /* Cap at 100% */
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Handle button press on GPU drawing area (for context menu)
 */
static gboolean on_gpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_gpu_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show GPU context menu
 */
static void show_gpu_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* GPU Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("GPU Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    const gchar *gpu_name = xrg_gpu_collector_get_name(state->gpu_collector);
    gdouble utilization = xrg_gpu_collector_get_utilization(state->gpu_collector);
    gdouble mem_used = xrg_gpu_collector_get_memory_used_mb(state->gpu_collector);
    gdouble mem_total = xrg_gpu_collector_get_memory_total_mb(state->gpu_collector);
    gdouble temp = xrg_gpu_collector_get_temperature(state->gpu_collector);

    gchar *stats_text = g_strdup_printf("%s | %.0f%% | %.0f/%.0f MB | %.0f°C",
                                       gpu_name, utilization, mem_used, mem_total, temp);
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * GPU motion notify (tooltip)
 */
static gboolean on_gpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *util_dataset = xrg_gpu_collector_get_utilization_dataset(state->gpu_collector);
    XRGDataset *mem_dataset = xrg_gpu_collector_get_memory_dataset(state->gpu_collector);
    gint count = xrg_dataset_get_count(util_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "GPU: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index */
    gdouble util_val = xrg_dataset_get_value(util_dataset, index);
    gdouble mem_val = xrg_dataset_get_value(mem_dataset, index);

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("GPU Usage\nUtilization: %.0f%%\nMemory: %.0f%%",
                                     util_val, mem_val);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Draw GPU graph
 */
static gboolean on_draw_gpu(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get GPU datasets */
    XRGDataset *util_dataset = xrg_gpu_collector_get_utilization_dataset(state->gpu_collector);
    XRGDataset *mem_dataset = xrg_gpu_collector_get_memory_dataset(state->gpu_collector);

    gint count = xrg_dataset_get_count(util_dataset);
    if (count < 2) {
        /* Not enough data yet - draw label */
        GdkRGBA *text_color = &state->prefs->text_color;
        cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha * 0.5);
        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10);
        cairo_move_to(cr, 5, 12);
        cairo_show_text(cr, "GPU: Waiting for data...");
        return FALSE;
    }

    /* Draw GPU utilization (cyan - FG1) - bottom layer */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->gpu_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(util_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(util_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(util_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(util_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw GPU memory usage on top (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(mem_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(mem_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(mem_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(mem_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10);

    const gchar *gpu_name = xrg_gpu_collector_get_name(state->gpu_collector);
    gdouble utilization = xrg_gpu_collector_get_utilization(state->gpu_collector);
    gdouble mem_used = xrg_gpu_collector_get_memory_used_mb(state->gpu_collector);
    gdouble mem_total = xrg_gpu_collector_get_memory_total_mb(state->gpu_collector);
    gdouble temp = xrg_gpu_collector_get_temperature(state->gpu_collector);

    /* Line 1: GPU name */
    cairo_move_to(cr, 5, 12);
    cairo_show_text(cr, gpu_name);

    /* Line 2: Utilization */
    gchar *util_text = g_strdup_printf("Util: %.0f%%", utilization);
    cairo_move_to(cr, 5, 24);
    cairo_show_text(cr, util_text);
    g_free(util_text);

    /* Line 3: Memory */
    gchar *mem_text = g_strdup_printf("Mem: %.0f/%.0f MB", mem_used, mem_total);
    cairo_move_to(cr, 5, 36);
    cairo_show_text(cr, mem_text);
    g_free(mem_text);

    /* Line 4: Temperature */
    gdouble display_temp = temp;
    const gchar *unit_symbol = "°C";

    if (state->prefs->temperature_units == XRG_TEMP_FAHRENHEIT) {
        /* Convert Celsius to Fahrenheit: F = (C × 9/5) + 32 */
        display_temp = (temp * 9.0 / 5.0) + 32.0;
        unit_symbol = "°F";
    }

    gchar *temp_text = g_strdup_printf("Temp: %.0f%s", display_temp, unit_symbol);
    cairo_move_to(cr, 5, 48);
    cairo_show_text(cr, temp_text);
    g_free(temp_text);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Draw filled bar representing current GPU utilization */
        gdouble current_value = utilization / 100.0;
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Handle button press on AI Token drawing area (for context menu)
 */
static gboolean on_aitoken_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_aitoken_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show AI Token context menu
 */
static void show_aitoken_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* AI Token Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("AI Token Settings...");
    g_signal_connect(settings_item, "activate",
                     G_CALLBACK(on_menu_aitoken_settings), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    const gchar *source = xrg_aitoken_collector_get_source_name(state->aitoken_collector);
    guint64 total_tokens = xrg_aitoken_collector_get_total_tokens(state->aitoken_collector);
    guint64 session_tokens = xrg_aitoken_collector_get_session_tokens(state->aitoken_collector);

    gchar *stats_text = g_strdup_printf("%s | Total: %lu | Session: %lu",
                                       source, total_tokens, session_tokens);
    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * AI Token motion notify (tooltip)
 */
static gboolean on_aitoken_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *input_dataset = xrg_aitoken_collector_get_input_dataset(state->aitoken_collector);
    XRGDataset *output_dataset = xrg_aitoken_collector_get_output_dataset(state->aitoken_collector);
    gint count = xrg_dataset_get_count(input_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "AI Tokens: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index (tokens/min) */
    gdouble input_val = xrg_dataset_get_value(input_dataset, index);
    gdouble output_val = xrg_dataset_get_value(output_dataset, index);
    gdouble total_val = input_val + output_val;

    /* Set tooltip */
    gchar *tooltip = g_strdup_printf("AI Token Usage: %.0f tokens/min\nInput: %.0f | Output: %.0f",
                                     total_val, input_val, output_val);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Draw Battery graph
 */
static gboolean on_draw_battery(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get battery datasets */
    XRGDataset *charge_dataset = state->battery_collector->charge_watts;
    XRGDataset *discharge_dataset = state->battery_collector->discharge_watts;

    gint count = xrg_dataset_get_count(charge_dataset);
    if (count < 2) {
        /* Not enough data yet - draw "No Battery" message */
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);
        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10.0);
        cairo_move_to(cr, 10, height / 2);
        cairo_show_text(cr, "Battery");
        return FALSE;
    }

    /* Get battery status */
    XRGBatteryStatus status = xrg_battery_collector_get_status(state->battery_collector);
    gint charge_percent = xrg_battery_collector_get_charge_percent(state->battery_collector);
    gint minutes_remaining = xrg_battery_collector_get_minutes_remaining(state->battery_collector);

    /* Draw charge level graph (green when charging, cyan when discharging) */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;

    XRGGraphStyle style = state->prefs->battery_graph_style;

    /* Draw discharge watts (cyan - FG1) */
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    gdouble max_discharge = xrg_dataset_get_max(discharge_dataset);
    if (max_discharge < 10.0) max_discharge = 10.0;  /* Minimum scale */

    if (style == XRG_GRAPH_STYLE_SOLID) {
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(discharge_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_discharge * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(discharge_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_discharge * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw charge watts (green - FG2) on top */
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha);

    gdouble max_charge = xrg_dataset_get_max(charge_dataset);
    if (max_charge < 10.0) max_charge = 10.0;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(charge_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_charge * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    }

    /* Draw battery icon/bar on the right */
    gint bar_x = width - 30;
    gint bar_width = 25;
    gint bar_height_total = height - 20;
    gint bar_y = 10;

    /* Draw battery outline */
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 2.0);
    cairo_rectangle(cr, bar_x, bar_y, bar_width, bar_height_total);
    cairo_stroke(cr);

    /* Draw battery terminal */
    cairo_rectangle(cr, bar_x + 7, bar_y - 3, 11, 3);
    cairo_fill(cr);

    /* Draw charge level fill */
    gdouble fill_height = (charge_percent / 100.0) * (bar_height_total - 4);
    gdouble fill_y = bar_y + bar_height_total - fill_height - 2;

    /* Color based on charge level */
    if (charge_percent > 50) {
        cairo_set_source_rgba(cr, 0.0, 1.0, 0.2, 0.8);  /* Green */
    } else if (charge_percent > 20) {
        cairo_set_source_rgba(cr, 1.0, 0.8, 0.0, 0.8);  /* Yellow */
    } else {
        cairo_set_source_rgba(cr, 1.0, 0.2, 0.0, 0.8);  /* Red */
    }

    cairo_rectangle(cr, bar_x + 2, fill_y, bar_width - 4, fill_height);
    cairo_fill(cr);

    /* Draw text labels */
    cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    /* Line 1: Status and charge percent */
    const gchar *status_text = "";
    switch (status) {
        case XRG_BATTERY_STATUS_CHARGING:
            status_text = "Charging";
            break;
        case XRG_BATTERY_STATUS_DISCHARGING:
            status_text = "Battery";
            break;
        case XRG_BATTERY_STATUS_FULL:
            status_text = "Fully Charged";
            break;
        case XRG_BATTERY_STATUS_NOT_CHARGING:
            status_text = "Not Charging";
            break;
        case XRG_BATTERY_STATUS_NO_BATTERY:
            status_text = "No Battery";
            break;
        default:
            status_text = "Unknown";
    }

    gchar *line1 = g_strdup_printf("%s: %d%%", status_text, charge_percent);
    cairo_move_to(cr, 5, 12);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: Time remaining */
    if (minutes_remaining > 0) {
        gint hours = minutes_remaining / 60;
        gint mins = minutes_remaining % 60;
        gchar *line2 = g_strdup_printf("Time: %dh %dm", hours, mins);
        cairo_move_to(cr, 5, 26);
        cairo_show_text(cr, line2);
        g_free(line2);
    }

    /* Line 3: Current power */
    gdouble current_discharge = xrg_dataset_get_latest(discharge_dataset);
    gdouble current_charge = xrg_dataset_get_latest(charge_dataset);
    if (current_charge > 0.1) {
        gchar *line3 = g_strdup_printf("Charging: %.1fW", current_charge);
        cairo_move_to(cr, 5, 40);
        cairo_show_text(cr, line3);
        g_free(line3);
    } else if (current_discharge > 0.1) {
        gchar *line3 = g_strdup_printf("Discharging: %.1fW", current_discharge);
        cairo_move_to(cr, 5, 40);
        cairo_show_text(cr, line3);
        g_free(line3);
    }

    /* Set tooltip */
    gint64 charge = xrg_battery_collector_get_total_charge(state->battery_collector);
    gint64 capacity = xrg_battery_collector_get_total_capacity(state->battery_collector);
    gchar *tooltip = g_strdup_printf("Battery: %d%% (%s)\nCharge: %ldmWh / %ldmWh",
                                     charge_percent, status_text,
                                     charge / 1000, capacity / 1000);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Draw Sensors/Temperature graph
 */
static gboolean on_draw_sensors(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get temperature sensors */
    GSList *temp_sensors = xrg_sensors_collector_get_temp_sensors(state->sensors_collector);

    if (temp_sensors == NULL || g_slist_length(temp_sensors) == 0) {
        /* No sensors found */
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);
        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10.0);
        cairo_move_to(cr, 10, height / 2);
        cairo_show_text(cr, "No Sensors");
        if (temp_sensors) g_slist_free(temp_sensors);
        return FALSE;
    }

    XRGGraphStyle style = state->prefs->temperature_graph_style;
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    GdkRGBA *fg3_color = &state->prefs->graph_fg3_color;

    /* Draw up to 3 temperature sensors */
    gint sensor_count = 0;
    GdkRGBA *colors[] = {fg1_color, fg2_color, fg3_color};

    for (GSList *l = temp_sensors; l != NULL && sensor_count < 3; l = l->next) {
        XRGSensorData *sensor = (XRGSensorData *)l->data;
        if (!sensor->is_enabled) continue;

        gint count = xrg_dataset_get_count(sensor->dataset);
        if (count < 2) continue;

        GdkRGBA *color = colors[sensor_count];
        cairo_set_source_rgba(cr, color->red, color->green, color->blue, color->alpha);

        gdouble max_temp = 100.0;  /* Scale to 100°C */

        if (style == XRG_GRAPH_STYLE_SOLID) {
            cairo_move_to(cr, 0, height);
            for (gint i = 0; i < count; i++) {
                gdouble temp = xrg_dataset_get_value(sensor->dataset, i);
                gdouble x = (gdouble)i / count * width;
                gdouble y = height - (temp / max_temp * height);
                if (y < 0) y = 0;
                if (y > height) y = height;
                cairo_line_to(cr, x, y);
            }
            cairo_line_to(cr, width, height);
            cairo_close_path(cr);
            cairo_fill(cr);
        } else if (style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels - fill area with dots */
            gint dot_spacing = 4;
            for (gint i = 0; i < count; i++) {
                gdouble temp = xrg_dataset_get_value(sensor->dataset, i);
                gdouble x = (gdouble)i / count * width;
                gdouble y_top = height - (temp / max_temp * height);
                if (y_top < 0) y_top = 0;
                if (y_top > height) y_top = height;

                /* Fill from bottom to the data line with dots */
                for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                    cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots - fill area with small dots */
            gint dot_spacing = 2;
            for (gint i = 0; i < count; i++) {
                gdouble temp = xrg_dataset_get_value(sensor->dataset, i);
                gdouble x = (gdouble)i / count * width;
                gdouble y_top = height - (temp / max_temp * height);
                if (y_top < 0) y_top = 0;
                if (y_top > height) y_top = height;

                /* Fill from bottom to the data line with dots */
                for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                    cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
            for (gint i = 0; i < count; i++) {
                gdouble temp = xrg_dataset_get_value(sensor->dataset, i);
                gdouble x = (gdouble)i / count * width;
                gdouble y = height - (temp / max_temp * height);
                if (y < 0) y = 0;
                if (y > height) y = height;
                cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }

        sensor_count++;
    }

    /* Draw temperature bar on the right */
    if (sensor_count > 0) {
        gint bar_x = width - 20;
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Get current temperature from first sensor */
        XRGSensorData *first_sensor = (XRGSensorData *)temp_sensors->data;
        gdouble current_temp = first_sensor->current_value;
        gdouble temp_ratio = current_temp / 100.0;
        if (temp_ratio > 1.0) temp_ratio = 1.0;

        gdouble fill_height = temp_ratio * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    /* Draw text labels */
    cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    cairo_move_to(cr, 5, 12);
    cairo_show_text(cr, "Temperature");

    /* Show temperatures of up to 3 sensors */
    sensor_count = 0;
    gint y_offset = 26;
    for (GSList *l = temp_sensors; l != NULL && sensor_count < 3; l = l->next) {
        XRGSensorData *sensor = (XRGSensorData *)l->data;
        if (!sensor->is_enabled) continue;

        /* Convert temperature based on user preference */
        gdouble display_temp = sensor->current_value;
        const gchar *unit_symbol = "°C";

        if (state->prefs->temperature_units == XRG_TEMP_FAHRENHEIT) {
            /* Convert Celsius to Fahrenheit: F = (C × 9/5) + 32 */
            display_temp = (sensor->current_value * 9.0 / 5.0) + 32.0;
            unit_symbol = "°F";
        }

        gchar *line = g_strdup_printf("%s: %.1f%s", sensor->name, display_temp, unit_symbol);
        cairo_move_to(cr, 5, y_offset);
        cairo_show_text(cr, line);
        g_free(line);

        y_offset += 14;
        sensor_count++;
    }

    /* Set tooltip with all sensors */
    GString *tooltip_str = g_string_new("Sensors:\n");
    for (GSList *l = temp_sensors; l != NULL; l = l->next) {
        XRGSensorData *sensor = (XRGSensorData *)l->data;

        /* Convert temperature based on user preference */
        gdouble display_temp = sensor->current_value;
        const gchar *unit_symbol = "°C";

        if (state->prefs->temperature_units == XRG_TEMP_FAHRENHEIT) {
            /* Convert Celsius to Fahrenheit: F = (C × 9/5) + 32 */
            display_temp = (sensor->current_value * 9.0 / 5.0) + 32.0;
            unit_symbol = "°F";
        }

        g_string_append_printf(tooltip_str, "%s: %.1f%s\n",
                              sensor->name, display_temp, unit_symbol);
    }
    gtk_widget_set_tooltip_text(widget, tooltip_str->str);
    g_string_free(tooltip_str, TRUE);

    g_slist_free(temp_sensors);
    return FALSE;
}

/**
 * Handle battery button press
 */
static gboolean on_battery_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_battery_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show battery context menu
 */
static void show_battery_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Battery Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("Battery Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Stats */
    XRGBatteryStatus status = xrg_battery_collector_get_status(state->battery_collector);
    gint charge_percent = xrg_battery_collector_get_charge_percent(state->battery_collector);
    gint minutes_remaining = xrg_battery_collector_get_minutes_remaining(state->battery_collector);
    gint64 total_charge = xrg_battery_collector_get_total_charge(state->battery_collector);
    gint64 total_capacity = xrg_battery_collector_get_total_capacity(state->battery_collector);

    const gchar *status_str = "Unknown";
    switch (status) {
        case XRG_BATTERY_STATUS_DISCHARGING:
            status_str = "Discharging";
            break;
        case XRG_BATTERY_STATUS_CHARGING:
            status_str = "Charging";
            break;
        case XRG_BATTERY_STATUS_FULL:
            status_str = "Full";
            break;
        case XRG_BATTERY_STATUS_NOT_CHARGING:
            status_str = "Not Charging";
            break;
        case XRG_BATTERY_STATUS_NO_BATTERY:
            status_str = "No Battery";
            break;
        default:
            break;
    }

    gchar *stats_text;
    if (minutes_remaining > 0) {
        gint hours = minutes_remaining / 60;
        gint mins = minutes_remaining % 60;
        stats_text = g_strdup_printf("%s | %d%% | %dh %dm remaining",
                                     status_str, charge_percent, hours, mins);
    } else {
        stats_text = g_strdup_printf("%s | %d%% | %.1f/%.1f Wh",
                                     status_str, charge_percent,
                                     total_charge / 1000000.0, total_capacity / 1000000.0);
    }

    GtkWidget *stats_item = gtk_menu_item_new_with_label(stats_text);
    gtk_widget_set_sensitive(stats_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), stats_item);
    g_free(stats_text);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Handle battery motion notify
 */
static gboolean on_battery_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    /* Get datasets */
    XRGDataset *charge_dataset = state->battery_collector->charge_watts;
    XRGDataset *discharge_dataset = state->battery_collector->discharge_watts;
    gint count = xrg_dataset_get_count(charge_dataset);

    if (count < 2) {
        gtk_widget_set_tooltip_text(widget, "Battery: Waiting for data...");
        return FALSE;
    }

    /* Calculate which data point the mouse is over */
    gint index = (gint)((event->x / allocation.width) * count);
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;

    /* Get values at this index */
    gdouble charge_val = xrg_dataset_get_value(charge_dataset, index);
    gdouble discharge_val = xrg_dataset_get_value(discharge_dataset, index);

    /* Set tooltip */
    gchar *tooltip;
    if (charge_val > 0.1) {
        tooltip = g_strdup_printf("Battery\nCharging: %.1f W", charge_val);
    } else if (discharge_val > 0.1) {
        tooltip = g_strdup_printf("Battery\nDischarging: %.1f W", discharge_val);
    } else {
        tooltip = g_strdup_printf("Battery\nIdle");
    }
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * Handle sensors button press
 */
static gboolean on_sensors_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_sensors_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * Show sensors context menu
 */
static void show_sensors_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Sensors Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("Sensors Settings...");
    g_signal_connect_swapped(settings_item, "activate",
                             G_CALLBACK(xrg_preferences_window_show), state->prefs_window);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Separator */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    /* Get temperature sensors */
    GSList *temp_sensors = xrg_sensors_collector_get_temp_sensors(state->sensors_collector);

    if (temp_sensors == NULL) {
        GtkWidget *no_sensors_item = gtk_menu_item_new_with_label("No sensors detected");
        gtk_widget_set_sensitive(no_sensors_item, FALSE);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), no_sensors_item);
    } else {
        /* List all temperature sensors */
        for (GSList *l = temp_sensors; l != NULL; l = l->next) {
            XRGSensorData *sensor = (XRGSensorData *)l->data;
            gchar *sensor_text = g_strdup_printf("%s: %.1f %s",
                                                 sensor->name,
                                                 sensor->current_value,
                                                 sensor->units);
            GtkWidget *sensor_item = gtk_menu_item_new_with_label(sensor_text);
            gtk_widget_set_sensitive(sensor_item, FALSE);
            gtk_menu_shell_append(GTK_MENU_SHELL(menu), sensor_item);
            g_free(sensor_text);
        }
    }

    g_slist_free(temp_sensors);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Handle sensors motion notify
 */
static gboolean on_sensors_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Get temperature sensors */
    GSList *temp_sensors = xrg_sensors_collector_get_temp_sensors(state->sensors_collector);

    if (temp_sensors == NULL) {
        gtk_widget_set_tooltip_text(widget, "Sensors: No sensors detected");
        return FALSE;
    }

    /* Build tooltip with all sensors */
    GString *tooltip_str = g_string_new("Temperature Sensors\n");
    for (GSList *l = temp_sensors; l != NULL; l = l->next) {
        XRGSensorData *sensor = (XRGSensorData *)l->data;
        g_string_append_printf(tooltip_str, "%s: %.1f %s\n",
                              sensor->name,
                              sensor->current_value,
                              sensor->units);
    }

    gtk_widget_set_tooltip_text(widget, tooltip_str->str);
    g_string_free(tooltip_str, TRUE);
    g_slist_free(temp_sensors);

    return FALSE;
}

/**
 * Draw AI Token graph
 */
static gboolean on_draw_aitoken(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get AI Token datasets */
    XRGDataset *input_dataset = xrg_aitoken_collector_get_input_dataset(state->aitoken_collector);
    XRGDataset *output_dataset = xrg_aitoken_collector_get_output_dataset(state->aitoken_collector);
    XRGDataset *gemini_dataset = xrg_aitoken_collector_get_gemini_dataset(state->aitoken_collector);

    gint count = xrg_dataset_get_count(input_dataset);
    if (count < 2) {
        /* Not enough data yet */
        /* Draw label indicating waiting for data */
        GdkRGBA *text_color = &state->prefs->text_color;
        cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha * 0.5);
        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10);
        cairo_move_to(cr, 5, 12);
        cairo_show_text(cr, "AI Tokens: Waiting for data...");
        return FALSE;
    }

    /* Find maximum rate for scaling (minimum 100 tokens/min) */
    gdouble max_rate = 100.0;
    for (gint i = 0; i < count; i++) {
        gdouble input = xrg_dataset_get_value(input_dataset, i);
        gdouble output = xrg_dataset_get_value(output_dataset, i);
        gdouble gemini = xrg_dataset_get_value(gemini_dataset, i);
        if (input > max_rate) max_rate = input;
        if (output > max_rate) max_rate = output;
        if (gemini > max_rate) max_rate = gemini;
    }

    /* Draw input tokens (cyan - FG1) */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->aitoken_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(input_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(input_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(input_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(input_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw output tokens (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(output_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(output_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(output_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(output_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw Gemini tokens (green - FG3) */
    GdkRGBA *fg3_color = &state->prefs->graph_fg3_color;
    cairo_set_source_rgba(cr, fg3_color->red, fg3_color->green, fg3_color->blue, fg3_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(gemini_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(gemini_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(gemini_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(gemini_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    gdouble tokens_per_min = xrg_aitoken_collector_get_tokens_per_minute(state->aitoken_collector);
    guint64 total_tokens = xrg_aitoken_collector_get_total_tokens(state->aitoken_collector);

    /* Convert tokens per minute to tokens per second */
    gdouble token_rate = tokens_per_min / 60.0;

    /* Line 1: AI Tokens label */
    gchar *line1 = g_strdup_printf("AI Tokens");
    cairo_move_to(cr, 5, 15);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: Token rate */
    gchar *line2 = g_strdup_printf("Rate: %.0f/s", token_rate);
    cairo_move_to(cr, 5, 27);
    cairo_show_text(cr, line2);
    g_free(line2);

    /* Line 3: Total tokens */
    gchar *line3 = g_strdup_printf("Total: %lu", (unsigned long)total_tokens);
    cairo_move_to(cr, 5, 39);
    cairo_show_text(cr, line3);
    g_free(line3);

    /* Line 4: Cost or Cap display based on billing mode */
    gint next_y = 51;

    /* Update cost calculations */
    xrg_aitoken_collector_update_costs(state->aitoken_collector, state->prefs);

    /* Get Claude tokens for cap display */
    guint64 claude_tokens = xrg_aitoken_collector_get_claude_tokens(state->aitoken_collector);

    if (state->prefs->aitoken_claude_billing_mode == XRG_AITOKEN_BILLING_API) {
        /* API billing - show cost in USD */
        gdouble total_cost = xrg_aitoken_collector_get_total_cost(state->aitoken_collector);
        gchar *cost_str;
        if (total_cost < 0.01) {
            cost_str = g_strdup_printf("Cost: %.2f¢", total_cost * 100.0);
        } else {
            cost_str = g_strdup_printf("Cost: $%.2f", total_cost);
        }
        cairo_move_to(cr, 5, next_y);
        cairo_show_text(cr, cost_str);
        g_free(cost_str);
        next_y += 12;

        /* Show budget if set */
        if (state->prefs->aitoken_budget_daily > 0) {
            gdouble pct = (total_cost / state->prefs->aitoken_budget_daily) * 100.0;
            gchar *budget_str = g_strdup_printf("Budget: %.0f%%", pct);
            cairo_move_to(cr, 5, next_y);
            cairo_show_text(cr, budget_str);
            g_free(budget_str);
            next_y += 12;
        }
    } else {
        /* Cap billing - show usage percentage */
        /* Get effective cap - use tier default if manual cap is 0 */
        guint64 effective_cap = state->prefs->aitoken_claude_cap > 0 ?
            state->prefs->aitoken_claude_cap :
            get_claude_tier_weekly_cap(state->prefs->aitoken_claude_tier);

        if (effective_cap > 0) {
            gdouble usage = xrg_aitoken_collector_get_claude_cap_usage(
                state->aitoken_collector, effective_cap);

            /* Show tier name and usage */
            gchar *cap_str = g_strdup_printf("%s: %.1f%%",
                get_claude_tier_name(state->prefs->aitoken_claude_tier), usage * 100.0);
            cairo_move_to(cr, 5, next_y);
            cairo_show_text(cr, cap_str);
            g_free(cap_str);
            next_y += 12;

            /* Show tokens remaining */
            guint64 remaining = (claude_tokens < effective_cap) ?
                                (effective_cap - claude_tokens) : 0;
            gchar *remain_str = format_tokens(remaining);
            gchar *left_str = g_strdup_printf("Left: %s", remain_str);
            cairo_move_to(cr, 5, next_y);
            cairo_show_text(cr, left_str);
            g_free(remain_str);
            g_free(left_str);
            next_y += 12;
        }
    }

    /* Show per-model breakdown if enabled */
    if (state->prefs->aitoken_show_model_breakdown) {
        GHashTable *model_tokens = xrg_aitoken_collector_get_model_tokens(state->aitoken_collector);
        const gchar *current_model = xrg_aitoken_collector_get_current_model(state->aitoken_collector);

        if (model_tokens && g_hash_table_size(model_tokens) > 0) {

            /* Helper function to display each model */
            GHashTableIter iter;
            gpointer key, value;
            g_hash_table_iter_init(&iter, model_tokens);

            while (g_hash_table_iter_next(&iter, &key, &value)) {
                const gchar *model_name = (const gchar *)key;
                ModelTokens *tokens = (ModelTokens *)value;
                guint64 model_total = tokens->input_tokens + tokens->output_tokens;

                /* Truncate long model names */
                gchar *display_name = g_strdup(model_name);
                if (strlen(display_name) > 20) {
                    display_name[17] = '.';
                    display_name[18] = '.';
                    display_name[19] = '.';
                    display_name[20] = '\0';
                }

                /* Mark current model with asterisk */
                gchar *model_line;
                if (current_model && g_strcmp0(model_name, current_model) == 0) {
                    model_line = g_strdup_printf("* %s: %lu", display_name, (unsigned long)model_total);
                } else {
                    model_line = g_strdup_printf("  %s: %lu", display_name, (unsigned long)model_total);
                }

                cairo_move_to(cr, 5, next_y);
                cairo_show_text(cr, model_line);
                g_free(model_line);
                g_free(display_name);
                next_y += 12;
            }
        }
    }

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Find max token rate in dataset to scale the bar */
        gdouble max_rate = 1.0;  /* Minimum to avoid division by zero */
        for (gint i = 0; i < count; i++) {
            gdouble input_val = xrg_dataset_get_value(input_dataset, i);
            gdouble output_val = xrg_dataset_get_value(output_dataset, i);
            gdouble gemini_val = xrg_dataset_get_value(gemini_dataset, i);
            gdouble total_val = input_val + output_val + gemini_val;
            if (total_val > max_rate) {
                max_rate = total_val;
            }
        }

        /* Draw filled bar representing current token rate */
        gdouble current_value = token_rate / max_rate;
        if (current_value > 1.0) current_value = 1.0;  /* Cap at 100% */
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Keyboard shortcut handler
 */
static gboolean on_key_press(GtkWidget *widget, GdkEventKey *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Ctrl+, = Preferences */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_comma) {
        xrg_preferences_window_show(state->prefs_window);
        return TRUE;
    }

    /* Ctrl+Q = Quit */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_q) {
        gtk_widget_destroy(state->window);
        return TRUE;
    }

    /* Ctrl+1 = Toggle CPU */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_1) {
        state->prefs->show_cpu = !state->prefs->show_cpu;
        gtk_widget_set_visible(state->cpu_box, state->prefs->show_cpu);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+2 = Toggle Memory */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_2) {
        state->prefs->show_memory = !state->prefs->show_memory;
        gtk_widget_set_visible(state->memory_box, state->prefs->show_memory);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+3 = Toggle Network */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_3) {
        state->prefs->show_network = !state->prefs->show_network;
        gtk_widget_set_visible(state->network_box, state->prefs->show_network);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+4 = Toggle Disk */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_4) {
        state->prefs->show_disk = !state->prefs->show_disk;
        gtk_widget_set_visible(state->disk_box, state->prefs->show_disk);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+5 = Toggle AI Tokens */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_5) {
        state->prefs->show_aitoken = !state->prefs->show_aitoken;
        gtk_widget_set_visible(state->aitoken_box, state->prefs->show_aitoken);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+6 = Toggle GPU */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_6) {
        state->prefs->show_gpu = !state->prefs->show_gpu;
        gtk_widget_set_visible(state->gpu_box, state->prefs->show_gpu);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+7 = Toggle Battery */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_7) {
        state->prefs->show_battery = !state->prefs->show_battery;
        gtk_widget_set_visible(state->battery_box, state->prefs->show_battery);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+8 = Toggle Temperature/Sensors */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_8) {
        state->prefs->show_temperature = !state->prefs->show_temperature;
        gtk_widget_set_visible(state->sensors_box, state->prefs->show_temperature);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+9 = Toggle Process */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_9) {
        state->prefs->show_process = !state->prefs->show_process;
        gtk_widget_set_visible(state->process_box, state->prefs->show_process);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Ctrl+0 = Toggle Always on Top */
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_0) {
        state->prefs->window_always_on_top = !state->prefs->window_always_on_top;
        gtk_window_set_keep_above(GTK_WINDOW(state->window), state->prefs->window_always_on_top);
        xrg_preferences_save(state->prefs);
        return TRUE;
    }

    /* Escape = Close preferences dialog (if open) */
    if (event->keyval == GDK_KEY_Escape) {
        /* The preferences dialog handles its own escape key */
        return FALSE;
    }

    return FALSE;
}







/**
 * Draw CPU graph
 */
static gboolean on_draw_cpu(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get CPU datasets */
    XRGDataset *user_dataset = xrg_cpu_collector_get_user_dataset(state->cpu_collector);
    XRGDataset *system_dataset = xrg_cpu_collector_get_system_dataset(state->cpu_collector);

    gint count = xrg_dataset_get_count(user_dataset);
    if (count < 2) {
        /* Not enough data yet */
        return FALSE;
    }

    /* Draw user CPU usage (cyan - FG1) */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->cpu_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(user_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(user_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(user_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(user_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw system CPU usage on top (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble user_val = xrg_dataset_get_value(user_dataset, i);
            gdouble system_val = xrg_dataset_get_value(system_dataset, i);
            gdouble total_val = user_val + system_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots (stacked on top of user) */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble user_val = xrg_dataset_get_value(user_dataset, i);
            gdouble system_val = xrg_dataset_get_value(system_dataset, i);
            gdouble total_val = user_val + system_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - (user_val / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from user level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots (stacked on top of user) */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble user_val = xrg_dataset_get_value(user_dataset, i);
            gdouble system_val = xrg_dataset_get_value(system_dataset, i);
            gdouble total_val = user_val + system_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - (user_val / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from user level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots (stacked on top of user) */
        for (gint i = 0; i < count; i++) {
            gdouble user_val = xrg_dataset_get_value(user_dataset, i);
            gdouble system_val = xrg_dataset_get_value(system_dataset, i);
            gdouble total_val = user_val + system_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    gdouble total_usage = xrg_cpu_collector_get_total_usage(state->cpu_collector);
    gdouble load_avg = xrg_cpu_collector_get_load_average_1min(state->cpu_collector);

    /* Get user and system from latest values in datasets */
    gdouble user_usage = xrg_dataset_get_latest(user_dataset);
    gdouble system_usage = xrg_dataset_get_latest(system_dataset);

    /* Line 1: Total CPU */
    gchar *line1 = g_strdup_printf("CPU: %.1f%%", total_usage);
    cairo_move_to(cr, 5, 15);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: User and System */
    gchar *line2 = g_strdup_printf("User: %.1f%% | System: %.1f%%", user_usage, system_usage);
    cairo_move_to(cr, 5, 27);
    cairo_show_text(cr, line2);
    g_free(line2);

    /* Line 3: Load average */
    gchar *line3 = g_strdup_printf("Load: %.2f", load_avg);
    cairo_move_to(cr, 5, 39);
    cairo_show_text(cr, line3);
    g_free(line3);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Draw filled bar representing current CPU usage */
        gdouble current_value = total_usage / 100.0;
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Draw Memory graph
 */
static gboolean on_draw_memory(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get memory datasets */
    XRGDataset *used_dataset = xrg_memory_collector_get_used_dataset(state->memory_collector);
    XRGDataset *wired_dataset = xrg_memory_collector_get_wired_dataset(state->memory_collector);
    XRGDataset *cached_dataset = xrg_memory_collector_get_cached_dataset(state->memory_collector);

    gint count = xrg_dataset_get_count(used_dataset);
    if (count < 2) {
        /* Not enough data yet */
        return FALSE;
    }

    /* Draw used memory (cyan - FG1) - bottom layer */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->memory_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(used_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(used_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(used_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / 100.0 * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(used_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw wired memory on top (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble total_val = used_val + wired_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots (stacked on top of used) */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble total_val = used_val + wired_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - (used_val / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from used level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots (stacked on top of used) */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble total_val = used_val + wired_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - (used_val / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from used level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots (stacked on top of used) */
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble total_val = used_val + wired_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw cached memory on top (amber - FG3) */
    GdkRGBA *fg3_color = &state->prefs->graph_fg3_color;
    cairo_set_source_rgba(cr, fg3_color->red, fg3_color->green, fg3_color->blue, fg3_color->alpha * 0.5);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble cached_val = xrg_dataset_get_value(cached_dataset, i);
            gdouble total_val = used_val + wired_val + cached_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots (stacked on top of used+wired) */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble cached_val = xrg_dataset_get_value(cached_dataset, i);
            gdouble total_val = used_val + wired_val + cached_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - ((used_val + wired_val) / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from used+wired level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots (stacked on top of used+wired) */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble cached_val = xrg_dataset_get_value(cached_dataset, i);
            gdouble total_val = used_val + wired_val + cached_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y_bottom = height - ((used_val + wired_val) / 100.0 * height);
            gdouble y_top = height - (total_val / 100.0 * height);

            /* Fill from used+wired level to total level with dots */
            for (gdouble y = y_bottom; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots (stacked on top of used+wired) */
        for (gint i = 0; i < count; i++) {
            gdouble used_val = xrg_dataset_get_value(used_dataset, i);
            gdouble wired_val = xrg_dataset_get_value(wired_dataset, i);
            gdouble cached_val = xrg_dataset_get_value(cached_dataset, i);
            gdouble total_val = used_val + wired_val + cached_val;
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (total_val / 100.0 * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    guint64 total_memory = xrg_memory_collector_get_total_memory(state->memory_collector);
    guint64 used_memory = xrg_memory_collector_get_used_memory(state->memory_collector);
    guint64 swap_used = xrg_memory_collector_get_swap_used(state->memory_collector);

    /* Get cached memory from dataset (percentage) and convert to bytes */
    gdouble cached_percent = xrg_dataset_get_latest(cached_dataset);
    guint64 cached_memory = (guint64)(total_memory * cached_percent / 100.0);

    /* Convert from bytes to MB */
    gdouble total_mb = total_memory / (1024.0 * 1024.0);
    gdouble used_mb = used_memory / (1024.0 * 1024.0);
    gdouble cached_mb = cached_memory / (1024.0 * 1024.0);
    gdouble swap_mb = swap_used / (1024.0 * 1024.0);

    /* Line 1: Memory usage */
    gchar *line1 = g_strdup_printf("Memory: %.0f/%.0f MB", used_mb, total_mb);
    cairo_move_to(cr, 5, 15);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: Cached memory */
    gchar *line2 = g_strdup_printf("Cached: %.0f MB", cached_mb);
    cairo_move_to(cr, 5, 27);
    cairo_show_text(cr, line2);
    g_free(line2);

    /* Line 3: Swap */
    gchar *line3 = g_strdup_printf("Swap: %.0f MB", swap_mb);
    cairo_move_to(cr, 5, 39);
    cairo_show_text(cr, line3);
    g_free(line3);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Draw filled bar representing current memory usage (used + wired + cached) */
        gdouble used_val = xrg_dataset_get_latest(used_dataset);
        gdouble wired_val = xrg_dataset_get_latest(wired_dataset);
        gdouble cached_val = xrg_dataset_get_latest(cached_dataset);
        gdouble current_value = (used_val + wired_val + cached_val) / 100.0;
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Draw Network graph
 */
static gboolean on_draw_network(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get network datasets */
    XRGDataset *download_dataset = xrg_network_collector_get_download_dataset(state->network_collector);
    XRGDataset *upload_dataset = xrg_network_collector_get_upload_dataset(state->network_collector);

    gint count = xrg_dataset_get_count(download_dataset);
    if (count < 2) {
        /* Not enough data yet */
        return FALSE;
    }

    /* Find maximum rate for scaling */
    gdouble max_rate = 0.1;  /* Minimum 0.1 MB/s */
    for (gint i = 0; i < count; i++) {
        gdouble download = xrg_dataset_get_value(download_dataset, i);
        gdouble upload = xrg_dataset_get_value(upload_dataset, i);
        if (download > max_rate) max_rate = download;
        if (upload > max_rate) max_rate = upload;
    }

    /* Draw download rate (cyan - FG1) */
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, fg1_color->alpha);

    XRGGraphStyle style = state->prefs->network_graph_style;

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(download_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(download_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(download_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(download_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Draw upload rate (purple - FG2) */
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;
    cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, fg2_color->alpha * 0.7);

    if (style == XRG_GRAPH_STYLE_SOLID) {
        /* Solid filled area (original behavior) */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(upload_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    } else if (style == XRG_GRAPH_STYLE_PIXEL) {
        /* Chunky pixels - fill area with dots */
        gint dot_spacing = 4;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(upload_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 1.5, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_DOT) {
        /* Fine dots - fill area with small dots */
        gint dot_spacing = 2;
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(upload_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y_top = height - (value / max_rate * height);

            /* Fill from bottom to the data line with dots */
            for (gdouble y = height; y >= y_top; y -= dot_spacing) {
                cairo_arc(cr, x, y, 0.6, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    } else if (style == XRG_GRAPH_STYLE_HOLLOW) {
        /* Hollow - outline only with dots */
        for (gint i = 0; i < count; i++) {
            gdouble value = xrg_dataset_get_value(upload_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (value / max_rate * height);
            cairo_arc(cr, x, y, 1.0, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }

    /* Overlay text labels */
    GdkRGBA *text_color = &state->prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    gdouble download_rate = xrg_network_collector_get_download_rate(state->network_collector);
    gdouble upload_rate = xrg_network_collector_get_upload_rate(state->network_collector);

    /* Line 1: Network label */
    gchar *line1 = g_strdup_printf("Network");
    cairo_move_to(cr, 5, 15);
    cairo_show_text(cr, line1);
    g_free(line1);

    /* Line 2: Download rate */
    gchar *line2 = g_strdup_printf("↓ %.2f MB/s", download_rate);
    cairo_move_to(cr, 5, 27);
    cairo_show_text(cr, line2);
    g_free(line2);

    /* Line 3: Upload rate */
    gchar *line3 = g_strdup_printf("↑ %.2f MB/s", upload_rate);
    cairo_move_to(cr, 5, 39);
    cairo_show_text(cr, line3);
    g_free(line3);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Find max download rate in dataset to scale the bar */
        gdouble max_rate = 0.1;  /* Minimum to avoid division by zero */
        for (gint i = 0; i < count; i++) {
            gdouble rate = xrg_dataset_get_value(download_dataset, i);
            if (rate > max_rate) {
                max_rate = rate;
            }
        }

        /* Draw filled bar representing current download rate */
        gdouble current_value = download_rate / max_rate;
        if (current_value > 1.0) current_value = 1.0;  /* Cap at 100% */
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * Process module draw callback
 */
static gboolean on_draw_process(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);

    gint width = allocation.width;
    gint height = allocation.height;

    /* Draw background */
    GdkRGBA *bg_color = &state->prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &state->prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get colors */
    GdkRGBA *text_color = &state->prefs->text_color;
    GdkRGBA *fg1_color = &state->prefs->graph_fg1_color;
    GdkRGBA *fg2_color = &state->prefs->graph_fg2_color;

    /* Font setup */
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10);

    /* Calculate layout */
    gint margin = 4;
    gint header_height = 14;
    gint row_height = 14;
    gint y_offset = margin;

    /* Draw header */
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.7);

    XRGProcessSortBy sort_by = xrg_process_collector_get_sort_by(state->process_collector);

    /* Column headers */
    gint col_name = margin;
    gint col_cpu = width - 90;
    gint col_mem = width - 45;

    cairo_move_to(cr, col_name, y_offset + 10);
    cairo_show_text(cr, "Process");

    cairo_move_to(cr, col_cpu, y_offset + 10);
    if (sort_by == XRG_PROCESS_SORT_CPU) {
        cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, 1.0);
    }
    cairo_show_text(cr, "CPU%");

    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.7);
    cairo_move_to(cr, col_mem, y_offset + 10);
    if (sort_by == XRG_PROCESS_SORT_MEMORY) {
        cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, 1.0);
    }
    cairo_show_text(cr, "Mem%");

    y_offset += header_height + 2;

    /* Draw separator line */
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.3);
    cairo_set_line_width(cr, 0.5);
    cairo_move_to(cr, margin, y_offset);
    cairo_line_to(cr, width - margin, y_offset);
    cairo_stroke(cr);

    y_offset += 4;

    /* Draw process list */
    GList *processes = xrg_process_collector_get_processes(state->process_collector);

    /* Calculate how many processes fit */
    gint available_height = height - y_offset - margin;
    gint max_rows = available_height / row_height;

    gint row = 0;
    for (GList *l = processes; l != NULL && row < max_rows; l = l->next, row++) {
        XRGProcessInfo *proc = l->data;
        gint row_y = y_offset + row * row_height;

        /* Process name (truncate if needed) */
        gchar name_buf[24];
        if (proc->name) {
            g_snprintf(name_buf, sizeof(name_buf), "%.18s", proc->name);
        } else {
            g_snprintf(name_buf, sizeof(name_buf), "%d", proc->pid);
        }

        cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.9);
        cairo_move_to(cr, col_name, row_y + row_height - 3);
        cairo_show_text(cr, name_buf);

        /* CPU bar and percentage */
        gint bar_width = 30;
        gint bar_height = row_height - 4;
        gint bar_x = col_cpu - bar_width - 2;
        gdouble cpu_ratio = CLAMP(proc->cpu_percent / 100.0, 0.0, 1.0);

        /* CPU bar background */
        cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, 0.2);
        cairo_rectangle(cr, bar_x, row_y + 2, bar_width, bar_height);
        cairo_fill(cr);

        /* CPU bar fill */
        if (cpu_ratio > 0) {
            cairo_set_source_rgba(cr, fg1_color->red, fg1_color->green, fg1_color->blue, 0.8);
            cairo_rectangle(cr, bar_x, row_y + 2, (gint)(cpu_ratio * bar_width), bar_height);
            cairo_fill(cr);
        }

        /* CPU text */
        gchar cpu_str[16];
        g_snprintf(cpu_str, sizeof(cpu_str), "%4.1f", proc->cpu_percent);
        cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.9);
        cairo_move_to(cr, col_cpu, row_y + row_height - 3);
        cairo_show_text(cr, cpu_str);

        /* Memory bar and percentage */
        bar_x = col_mem - bar_width - 2;
        gdouble mem_ratio = CLAMP(proc->mem_percent / 100.0, 0.0, 1.0);

        /* Memory bar background */
        cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, 0.2);
        cairo_rectangle(cr, bar_x, row_y + 2, bar_width, bar_height);
        cairo_fill(cr);

        /* Memory bar fill */
        if (mem_ratio > 0) {
            cairo_set_source_rgba(cr, fg2_color->red, fg2_color->green, fg2_color->blue, 0.8);
            cairo_rectangle(cr, bar_x, row_y + 2, (gint)(mem_ratio * bar_width), bar_height);
            cairo_fill(cr);
        }

        /* Memory text */
        gchar mem_str[16];
        g_snprintf(mem_str, sizeof(mem_str), "%4.1f", proc->mem_percent);
        cairo_move_to(cr, col_mem, row_y + row_height - 3);
        cairo_show_text(cr, mem_str);
    }

    /* Draw summary at bottom if space permits */
    gint summary_y = height - margin - 2;
    if (summary_y > y_offset + row * row_height + 10) {
        gint total = xrg_process_collector_get_total_processes(state->process_collector);
        gint running = xrg_process_collector_get_running_processes(state->process_collector);

        gchar summary[64];
        g_snprintf(summary, sizeof(summary), "Processes: %d (%d running)", total, running);

        cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, 0.5);
        cairo_set_font_size(cr, 9);
        cairo_move_to(cr, margin, summary_y);
        cairo_show_text(cr, summary);
    }

    return FALSE;
}

/**
 * Process module button press callback
 */
static gboolean on_process_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    (void)widget;

    if (event->button == 3) {  /* Right-click */
        show_process_context_menu(state, event);
        return TRUE;
    } else if (event->button == 1) {  /* Left-click */
        /* Toggle sort between CPU and Memory */
        XRGProcessSortBy current = xrg_process_collector_get_sort_by(state->process_collector);
        if (current == XRG_PROCESS_SORT_CPU) {
            xrg_process_collector_set_sort_by(state->process_collector, XRG_PROCESS_SORT_MEMORY);
        } else {
            xrg_process_collector_set_sort_by(state->process_collector, XRG_PROCESS_SORT_CPU);
        }
        gtk_widget_queue_draw(state->process_drawing_area);
        return TRUE;
    }

    return FALSE;
}

/**
 * Process module motion notify callback (for tooltips)
 */
static gboolean on_process_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    (void)user_data;
    (void)event;

    /* Request tooltip update */
    gtk_widget_trigger_tooltip_query(widget);

    return FALSE;
}

/**
 * Process module context menu
 */
static void show_process_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* Sort by CPU */
    GtkWidget *sort_cpu_item = gtk_check_menu_item_new_with_label("Sort by CPU");
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(sort_cpu_item),
        xrg_process_collector_get_sort_by(state->process_collector) == XRG_PROCESS_SORT_CPU);
    g_signal_connect(sort_cpu_item, "activate", G_CALLBACK(on_process_sort_cpu), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), sort_cpu_item);

    /* Sort by Memory */
    GtkWidget *sort_mem_item = gtk_check_menu_item_new_with_label("Sort by Memory");
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(sort_mem_item),
        xrg_process_collector_get_sort_by(state->process_collector) == XRG_PROCESS_SORT_MEMORY);
    g_signal_connect(sort_mem_item, "activate", G_CALLBACK(on_process_sort_memory), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), sort_mem_item);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Sort by CPU menu callback
 */
static void on_process_sort_cpu(GtkMenuItem *item, gpointer user_data) {
    (void)item;
    AppState *state = (AppState *)user_data;
    xrg_process_collector_set_sort_by(state->process_collector, XRG_PROCESS_SORT_CPU);
    gtk_widget_queue_draw(state->process_drawing_area);
}

/**
 * Sort by Memory menu callback
 */
static void on_process_sort_memory(GtkMenuItem *item, gpointer user_data) {
    (void)item;
    AppState *state = (AppState *)user_data;
    xrg_process_collector_set_sort_by(state->process_collector, XRG_PROCESS_SORT_MEMORY);
    gtk_widget_queue_draw(state->process_drawing_area);
}

/* ============================================================ */
/* TPU Module Functions                                          */
/* ============================================================ */

/* Coral brand colors */
#define CORAL_ORANGE_R 1.0
#define CORAL_ORANGE_G 0.45
#define CORAL_ORANGE_B 0.2

#define CORAL_TEAL_R 0.0
#define CORAL_TEAL_G 0.7
#define CORAL_TEAL_B 0.7

/**
 * Get TPU status text
 */
static const gchar* get_tpu_status_text(XRGTPUStatus status) {
    switch (status) {
        case XRG_TPU_STATUS_CONNECTED:  return "Connected";
        case XRG_TPU_STATUS_BUSY:       return "Inferencing";
        case XRG_TPU_STATUS_ERROR:      return "Error";
        case XRG_TPU_STATUS_DISCONNECTED:
        default:                        return "Disconnected";
    }
}

/**
 * Draw TPU graph with 3-color stacked display for usage categories
 */
static gboolean on_draw_tpu(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    XRGPreferences *prefs = state->prefs;
    XRGTPUCollector *collector = state->tpu_collector;

    gint width = gtk_widget_get_allocated_width(widget);
    gint height = gtk_widget_get_allocated_height(widget);

    /* Draw background */
    GdkRGBA *bg_color = &prefs->graph_bg_color;
    cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    /* Draw border */
    GdkRGBA *border_color = &prefs->border_color;
    cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0.5, 0.5, width - 1, height - 1);
    cairo_stroke(cr);

    /* Get TPU data */
    XRGTPUStatus status = xrg_tpu_collector_get_status(collector);
    const gchar *name = xrg_tpu_collector_get_name(collector);
    gdouble inf_per_sec = xrg_tpu_collector_get_inferences_per_second(collector);
    gdouble latency = xrg_tpu_collector_get_last_latency_ms(collector);
    guint64 total_inf = xrg_tpu_collector_get_total_inferences(collector);

    /* Get category breakdown */
    guint64 direct_inf = xrg_tpu_collector_get_direct_inferences(collector);
    guint64 hooked_inf = xrg_tpu_collector_get_hooked_inferences(collector);
    guint64 logged_inf = xrg_tpu_collector_get_logged_inferences(collector);
    guint64 warming_inf = xrg_tpu_collector_get_warming_inferences(collector);

    /* Get 4-color datasets for stacked graph */
    XRGDataset *direct_dataset = xrg_tpu_collector_get_direct_dataset(collector);
    XRGDataset *hooked_dataset = xrg_tpu_collector_get_hooked_dataset(collector);
    XRGDataset *logged_dataset = xrg_tpu_collector_get_logged_dataset(collector);
    XRGDataset *warming_dataset = xrg_tpu_collector_get_warming_dataset(collector);
    gint count = xrg_dataset_get_count(direct_dataset);

    /* Draw 4-color stacked inference rate graph */
    if (count >= 2) {
        /* Find max stacked value for scaling */
        gdouble max_rate = 1.0;
        for (gint i = 0; i < count; i++) {
            gdouble direct = xrg_dataset_get_value(direct_dataset, i);
            gdouble hooked = xrg_dataset_get_value(hooked_dataset, i);
            gdouble logged = xrg_dataset_get_value(logged_dataset, i);
            gdouble warming = xrg_dataset_get_value(warming_dataset, i);
            gdouble total = direct + hooked + logged + warming;
            if (total > max_rate) max_rate = total;
        }
        max_rate = max_rate * 1.2;  /* Add 20% headroom */

        /* Layer 1 (bottom): Warming - Gold */
        cairo_set_source_rgba(cr, 1.0, 0.8, 0.2, 0.8);  /* Gold */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble direct = xrg_dataset_get_value(direct_dataset, i);
            gdouble hooked = xrg_dataset_get_value(hooked_dataset, i);
            gdouble logged = xrg_dataset_get_value(logged_dataset, i);
            gdouble warming = xrg_dataset_get_value(warming_dataset, i);
            gdouble stacked = direct + hooked + logged + warming;  /* Full stack */
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (stacked / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);

        /* Layer 2: Logged - Orange */
        cairo_set_source_rgba(cr, CORAL_ORANGE_R, CORAL_ORANGE_G, CORAL_ORANGE_B, 0.8);
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble direct = xrg_dataset_get_value(direct_dataset, i);
            gdouble hooked = xrg_dataset_get_value(hooked_dataset, i);
            gdouble logged = xrg_dataset_get_value(logged_dataset, i);
            gdouble stacked = direct + hooked + logged;  /* Without warming */
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (stacked / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);

        /* Layer 3: Hooked - Green */
        cairo_set_source_rgba(cr, 0.2, 0.85, 0.4, 0.85);  /* Bright green */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble direct = xrg_dataset_get_value(direct_dataset, i);
            gdouble hooked = xrg_dataset_get_value(hooked_dataset, i);
            gdouble stacked = direct + hooked;  /* Direct + hooked only */
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (stacked / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);

        /* Layer 3 (top): Direct - Cyan */
        cairo_set_source_rgba(cr, 0.0, 0.8, 0.9, 0.9);  /* Cyan */
        cairo_move_to(cr, 0, height);
        for (gint i = 0; i < count; i++) {
            gdouble direct = xrg_dataset_get_value(direct_dataset, i);
            gdouble x = (gdouble)i / count * width;
            gdouble y = height - (direct / max_rate * height);
            cairo_line_to(cr, x, y);
        }
        cairo_line_to(cr, width, height);
        cairo_close_path(cr);
        cairo_fill(cr);
    }

    /* Draw status indicator (top-left circle) */
    gdouble sr, sg, sb;
    switch (status) {
        case XRG_TPU_STATUS_CONNECTED:
            sr = 0.2; sg = 0.8; sb = 0.3;  /* Green */
            break;
        case XRG_TPU_STATUS_BUSY:
            sr = CORAL_ORANGE_R; sg = CORAL_ORANGE_G; sb = CORAL_ORANGE_B;
            break;
        case XRG_TPU_STATUS_ERROR:
            sr = 0.9; sg = 0.2; sb = 0.2;  /* Red */
            break;
        default:
            sr = 0.5; sg = 0.5; sb = 0.5;  /* Gray */
            break;
    }
    cairo_set_source_rgba(cr, sr, sg, sb, 1.0);
    cairo_arc(cr, 8, 8, 4, 0, 2 * G_PI);
    cairo_fill(cr);

    /* Overlay text labels */
    GdkRGBA *text_color = &prefs->text_color;
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10.0);

    /* Line 1: Device name */
    cairo_move_to(cr, 16, 12);
    cairo_show_text(cr, name);

    /* Line 2: Inference rate or status */
    gchar *rate_text;
    if (inf_per_sec > 0) {
        rate_text = g_strdup_printf("Rate: %.1f inf/s", inf_per_sec);
    } else {
        rate_text = g_strdup_printf("Status: %s", get_tpu_status_text(status));
    }
    cairo_move_to(cr, 5, 26);
    cairo_show_text(cr, rate_text);
    g_free(rate_text);

    /* Line 3: Latency */
    gchar *latency_text;
    if (latency > 0) {
        latency_text = g_strdup_printf("Latency: %.1f ms", latency);
    } else {
        latency_text = g_strdup_printf("Latency: --");
    }
    cairo_move_to(cr, 5, 38);
    cairo_show_text(cr, latency_text);
    g_free(latency_text);

    /* Line 4: Total inferences with breakdown */
    gchar *total_text;
    if (total_inf > 1000000) {
        total_text = g_strdup_printf("Total: %.2fM inf", total_inf / 1000000.0);
    } else if (total_inf > 1000) {
        total_text = g_strdup_printf("Total: %.1fK inf", total_inf / 1000.0);
    } else {
        total_text = g_strdup_printf("Total: %lu inf", (unsigned long)total_inf);
    }
    cairo_move_to(cr, 5, 50);
    cairo_show_text(cr, total_text);
    g_free(total_text);

    /* Color legend (bottom-right corner) */
    cairo_set_font_size(cr, 8.0);
    gint legend_x = width - 80;
    gint legend_y = height - 46;

    /* Cyan - Direct */
    cairo_set_source_rgba(cr, 0.0, 0.8, 0.9, 1.0);
    cairo_rectangle(cr, legend_x, legend_y, 8, 8);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_move_to(cr, legend_x + 11, legend_y + 7);
    gchar *direct_txt = g_strdup_printf("Direct %lu", (unsigned long)direct_inf);
    cairo_show_text(cr, direct_txt);
    g_free(direct_txt);

    /* Green - Hooked */
    cairo_set_source_rgba(cr, 0.2, 0.85, 0.4, 1.0);
    cairo_rectangle(cr, legend_x, legend_y + 11, 8, 8);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_move_to(cr, legend_x + 11, legend_y + 18);
    gchar *hooked_txt = g_strdup_printf("Hooked %lu", (unsigned long)hooked_inf);
    cairo_show_text(cr, hooked_txt);
    g_free(hooked_txt);

    /* Orange - Logged */
    cairo_set_source_rgba(cr, CORAL_ORANGE_R, CORAL_ORANGE_G, CORAL_ORANGE_B, 1.0);
    cairo_rectangle(cr, legend_x, legend_y + 22, 8, 8);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_move_to(cr, legend_x + 11, legend_y + 29);
    gchar *logged_txt = g_strdup_printf("Logged %lu", (unsigned long)logged_inf);
    cairo_show_text(cr, logged_txt);
    g_free(logged_txt);

    /* Gold - Warming */
    cairo_set_source_rgba(cr, 1.0, 0.8, 0.2, 1.0);  /* Gold */
    cairo_rectangle(cr, legend_x, legend_y + 33, 8, 8);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, text_color->red, text_color->green, text_color->blue, text_color->alpha);
    cairo_move_to(cr, legend_x + 11, legend_y + 40);
    gchar *warming_txt = g_strdup_printf("Warming %lu", (unsigned long)warming_inf);
    cairo_show_text(cr, warming_txt);
    g_free(warming_txt);

    /* Draw activity bar on the right (if enabled) */
    if (state->prefs->show_activity_bars) {
        gint bar_x = width - 20;  /* 20px from right edge */
        gint bar_width = 20;

        /* Draw bar background */
        cairo_set_source_rgba(cr, bg_color->red, bg_color->green, bg_color->blue, bg_color->alpha);
        cairo_rectangle(cr, bar_x, 0, bar_width, height);
        cairo_fill(cr);

        /* Draw bar border */
        cairo_set_source_rgba(cr, border_color->red, border_color->green, border_color->blue, border_color->alpha);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, bar_x + 0.5, 0.5, bar_width - 1, height - 1);
        cairo_stroke(cr);

        /* Draw filled bar representing current inference rate */
        gdouble max_inf_rate = 100.0;  /* Max inferences per second for scaling */
        gdouble current_value = inf_per_sec / max_inf_rate;
        if (current_value > 1.0) current_value = 1.0;  /* Cap at 100% */
        gdouble fill_height = current_value * height;
        gdouble bar_y = height - fill_height;

        XRGGraphStyle bar_style = state->prefs->activity_bar_style;
        GdkRGBA gradient_color;

        if (bar_style == XRG_GRAPH_STYLE_SOLID) {
            /* Draw gradient by slicing horizontally */
            for (gdouble y = height; y >= bar_y; y -= 1.0) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                cairo_rectangle(cr, bar_x, y, bar_width, 1.0);
                cairo_fill(cr);
            }
        } else if (bar_style == XRG_GRAPH_STYLE_PIXEL) {
            /* Chunky pixels with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 4) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 4) {
                    cairo_arc(cr, x + 2, y, 1.5, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_DOT) {
            /* Fine dots with gradient colors */
            for (gdouble y = height; y >= bar_y; y -= 2) {
                gdouble position = (height - y) / height;
                get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
                cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
                for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                    cairo_arc(cr, x + 1, y, 0.6, 0, 2 * G_PI);
                    cairo_fill(cr);
                }
            }
        } else if (bar_style == XRG_GRAPH_STYLE_HOLLOW) {
            /* Outline only - draw dots at top of fill level with gradient color */
            gdouble position = (height - bar_y) / height;
            get_activity_bar_gradient_color(position, state->prefs, &gradient_color);
            cairo_set_source_rgba(cr, gradient_color.red, gradient_color.green, gradient_color.blue, gradient_color.alpha);
            for (gdouble x = bar_x; x < bar_x + bar_width; x += 2) {
                cairo_arc(cr, x, bar_y, 1.0, 0, 2 * G_PI);
                cairo_fill(cr);
            }
        }
    }

    return FALSE;
}

/**
 * TPU button press handler
 */
static gboolean on_tpu_button_press(GtkWidget *widget, GdkEventButton *event, gpointer user_data) {
    (void)widget;
    AppState *state = (AppState *)user_data;

    if (event->button == 3) {  /* Right click */
        show_tpu_context_menu(state, event);
        return TRUE;
    }

    return FALSE;
}

/**
 * TPU motion notify handler (for tooltips)
 */
static gboolean on_tpu_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer user_data) {
    (void)event;
    AppState *state = (AppState *)user_data;
    XRGTPUCollector *collector = state->tpu_collector;

    const gchar *name = xrg_tpu_collector_get_name(collector);
    XRGTPUStatus status = xrg_tpu_collector_get_status(collector);
    gdouble inf_per_sec = xrg_tpu_collector_get_inferences_per_second(collector);
    gdouble avg_latency = xrg_tpu_collector_get_avg_latency_ms(collector);
    guint64 total_inf = xrg_tpu_collector_get_total_inferences(collector);

    gchar *tooltip = g_strdup_printf("%s\n─────────────\nStatus: %s\nRate: %.2f inf/s\nAvg Latency: %.2f ms\nTotal: %lu inferences",
                                     name, get_tpu_status_text(status),
                                     inf_per_sec, avg_latency, (unsigned long)total_inf);
    gtk_widget_set_tooltip_text(widget, tooltip);
    g_free(tooltip);

    return FALSE;
}

/**
 * TPU context menu
 */
static void show_tpu_context_menu(AppState *state, GdkEventButton *event) {
    GtkWidget *menu = gtk_menu_new();

    /* TPU Settings */
    GtkWidget *settings_item = gtk_menu_item_new_with_label("TPU Settings...");
    g_signal_connect(settings_item, "activate",
                     G_CALLBACK(on_menu_tpu_settings), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), settings_item);

    /* Toggle visibility item */
    GtkWidget *toggle_item = gtk_check_menu_item_new_with_label("Show TPU");
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(toggle_item), state->prefs->show_tpu);
    g_signal_connect(toggle_item, "toggled", G_CALLBACK(on_menu_preferences), state);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), toggle_item);

    /* Stats file path info */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    const gchar *stats_path = xrg_tpu_collector_get_stats_file_path();
    gchar *path_label = g_strdup_printf("Stats: %s", stats_path);
    GtkWidget *path_item = gtk_menu_item_new_with_label(path_label);
    gtk_widget_set_sensitive(path_item, FALSE);  /* Informational only */
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), path_item);
    g_free(path_label);

    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
}

/**
 * Update timer callback (1 second interval)
 */
static gboolean on_update_timer(gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Update collectors */
    xrg_cpu_collector_update(state->cpu_collector);
    xrg_memory_collector_update(state->memory_collector);
    xrg_network_collector_update(state->network_collector);
    xrg_disk_collector_update(state->disk_collector);
    xrg_gpu_collector_update(state->gpu_collector);
    xrg_battery_collector_update(state->battery_collector);
    xrg_sensors_collector_update(state->sensors_collector);
    xrg_aitoken_collector_update(state->aitoken_collector);
    xrg_process_collector_update(state->process_collector);
    xrg_tpu_collector_update(state->tpu_collector);

    /* Redraw graphs */
    gtk_widget_queue_draw(state->cpu_drawing_area);
    gtk_widget_queue_draw(state->memory_drawing_area);
    gtk_widget_queue_draw(state->network_drawing_area);
    gtk_widget_queue_draw(state->disk_drawing_area);
    gtk_widget_queue_draw(state->gpu_drawing_area);
    gtk_widget_queue_draw(state->battery_drawing_area);
    gtk_widget_queue_draw(state->sensors_drawing_area);
    gtk_widget_queue_draw(state->aitoken_drawing_area);
    gtk_widget_queue_draw(state->process_drawing_area);
    gtk_widget_queue_draw(state->tpu_drawing_area);

    return G_SOURCE_CONTINUE;  /* Keep timer running */
}

/**
 * Window destroy callback (cleanup)
 */
static void on_window_destroy(GtkWidget *widget, gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Stop timer */
    if (state->update_timer_id > 0) {
        g_source_remove(state->update_timer_id);
    }

    /* Save window position */
    gint x, y, width, height;
    gtk_window_get_position(GTK_WINDOW(state->window), &x, &y);
    gtk_window_get_size(GTK_WINDOW(state->window), &width, &height);
    state->prefs->window_x = x;
    state->prefs->window_y = y;
    state->prefs->window_width = width;
    state->prefs->window_height = height - TITLE_BAR_HEIGHT;
    g_message("On exit - saving position: x=%d, y=%d, width=%d, height=%d", x, y, width, height - TITLE_BAR_HEIGHT);

    /* Sanity check: prevent saving black colors (corrupted) */
    if (state->prefs->graph_fg1_color.red < 0.01 &&
        state->prefs->graph_fg1_color.green < 0.01 &&
        state->prefs->graph_fg1_color.blue < 0.01) {
        g_warning("Colors corrupted to black! Restoring Cyberpunk theme defaults...");
        xrg_preferences_apply_theme(state->prefs, "Cyberpunk");
    }

    /* Save preferences */
    g_message("Saving on exit - Graph FG1: (%.3f, %.3f, %.3f, %.3f)",
              state->prefs->graph_fg1_color.red, state->prefs->graph_fg1_color.green,
              state->prefs->graph_fg1_color.blue, state->prefs->graph_fg1_color.alpha);
    xrg_preferences_save(state->prefs);

    /* Cleanup */
    xrg_cpu_collector_free(state->cpu_collector);
    xrg_memory_collector_free(state->memory_collector);
    xrg_network_collector_free(state->network_collector);
    xrg_disk_collector_free(state->disk_collector);
    xrg_gpu_collector_free(state->gpu_collector);
    xrg_aitoken_collector_free(state->aitoken_collector);
    xrg_preferences_window_free(state->prefs_window);
    xrg_preferences_free(state->prefs);
    g_free(state);

    g_message("XRG-ng for Linux stopped");
}

/**
 * Preferences applied callback - update module visibility and layout
 */
static void on_preferences_applied(gpointer user_data) {
    AppState *state = (AppState *)user_data;

    /* Update window properties */
    gtk_widget_set_opacity(state->window, state->prefs->window_opacity);
    gtk_window_set_keep_above(GTK_WINDOW(state->window), state->prefs->window_always_on_top);

    /* Update visibility of all module boxes based on preferences */
    gtk_widget_set_visible(state->cpu_box, state->prefs->show_cpu);
    gtk_widget_set_visible(state->memory_box, state->prefs->show_memory);
    gtk_widget_set_visible(state->network_box, state->prefs->show_network);
    gtk_widget_set_visible(state->disk_box, state->prefs->show_disk);
    gtk_widget_set_visible(state->gpu_box, state->prefs->show_gpu);
    gtk_widget_set_visible(state->battery_box, state->prefs->show_battery);
    gtk_widget_set_visible(state->sensors_box, state->prefs->show_temperature);
    gtk_widget_set_visible(state->aitoken_box, state->prefs->show_aitoken);

    /* Update module heights */
    gtk_widget_set_size_request(state->cpu_drawing_area, state->prefs->graph_width, state->prefs->graph_height_cpu);
    gtk_widget_set_size_request(state->memory_drawing_area, state->prefs->graph_width, state->prefs->graph_height_memory);
    gtk_widget_set_size_request(state->network_drawing_area, state->prefs->graph_width, state->prefs->graph_height_network);
    gtk_widget_set_size_request(state->disk_drawing_area, state->prefs->graph_width, state->prefs->graph_height_disk);
    gtk_widget_set_size_request(state->gpu_drawing_area, state->prefs->graph_width, state->prefs->graph_height_gpu);
    gtk_widget_set_size_request(state->battery_drawing_area, state->prefs->graph_width, state->prefs->graph_height_battery);
    gtk_widget_set_size_request(state->sensors_drawing_area, state->prefs->graph_width, state->prefs->graph_height_temperature);
    gtk_widget_set_size_request(state->aitoken_drawing_area, state->prefs->graph_width, state->prefs->graph_height_aitoken);

    /* Trigger redraw of all modules to apply new colors, styles, and settings */
    gtk_widget_queue_draw(state->cpu_drawing_area);
    gtk_widget_queue_draw(state->memory_drawing_area);
    gtk_widget_queue_draw(state->network_drawing_area);
    gtk_widget_queue_draw(state->disk_drawing_area);
    gtk_widget_queue_draw(state->gpu_drawing_area);
    gtk_widget_queue_draw(state->battery_drawing_area);
    gtk_widget_queue_draw(state->sensors_drawing_area);
    gtk_widget_queue_draw(state->aitoken_drawing_area);

    /* Check if layout orientation changed */
    if (state->current_layout_orientation != state->prefs->layout_orientation) {
        /* Show dialog to user that restart is needed */
        GtkWidget *dialog = gtk_message_dialog_new(GTK_WINDOW(state->window),
                                                   GTK_DIALOG_MODAL,
                                                   GTK_MESSAGE_INFO,
                                                   GTK_BUTTONS_OK_CANCEL,
                                                   "Layout orientation changed");
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog),
                                                 "XRG-ng needs to restart for the layout change to take effect.\nRestart now?");

        gint response = gtk_dialog_run(GTK_DIALOG(dialog));
        gtk_widget_destroy(dialog);

        if (response == GTK_RESPONSE_OK) {
            /* Restart the application */
            const gchar *appimage_path = g_getenv("APPIMAGE");
            if (appimage_path) {
                /* Running as AppImage - restart via AppImage */
                execl(appimage_path, appimage_path, NULL);
            } else {
                /* Try to restart using argv[0] or program path */
                gchar *program_path = g_find_program_in_path("xrg-linux");
                if (program_path) {
                    execl(program_path, "xrg-linux", NULL);
                    g_free(program_path);
                } else {
                    g_message("Could not find xrg-linux to restart. Please restart manually.");
                }
            }
        }
    }
}

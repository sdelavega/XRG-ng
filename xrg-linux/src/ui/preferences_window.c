#include "preferences_window.h"
#include <string.h>

struct _XRGPreferencesWindow {
    GtkWidget *window;
    GtkWidget *notebook;
    XRGPreferences *prefs;

    /* Window tab widgets */
    GtkWidget *window_x_spin;
    GtkWidget *window_y_spin;
    GtkWidget *window_width_spin;
    GtkWidget *window_height_spin;
    GtkWidget *window_opacity_scale;
    GtkWidget *window_always_on_top_check;
    GtkWidget *show_activity_bars_check;
    GtkWidget *activity_bar_style_combo;
    GtkWidget *layout_orientation_combo;
    GtkWidget *graph_width_spin;
    GtkWidget *fast_update_interval_spin;
    GtkWidget *normal_update_interval_spin;
    GtkWidget *slow_update_interval_spin;
    GtkWidget *vslow_update_interval_spin;

    /* CPU module tab widgets */
    GtkWidget *cpu_enabled_check;
    GtkWidget *cpu_height_spin;
    GtkWidget *cpu_update_interval_spin;
    GtkWidget *cpu_style_combo;

    /* Memory module tab widgets */
    GtkWidget *memory_enabled_check;
    GtkWidget *memory_height_spin;
    GtkWidget *memory_style_combo;

    /* Network module tab widgets */
    GtkWidget *network_enabled_check;
    GtkWidget *network_height_spin;
    GtkWidget *network_style_combo;

    /* Disk module tab widgets */
    GtkWidget *disk_enabled_check;
    GtkWidget *disk_height_spin;
    GtkWidget *disk_style_combo;

    /* GPU module tab widgets */
    GtkWidget *gpu_enabled_check;
    GtkWidget *gpu_height_spin;
    GtkWidget *gpu_style_combo;
    GtkWidget *gpu_temperature_units_combo;

    /* Battery module tab widgets */
    GtkWidget *battery_enabled_check;
    GtkWidget *battery_height_spin;
    GtkWidget *battery_style_combo;

    /* Temperature/Sensors module tab widgets */
    GtkWidget *temperature_enabled_check;
    GtkWidget *temperature_height_spin;
    GtkWidget *temperature_style_combo;
    GtkWidget *temperature_units_combo;

    /* AI Token module tab widgets */
    GtkWidget *aitoken_enabled_check;
    GtkWidget *aitoken_height_spin;
    GtkWidget *aitoken_style_combo;
    GtkWidget *aitoken_show_model_breakdown_check;
    GtkWidget *aitoken_jsonl_path_entry;
    GtkWidget *aitoken_db_path_entry;
    GtkWidget *aitoken_otel_endpoint_entry;
    GtkWidget *aitoken_auto_detect_check;
    /* Subscription tier selectors */
    GtkWidget *aitoken_claude_tier_combo;
    GtkWidget *aitoken_codex_tier_combo;
    GtkWidget *aitoken_gemini_tier_combo;
    GtkWidget *aitoken_claude_billing_combo;
    GtkWidget *aitoken_codex_billing_combo;
    GtkWidget *aitoken_gemini_billing_combo;

    /* Process module tab widgets */
    GtkWidget *process_enabled_check;
    GtkWidget *process_height_spin;

    /* TPU module tab widgets */
    GtkWidget *tpu_enabled_check;
    GtkWidget *tpu_height_spin;
    GtkWidget *tpu_style_combo;

    /* Colors tab widgets */
    GtkWidget *theme_combo;
    GtkWidget *bg_color_button;
    GtkWidget *graph_bg_color_button;
    GtkWidget *graph_fg1_color_button;
    GtkWidget *graph_fg2_color_button;
    GtkWidget *graph_fg3_color_button;
    GtkWidget *text_color_button;
    GtkWidget *border_color_button;
    GtkWidget *activity_bar_color_button;

    /* Callback for when preferences are applied */
    XRGPreferencesAppliedCallback applied_callback;
    gpointer callback_user_data;
};

/* Forward declarations */
static void on_response(GtkDialog *dialog, gint response_id, gpointer user_data);
static void on_theme_changed(GtkComboBox *combo, gpointer user_data);
static GtkWidget* create_window_tab(XRGPreferencesWindow *win);
static GtkWidget* create_cpu_tab(XRGPreferencesWindow *win);
static GtkWidget* create_memory_tab(XRGPreferencesWindow *win);
static GtkWidget* create_network_tab(XRGPreferencesWindow *win);
static GtkWidget* create_disk_tab(XRGPreferencesWindow *win);
static GtkWidget* create_gpu_tab(XRGPreferencesWindow *win);
static GtkWidget* create_battery_tab(XRGPreferencesWindow *win);
static GtkWidget* create_temperature_tab(XRGPreferencesWindow *win);
static GtkWidget* create_aitoken_tab(XRGPreferencesWindow *win);
static GtkWidget* create_tpu_tab(XRGPreferencesWindow *win);
static GtkWidget* create_process_tab(XRGPreferencesWindow *win);
static GtkWidget* create_colors_tab(XRGPreferencesWindow *win);
static void load_preferences_to_ui(XRGPreferencesWindow *win);
static void save_ui_to_preferences(XRGPreferencesWindow *win);

/**
 * Create new preferences window
 */
XRGPreferencesWindow* xrg_preferences_window_new(GtkWindow *parent, XRGPreferences *prefs) {
    XRGPreferencesWindow *win = g_new0(XRGPreferencesWindow, 1);
    win->prefs = prefs;

    /* Create dialog window */
    win->window = gtk_dialog_new_with_buttons("XRG-ng for Linux Preferences",
                                               parent,
                                               GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                               "Cancel", GTK_RESPONSE_CANCEL,
                                               "Apply", GTK_RESPONSE_APPLY,
                                               "OK", GTK_RESPONSE_OK,
                                               NULL);

    gtk_window_set_default_size(GTK_WINDOW(win->window), 600, 500);

    /* Create notebook for tabs */
    win->notebook = gtk_notebook_new();
    gtk_container_set_border_width(GTK_CONTAINER(win->notebook), 10);

    /* Add tabs */
    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_window_tab(win),
                            gtk_label_new("Window"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_cpu_tab(win),
                            gtk_label_new("CPU Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_memory_tab(win),
                            gtk_label_new("Memory Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_network_tab(win),
                            gtk_label_new("Network Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_disk_tab(win),
                            gtk_label_new("Disk Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_gpu_tab(win),
                            gtk_label_new("GPU Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_battery_tab(win),
                            gtk_label_new("Battery Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_temperature_tab(win),
                            gtk_label_new("Temperature Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_aitoken_tab(win),
                            gtk_label_new("AI Token Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_tpu_tab(win),
                            gtk_label_new("TPU Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_process_tab(win),
                            gtk_label_new("Process Module"));

    gtk_notebook_append_page(GTK_NOTEBOOK(win->notebook),
                            create_colors_tab(win),
                            gtk_label_new("Colors"));

    /* Add notebook to dialog content area */
    GtkWidget *content_area = gtk_dialog_get_content_area(GTK_DIALOG(win->window));
    gtk_container_add(GTK_CONTAINER(content_area), win->notebook);

    /* Connect response signal */
    g_signal_connect(win->window, "response", G_CALLBACK(on_response), win);

    /* Load current preferences into UI */
    load_preferences_to_ui(win);

    return win;
}

/**
 * Create Window settings tab
 */
static GtkWidget* create_window_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Window position section */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Window Position</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* X position */
    label = gtk_label_new("X Position:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->window_x_spin = gtk_spin_button_new_with_range(0, 3840, 1);
    gtk_grid_attach(GTK_GRID(grid), win->window_x_spin, 1, row++, 1, 1);

    /* Y position */
    label = gtk_label_new("Y Position:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->window_y_spin = gtk_spin_button_new_with_range(0, 2160, 1);
    gtk_grid_attach(GTK_GRID(grid), win->window_y_spin, 1, row++, 1, 1);

    /* Width */
    label = gtk_label_new("Width:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->window_width_spin = gtk_spin_button_new_with_range(100, 800, 10);
    gtk_grid_attach(GTK_GRID(grid), win->window_width_spin, 1, row++, 1, 1);

    /* Height */
    label = gtk_label_new("Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->window_height_spin = gtk_spin_button_new_with_range(100, 1200, 10);
    gtk_grid_attach(GTK_GRID(grid), win->window_height_spin, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Window behavior section */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Window Behavior</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Always on top */
    win->window_always_on_top_check = gtk_check_button_new_with_label("Always on top");
    gtk_grid_attach(GTK_GRID(grid), win->window_always_on_top_check, 0, row++, 2, 1);

    /* Opacity */
    label = gtk_label_new("Opacity:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->window_opacity_scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.1, 1.0, 0.05);
    gtk_scale_set_value_pos(GTK_SCALE(win->window_opacity_scale), GTK_POS_RIGHT);
    gtk_widget_set_hexpand(win->window_opacity_scale, TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->window_opacity_scale, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display features section */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Features</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Activity bars */
    win->show_activity_bars_check = gtk_check_button_new_with_label("Show Activity Bars");
    gtk_grid_attach(GTK_GRID(grid), win->show_activity_bars_check, 0, row++, 2, 1);

    /* Activity bar style */
    label = gtk_label_new("Activity Bar Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);

    win->activity_bar_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->activity_bar_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->activity_bar_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->activity_bar_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->activity_bar_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->activity_bar_style_combo, 1, row++, 1, 1);

    /* Layout orientation */
    label = gtk_label_new("Layout Orientation:");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);

    win->layout_orientation_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->layout_orientation_combo), "Vertical (Stacked)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->layout_orientation_combo), "Horizontal (Side-by-Side)");
    gtk_grid_attach(GTK_GRID(grid), win->layout_orientation_combo, 1, row++, 1, 1);

    /* Graph width */
    label = gtk_label_new("Graph Width:");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->graph_width_spin = gtk_spin_button_new_with_range(100, 800, 10);
    gtk_grid_attach(GTK_GRID(grid), win->graph_width_spin, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Update Intervals section */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Update Intervals (milliseconds)</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Fast update interval (CPU, Network) */
    label = gtk_label_new("Fast (CPU, Network):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->fast_update_interval_spin = gtk_spin_button_new_with_range(50, 500, 10);
    gtk_grid_attach(GTK_GRID(grid), win->fast_update_interval_spin, 1, row++, 1, 1);

    /* Normal update interval (Memory, Disk, GPU) */
    label = gtk_label_new("Normal (Memory, Disk, GPU):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->normal_update_interval_spin = gtk_spin_button_new_with_range(100, 5000, 100);
    gtk_grid_attach(GTK_GRID(grid), win->normal_update_interval_spin, 1, row++, 1, 1);

    /* Slow update interval (Temperature, Battery) */
    label = gtk_label_new("Slow (Temperature, Battery):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->slow_update_interval_spin = gtk_spin_button_new_with_range(1000, 10000, 500);
    gtk_grid_attach(GTK_GRID(grid), win->slow_update_interval_spin, 1, row++, 1, 1);

    /* Very slow update interval (Weather, Stocks) */
    label = gtk_label_new("Very Slow (Weather, Stocks):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->vslow_update_interval_spin = gtk_spin_button_new_with_range(10000, 600000, 5000);
    gtk_grid_attach(GTK_GRID(grid), win->vslow_update_interval_spin, 1, row++, 1, 1);

    return grid;
}

/**
 * Create CPU module settings tab
 */
static GtkWidget* create_cpu_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->cpu_enabled_check = gtk_check_button_new_with_label("Show CPU Module");
    gtk_grid_attach(GTK_GRID(grid), win->cpu_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->cpu_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->cpu_height_spin, 1, row++, 1, 1);

    /* Update interval */
    label = gtk_label_new("Update Interval (ms):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->cpu_update_interval_spin = gtk_spin_button_new_with_range(100, 5000, 100);
    gtk_grid_attach(GTK_GRID(grid), win->cpu_update_interval_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->cpu_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->cpu_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->cpu_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->cpu_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->cpu_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->cpu_style_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Memory module settings tab
 */
static GtkWidget* create_memory_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->memory_enabled_check = gtk_check_button_new_with_label("Show Memory Module");
    gtk_grid_attach(GTK_GRID(grid), win->memory_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->memory_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->memory_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->memory_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->memory_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->memory_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->memory_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->memory_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->memory_style_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Network module settings tab
 */
static GtkWidget* create_network_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->network_enabled_check = gtk_check_button_new_with_label("Show Network Module");
    gtk_grid_attach(GTK_GRID(grid), win->network_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->network_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->network_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->network_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->network_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->network_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->network_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->network_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->network_style_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Disk module settings tab
 */
static GtkWidget* create_disk_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->disk_enabled_check = gtk_check_button_new_with_label("Show Disk Module");
    gtk_grid_attach(GTK_GRID(grid), win->disk_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->disk_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->disk_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->disk_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->disk_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->disk_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->disk_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->disk_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->disk_style_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create GPU module settings tab
 */
static GtkWidget* create_gpu_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->gpu_enabled_check = gtk_check_button_new_with_label("Show GPU Module");
    gtk_grid_attach(GTK_GRID(grid), win->gpu_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->gpu_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->gpu_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->gpu_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->gpu_style_combo, 1, row++, 1, 1);

    /* Temperature units */
    label = gtk_label_new("Temperature Units:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->gpu_temperature_units_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_temperature_units_combo), "Celsius (°C)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->gpu_temperature_units_combo), "Fahrenheit (°F)");
    gtk_grid_attach(GTK_GRID(grid), win->gpu_temperature_units_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Battery module settings tab
 */
static GtkWidget* create_battery_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->battery_enabled_check = gtk_check_button_new_with_label("Show Battery Module");
    gtk_grid_attach(GTK_GRID(grid), win->battery_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->battery_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->battery_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->battery_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->battery_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->battery_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->battery_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->battery_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->battery_style_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Temperature/Sensors module settings tab
 */
static GtkWidget* create_temperature_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->temperature_enabled_check = gtk_check_button_new_with_label("Show Temperature/Sensors Module");
    gtk_grid_attach(GTK_GRID(grid), win->temperature_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->temperature_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->temperature_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->temperature_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->temperature_style_combo, 1, row++, 1, 1);

    /* Temperature units */
    label = gtk_label_new("Temperature Units:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->temperature_units_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_units_combo), "Celsius (°C)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->temperature_units_combo), "Fahrenheit (°F)");
    gtk_grid_attach(GTK_GRID(grid), win->temperature_units_combo, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create AI Token module tab
 */
static GtkWidget* create_aitoken_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->aitoken_enabled_check = gtk_check_button_new_with_label("Show AI Token Module");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_style_combo, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Subscription Tiers section */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Subscription Tiers</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Claude tier */
    label = gtk_label_new("Claude Plan:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_claude_tier_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_tier_combo), "Pro ($20/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_tier_combo), "Max 5x ($100/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_tier_combo), "Max 20x ($200/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_tier_combo), "API (Pay-per-token)");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_claude_tier_combo, 1, row++, 1, 1);

    /* Claude billing mode */
    label = gtk_label_new("Claude Billing:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_claude_billing_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_billing_combo), "Subscription Cap");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_claude_billing_combo), "API Pay-per-token");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_claude_billing_combo, 1, row++, 1, 1);

    /* Codex tier */
    label = gtk_label_new("Codex Plan:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_codex_tier_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_codex_tier_combo), "Plus ($20/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_codex_tier_combo), "Pro ($200/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_codex_tier_combo), "API (Pay-per-token)");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_codex_tier_combo, 1, row++, 1, 1);

    /* Codex billing mode */
    label = gtk_label_new("Codex Billing:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_codex_billing_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_codex_billing_combo), "Subscription Cap");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_codex_billing_combo), "API Pay-per-token");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_codex_billing_combo, 1, row++, 1, 1);

    /* Gemini tier */
    label = gtk_label_new("Gemini Plan:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_gemini_tier_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_tier_combo), "Free");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_tier_combo), "Pro ($20/mo)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_tier_combo), "Ultra");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_tier_combo), "API (Pay-per-token)");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_gemini_tier_combo, 1, row++, 1, 1);

    /* Gemini billing mode */
    label = gtk_label_new("Gemini Billing:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_gemini_billing_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_billing_combo), "Subscription Cap");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->aitoken_gemini_billing_combo), "API Pay-per-token");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_gemini_billing_combo, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Data display options */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Data Display Options</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Show model breakdown */
    win->aitoken_show_model_breakdown_check = gtk_check_button_new_with_label("Show Per-Model Token Breakdown");
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_show_model_breakdown_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Advanced settings */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Advanced Data Sources</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Auto-detect */
    win->aitoken_auto_detect_check = gtk_check_button_new_with_label("Auto-detect data sources (recommended)");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->aitoken_auto_detect_check), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_auto_detect_check, 0, row++, 2, 1);

    /* JSONL path */
    label = gtk_label_new("JSONL Path:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_jsonl_path_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(win->aitoken_jsonl_path_entry), "~/.claude/projects/*/sessionid.jsonl");
    gtk_widget_set_hexpand(win->aitoken_jsonl_path_entry, TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_jsonl_path_entry, 1, row++, 1, 1);

    /* Database path */
    label = gtk_label_new("Database Path:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_db_path_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(win->aitoken_db_path_entry), "~/.claude/monitoring/claude_usage.db");
    gtk_widget_set_hexpand(win->aitoken_db_path_entry, TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_db_path_entry, 1, row++, 1, 1);

    /* OTel endpoint */
    label = gtk_label_new("OTel Endpoint:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->aitoken_otel_endpoint_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(win->aitoken_otel_endpoint_entry), "http://localhost:8889/metrics");
    gtk_widget_set_hexpand(win->aitoken_otel_endpoint_entry, TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->aitoken_otel_endpoint_entry, 1, row++, 1, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create Process module settings tab
 */
static GtkWidget* create_process_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->process_enabled_check = gtk_check_button_new_with_label("Show Process Module");
    gtk_grid_attach(GTK_GRID(grid), win->process_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->process_height_spin = gtk_spin_button_new_with_range(80, 400, 10);
    gtk_grid_attach(GTK_GRID(grid), win->process_height_spin, 1, row++, 1, 1);

    /* Info label */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<i>Shows top 10 processes by CPU usage.\nRight-click a process to terminate, force kill, pause, or resume it.</i>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    return grid;
}

/**
 * Create TPU module settings tab
 */
static GtkWidget* create_tpu_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    /* Module enabled */
    win->tpu_enabled_check = gtk_check_button_new_with_label("Show TPU Module");
    gtk_grid_attach(GTK_GRID(grid), win->tpu_enabled_check, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Display settings */
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Display Settings</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Graph height */
    label = gtk_label_new("Graph Height:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->tpu_height_spin = gtk_spin_button_new_with_range(40, 300, 10);
    gtk_grid_attach(GTK_GRID(grid), win->tpu_height_spin, 1, row++, 1, 1);

    /* Visual Style */
    label = gtk_label_new("Visual Style:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->tpu_style_combo = gtk_combo_box_text_new();
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->tpu_style_combo), "Solid (Filled)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->tpu_style_combo), "Pixel (Chunky)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->tpu_style_combo), "Dot (Fine)");
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->tpu_style_combo), "Hollow (Outline)");
    gtk_grid_attach(GTK_GRID(grid), win->tpu_style_combo, 1, row++, 1, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Info about TPU */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>About TPU Monitoring</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label),
        "<i>Monitors Google Coral Edge TPU accelerators.\n"
        "Shows inference operations per second and temperature.\n"
        "Requires a Coral USB or PCIe TPU device.</i>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Note: Colors are managed in the Colors tab */

    return grid;
}

/**
 * Create global colors tab
 */
static GtkWidget* create_colors_tab(XRGPreferencesWindow *win) {
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_container_set_border_width(GTK_CONTAINER(grid), 15);

    gint row = 0;

    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Color Theme</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Theme selector */
    label = gtk_label_new("Theme Preset:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);

    win->theme_combo = gtk_combo_box_text_new();
    for (gint i = 0; i < xrg_preferences_get_theme_count(); i++) {
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(win->theme_combo),
                                        xrg_preferences_get_theme_name(i));
    }
    g_signal_connect(win->theme_combo, "changed", G_CALLBACK(on_theme_changed), win);
    gtk_grid_attach(GTK_GRID(grid), win->theme_combo, 1, row++, 1, 1);

    /* Info label */
    label = gtk_label_new("Select a theme preset or customize individual colors below.");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_widget_set_opacity(label, 0.7);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Separator */
    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, row++, 2, 1);

    /* Global Colors header */
    label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), "<b>Custom Colors</b>");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row++, 2, 1);

    /* Background color */
    label = gtk_label_new("Window Background:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->bg_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->bg_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->bg_color_button, 1, row++, 1, 1);

    /* Graph background */
    label = gtk_label_new("Graph Background:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->graph_bg_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->graph_bg_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->graph_bg_color_button, 1, row++, 1, 1);

    /* FG1 color (cyan) */
    label = gtk_label_new("Data Series 1 (Cyan):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->graph_fg1_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->graph_fg1_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->graph_fg1_color_button, 1, row++, 1, 1);

    /* FG2 color (purple) */
    label = gtk_label_new("Data Series 2 (Purple):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->graph_fg2_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->graph_fg2_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->graph_fg2_color_button, 1, row++, 1, 1);

    /* FG3 color (amber) */
    label = gtk_label_new("Data Series 3 (Amber):");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->graph_fg3_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->graph_fg3_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->graph_fg3_color_button, 1, row++, 1, 1);

    /* Text color */
    label = gtk_label_new("Text Color:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->text_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->text_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->text_color_button, 1, row++, 1, 1);

    /* Border color */
    label = gtk_label_new("Border Color:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->border_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->border_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->border_color_button, 1, row++, 1, 1);

    /* Activity bar color */
    label = gtk_label_new("Activity Bar Color:");
    gtk_widget_set_halign(label, GTK_ALIGN_END);
    gtk_grid_attach(GTK_GRID(grid), label, 0, row, 1, 1);
    win->activity_bar_color_button = gtk_color_button_new();
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(win->activity_bar_color_button), TRUE);
    gtk_grid_attach(GTK_GRID(grid), win->activity_bar_color_button, 1, row++, 1, 1);

    return grid;
}

/**
 * Load preferences into UI widgets
 */
static void load_preferences_to_ui(XRGPreferencesWindow *win) {
    XRGPreferences *prefs = win->prefs;

    /* Window tab */
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->window_x_spin), prefs->window_x);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->window_y_spin), prefs->window_y);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->window_width_spin), prefs->window_width);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->window_height_spin), prefs->window_height);
    gtk_range_set_value(GTK_RANGE(win->window_opacity_scale), prefs->window_opacity);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->window_always_on_top_check), prefs->window_always_on_top);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->show_activity_bars_check), prefs->show_activity_bars);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->activity_bar_style_combo), prefs->activity_bar_style);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->layout_orientation_combo), prefs->layout_orientation);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->graph_width_spin), prefs->graph_width);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->fast_update_interval_spin), prefs->fast_update_interval);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->normal_update_interval_spin), prefs->normal_update_interval);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->slow_update_interval_spin), prefs->slow_update_interval);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->vslow_update_interval_spin), prefs->vslow_update_interval);

    /* CPU module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->cpu_enabled_check), prefs->show_cpu);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->cpu_height_spin), prefs->graph_height_cpu);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->cpu_update_interval_spin), prefs->normal_update_interval);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->cpu_style_combo), prefs->cpu_graph_style);
    /* Note: CPU colors removed - use Colors tab instead */

    /* Memory module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->memory_enabled_check), prefs->show_memory);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->memory_height_spin), prefs->graph_height_memory);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->memory_style_combo), prefs->memory_graph_style);
    /* Note: Memory colors removed - use Colors tab instead */

    /* Network module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->network_enabled_check), prefs->show_network);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->network_height_spin), prefs->graph_height_network);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->network_style_combo), prefs->network_graph_style);
    /* Note: Network colors removed - use Colors tab instead */

    /* Disk module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->disk_enabled_check), prefs->show_disk);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->disk_height_spin), prefs->graph_height_disk);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->disk_style_combo), prefs->disk_graph_style);
    /* Note: Disk colors removed - use Colors tab instead */

    /* GPU module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->gpu_enabled_check), prefs->show_gpu);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->gpu_height_spin), prefs->graph_height_gpu);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->gpu_style_combo), prefs->gpu_graph_style);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->gpu_temperature_units_combo), prefs->temperature_units);
    /* Note: GPU colors removed - use Colors tab instead */

    /* Battery module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->battery_enabled_check), prefs->show_battery);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->battery_height_spin), prefs->graph_height_battery);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->battery_style_combo), prefs->battery_graph_style);
    /* Note: Battery colors removed - use Colors tab instead */

    /* Temperature/Sensors module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->temperature_enabled_check), prefs->show_temperature);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->temperature_height_spin), prefs->graph_height_temperature);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->temperature_style_combo), prefs->temperature_graph_style);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->temperature_units_combo), prefs->temperature_units);
    /* Note: Temperature colors removed - use Colors tab instead */

    /* AI Token module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->aitoken_enabled_check), prefs->show_aitoken);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->aitoken_height_spin), prefs->graph_height_aitoken);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_style_combo), prefs->aitoken_graph_style);
    /* Subscription tier selectors */
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_claude_tier_combo), prefs->aitoken_claude_tier);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_codex_tier_combo), prefs->aitoken_codex_tier);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_gemini_tier_combo), prefs->aitoken_gemini_tier);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_claude_billing_combo), prefs->aitoken_claude_billing_mode);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_codex_billing_combo), prefs->aitoken_codex_billing_mode);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->aitoken_gemini_billing_combo), prefs->aitoken_gemini_billing_mode);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->aitoken_show_model_breakdown_check), prefs->aitoken_show_model_breakdown);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->aitoken_auto_detect_check), prefs->aitoken_auto_detect);
    if (prefs->aitoken_jsonl_path) {
        gtk_entry_set_text(GTK_ENTRY(win->aitoken_jsonl_path_entry), prefs->aitoken_jsonl_path);
    }
    if (prefs->aitoken_db_path) {
        gtk_entry_set_text(GTK_ENTRY(win->aitoken_db_path_entry), prefs->aitoken_db_path);
    }
    if (prefs->aitoken_otel_endpoint) {
        gtk_entry_set_text(GTK_ENTRY(win->aitoken_otel_endpoint_entry), prefs->aitoken_otel_endpoint);
    }
    /* Note: AIToken colors removed - use Colors tab instead */

    /* Process module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->process_enabled_check), prefs->show_process);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->process_height_spin), prefs->graph_height_process);

    /* TPU module tab */
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(win->tpu_enabled_check), prefs->show_tpu);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->tpu_height_spin), prefs->graph_height_tpu);
    gtk_combo_box_set_active(GTK_COMBO_BOX(win->tpu_style_combo), prefs->tpu_graph_style);

    /* Colors tab */
    /* Load color buttons FIRST (before setting theme combo, to avoid triggering callback) */
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->bg_color_button), &prefs->background_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_bg_color_button), &prefs->graph_bg_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg1_color_button), &prefs->graph_fg1_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg2_color_button), &prefs->graph_fg2_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg3_color_button), &prefs->graph_fg3_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->text_color_button), &prefs->text_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->border_color_button), &prefs->border_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->activity_bar_color_button), &prefs->activity_bar_color);

    /* Set current theme in dropdown (block signal to avoid overwriting colors) */
    const gchar *current_theme = xrg_preferences_get_current_theme(prefs);
    if (current_theme != NULL) {
        /* Block the "changed" signal while we set the active item */
        g_signal_handlers_block_by_func(win->theme_combo, G_CALLBACK(on_theme_changed), win);

        for (gint i = 0; i < xrg_preferences_get_theme_count(); i++) {
            if (g_strcmp0(xrg_preferences_get_theme_name(i), current_theme) == 0) {
                gtk_combo_box_set_active(GTK_COMBO_BOX(win->theme_combo), i);
                break;
            }
        }

        /* Unblock the signal */
        g_signal_handlers_unblock_by_func(win->theme_combo, G_CALLBACK(on_theme_changed), win);
    }
}

/**
 * Save UI widget values to preferences
 */
static void save_ui_to_preferences(XRGPreferencesWindow *win) {
    XRGPreferences *prefs = win->prefs;

    /* Window tab */
    prefs->window_x = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->window_x_spin));
    prefs->window_y = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->window_y_spin));
    prefs->window_width = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->window_width_spin));
    prefs->window_height = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->window_height_spin));
    prefs->window_opacity = gtk_range_get_value(GTK_RANGE(win->window_opacity_scale));
    prefs->window_always_on_top = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->window_always_on_top_check));
    prefs->show_activity_bars = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->show_activity_bars_check));
    prefs->activity_bar_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->activity_bar_style_combo));
    prefs->layout_orientation = gtk_combo_box_get_active(GTK_COMBO_BOX(win->layout_orientation_combo));
    prefs->graph_width = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->graph_width_spin));
    prefs->fast_update_interval = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->fast_update_interval_spin));
    prefs->normal_update_interval = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->normal_update_interval_spin));
    prefs->slow_update_interval = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->slow_update_interval_spin));
    prefs->vslow_update_interval = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->vslow_update_interval_spin));

    /* CPU module tab */
    prefs->show_cpu = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->cpu_enabled_check));
    prefs->graph_height_cpu = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->cpu_height_spin));
    prefs->normal_update_interval = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->cpu_update_interval_spin));
    prefs->cpu_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->cpu_style_combo));
    /* Note: CPU colors removed - use Colors tab instead */

    /* Memory module tab */
    prefs->show_memory = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->memory_enabled_check));
    prefs->graph_height_memory = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->memory_height_spin));
    prefs->memory_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->memory_style_combo));
    /* Note: Memory colors removed - use Colors tab instead */

    /* Network module tab */
    prefs->show_network = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->network_enabled_check));
    prefs->graph_height_network = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->network_height_spin));
    prefs->network_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->network_style_combo));
    /* Note: Network colors removed - use Colors tab instead */

    /* Disk module tab */
    prefs->show_disk = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->disk_enabled_check));
    prefs->graph_height_disk = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->disk_height_spin));
    prefs->disk_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->disk_style_combo));
    /* Note: Disk colors removed - use Colors tab instead */

    /* GPU module tab */
    prefs->show_gpu = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->gpu_enabled_check));
    prefs->graph_height_gpu = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->gpu_height_spin));
    prefs->gpu_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->gpu_style_combo));
    prefs->temperature_units = gtk_combo_box_get_active(GTK_COMBO_BOX(win->gpu_temperature_units_combo));
    /* Note: GPU colors removed - use Colors tab instead */

    /* Battery module tab */
    prefs->show_battery = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->battery_enabled_check));
    prefs->graph_height_battery = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->battery_height_spin));
    prefs->battery_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->battery_style_combo));
    /* Note: Battery colors removed - use Colors tab instead */

    /* Temperature/Sensors module tab */
    prefs->show_temperature = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->temperature_enabled_check));
    prefs->graph_height_temperature = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->temperature_height_spin));
    prefs->temperature_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->temperature_style_combo));
    prefs->temperature_units = gtk_combo_box_get_active(GTK_COMBO_BOX(win->temperature_units_combo));
    /* Note: Temperature colors removed - use Colors tab instead */

    /* AI Token module tab */
    prefs->show_aitoken = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->aitoken_enabled_check));
    prefs->graph_height_aitoken = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->aitoken_height_spin));
    prefs->aitoken_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_style_combo));
    /* Subscription tier selectors */
    prefs->aitoken_claude_tier = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_claude_tier_combo));
    prefs->aitoken_codex_tier = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_codex_tier_combo));
    prefs->aitoken_gemini_tier = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_gemini_tier_combo));
    prefs->aitoken_claude_billing_mode = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_claude_billing_combo));
    prefs->aitoken_codex_billing_mode = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_codex_billing_combo));
    prefs->aitoken_gemini_billing_mode = gtk_combo_box_get_active(GTK_COMBO_BOX(win->aitoken_gemini_billing_combo));
    prefs->aitoken_show_model_breakdown = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->aitoken_show_model_breakdown_check));
    prefs->aitoken_auto_detect = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->aitoken_auto_detect_check));
    g_free(prefs->aitoken_jsonl_path);
    prefs->aitoken_jsonl_path = g_strdup(gtk_entry_get_text(GTK_ENTRY(win->aitoken_jsonl_path_entry)));
    g_free(prefs->aitoken_db_path);
    prefs->aitoken_db_path = g_strdup(gtk_entry_get_text(GTK_ENTRY(win->aitoken_db_path_entry)));
    g_free(prefs->aitoken_otel_endpoint);
    prefs->aitoken_otel_endpoint = g_strdup(gtk_entry_get_text(GTK_ENTRY(win->aitoken_otel_endpoint_entry)));
    /* Note: AIToken colors removed - use Colors tab instead */

    /* Process module tab */
    prefs->show_process = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->process_enabled_check));
    prefs->graph_height_process = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->process_height_spin));

    /* TPU module tab */
    prefs->show_tpu = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(win->tpu_enabled_check));
    prefs->graph_height_tpu = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(win->tpu_height_spin));
    prefs->tpu_graph_style = gtk_combo_box_get_active(GTK_COMBO_BOX(win->tpu_style_combo));

    /* Colors tab */
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->bg_color_button), &prefs->background_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->graph_bg_color_button), &prefs->graph_bg_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->graph_fg1_color_button), &prefs->graph_fg1_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->graph_fg2_color_button), &prefs->graph_fg2_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->graph_fg3_color_button), &prefs->graph_fg3_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->text_color_button), &prefs->text_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->border_color_button), &prefs->border_color);
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(win->activity_bar_color_button), &prefs->activity_bar_color);

    /* Save to file */
    xrg_preferences_save(prefs);
}

/**
 * Theme selection callback - applies theme and updates color buttons
 */
static void on_theme_changed(GtkComboBox *combo, gpointer user_data) {
    XRGPreferencesWindow *win = (XRGPreferencesWindow *)user_data;
    gchar *theme_name = gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(combo));

    if (theme_name == NULL) {
        return;  /* No selection */
    }

    /* Apply the theme to preferences */
    xrg_preferences_apply_theme(win->prefs, theme_name);

    /* Update all color buttons to reflect the new theme */
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->bg_color_button), &win->prefs->background_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_bg_color_button), &win->prefs->graph_bg_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg1_color_button), &win->prefs->graph_fg1_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg2_color_button), &win->prefs->graph_fg2_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->graph_fg3_color_button), &win->prefs->graph_fg3_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->text_color_button), &win->prefs->text_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->border_color_button), &win->prefs->border_color);
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(win->activity_bar_color_button), &win->prefs->activity_bar_color);

    g_free(theme_name);
}

/**
 * Dialog response callback
 */
static void on_response(GtkDialog *dialog G_GNUC_UNUSED, gint response_id, gpointer user_data) {
    XRGPreferencesWindow *win = (XRGPreferencesWindow *)user_data;

    if (response_id == GTK_RESPONSE_OK || response_id == GTK_RESPONSE_APPLY) {
        /* Save UI values to preferences struct */
        save_ui_to_preferences(win);

        /* Persist preferences to disk */
        if (!xrg_preferences_save(win->prefs)) {
            g_warning("Failed to save preferences to disk");
        }

        /* Call the applied callback if set */
        if (win->applied_callback) {
            win->applied_callback(win->callback_user_data);
        }
    }

    if (response_id == GTK_RESPONSE_OK || response_id == GTK_RESPONSE_CANCEL) {
        gtk_widget_hide(win->window);
    }
}

/**
 * Show preferences window
 */
void xrg_preferences_window_show(XRGPreferencesWindow *win) {
    g_return_if_fail(win != NULL);
    load_preferences_to_ui(win);
    gtk_widget_show_all(win->window);
}

/**
 * Show preferences window and navigate to specific tab
 */
void xrg_preferences_window_show_tab(XRGPreferencesWindow *win, XRGPrefsTab tab) {
    g_return_if_fail(win != NULL);
    load_preferences_to_ui(win);
    gtk_widget_show_all(win->window);
    gtk_notebook_set_current_page(GTK_NOTEBOOK(win->notebook), (gint)tab);
}

/**
 * Hide preferences window
 */
void xrg_preferences_window_hide(XRGPreferencesWindow *win) {
    g_return_if_fail(win != NULL);
    gtk_widget_hide(win->window);
}

/**
 * Set callback to be called when preferences are applied
 */
void xrg_preferences_window_set_applied_callback(XRGPreferencesWindow *win,
                                                   XRGPreferencesAppliedCallback callback,
                                                   gpointer user_data) {
    g_return_if_fail(win != NULL);
    win->applied_callback = callback;
    win->callback_user_data = user_data;
}

/**
 * Free preferences window
 */
void xrg_preferences_window_free(XRGPreferencesWindow *win) {
    if (win == NULL)
        return;

    if (win->window)
        gtk_widget_destroy(win->window);

    g_free(win);
}

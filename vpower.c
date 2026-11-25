/*
 * Easy Laptop power manager 0.1 — power modes for EasyOS (X11 / GTK2)
 * Extreme Flight Mode and Power Save Mode, built on an embedded bash engine.
 * Runs as root (EasyOS default). Build: make
 */
#include <gtk/gtk.h>
#include <glib/gstdio.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <glob.h>
#include <stdio.h>
#include "engine.h"   /* generated from vpower-engine.sh: engine_sh[], engine_sh_len */

enum { RADIO_NONE, RADIO_WIFI, RADIO_BT, RADIO_BOTH, RADIO_ALL };

typedef struct {
    GtkWidget *win, *rb_flight, *rb_save;
    GtkWidget *sp_cores, *sp_freq, *sp_bright, *cb_radio, *ck_powertop, *sp_font;
    GtkWidget *radio_row, *lbl_bat, *view, *buttons;
    gchar *engine_path;
    int ncpu;
    gboolean busy;
} App;

static App A;

/* ------------------------------------------------------------ fonts */
#define TEXT_SIZE_MIN 8
#define TEXT_SIZE_MAX 24
#define TEXT_SIZE_DEF 12

static void apply_text_font(int pts)
{
    if (pts < TEXT_SIZE_MIN) pts = TEXT_SIZE_MIN;
    if (pts > TEXT_SIZE_MAX) pts = TEXT_SIZE_MAX;
    char buf[32];
    g_snprintf(buf, sizeof buf, "Monospace %d", pts);
    PangoFontDescription *fd = pango_font_description_from_string(buf);
    gtk_widget_modify_font(A.view, fd);
    pango_font_description_free(fd);
}

/* set a widget's font size in points, keeping the desktop's own font family */
static void set_font_size(GtkWidget *w, int pts)
{
    GtkStyle *st = gtk_widget_get_style(w);
    PangoFontDescription *fd = pango_font_description_copy(st->font_desc);
    if (pango_font_description_get_size(fd) < (gint)(pts * PANGO_SCALE))
        pango_font_description_set_size(fd, (gint)(pts * PANGO_SCALE));
    gtk_widget_modify_font(w, fd);
    pango_font_description_free(fd);
}

static void on_font_size(GtkSpinButton *sb, gpointer unused)
{
    (void)unused;
    apply_text_font(gtk_spin_button_get_value_as_int(sb));
}

static int default_text_size(void)
{
    const char *v = g_getenv("VPOWER_TEXT_SIZE");
    if (v && *v) {
        int n = atoi(v);
        if (n >= TEXT_SIZE_MIN && n <= TEXT_SIZE_MAX) return n;
    }
    return TEXT_SIZE_DEF;
}

/* ------------------------------------------------------------ helpers */
static void log_append(const char *txt)
{
    GtkTextBuffer *b = gtk_text_view_get_buffer(GTK_TEXT_VIEW(A.view));
    GtkTextIter end;
    gtk_text_buffer_get_end_iter(b, &end);
    gtk_text_buffer_insert(b, &end, txt, -1);
    gtk_text_buffer_get_end_iter(b, &end);
    GtkTextMark *m = gtk_text_buffer_create_mark(b, NULL, &end, FALSE);
    gtk_text_view_scroll_mark_onscreen(GTK_TEXT_VIEW(A.view), m);
    gtk_text_buffer_delete_mark(b, m);
}

static void log_clear(void)
{
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(A.view)), "", -1);
}

static gboolean write_engine(void)
{
    GError *err = NULL;
    gint fd = g_file_open_tmp("vpower-engine-XXXXXX.sh", &A.engine_path, &err);
    if (fd < 0) {
        g_printerr("Cannot create temp file: %s\n", err->message);
        return FALSE;
    }
    gboolean ok = write(fd, engine_sh, engine_sh_len) == (ssize_t)engine_sh_len;
    close(fd);
    g_chmod(A.engine_path, 0700);
    return ok;
}

static gchar *read_sys(const char *path)
{
    gchar *s = NULL;
    if (g_file_get_contents(path, &s, NULL, NULL)) g_strstrip(s);
    return s;
}

static gboolean update_battery(gpointer unused)
{
    (void)unused;
    GDir *d = g_dir_open("/sys/class/power_supply", 0, NULL);
    GString *out = g_string_new("");
    if (d) {
        const gchar *n;
        while ((n = g_dir_read_name(d))) {
            gchar *p = g_strdup_printf("/sys/class/power_supply/%s/type", n);
            gchar *t = read_sys(p); g_free(p);
            if (t && !strcmp(t, "Battery")) {
                gchar *pc = g_strdup_printf("/sys/class/power_supply/%s/capacity", n);
                gchar *ps = g_strdup_printf("/sys/class/power_supply/%s/status", n);
                gchar *c = read_sys(pc), *s = read_sys(ps);
                g_string_append_printf(out, "%s%s: %s%% (%s)", out->len ? "   " : "",
                                       n, c ? c : "?", s ? s : "?");
                g_free(c); g_free(s); g_free(pc); g_free(ps);
            }
            g_free(t);
        }
        g_dir_close(d);
    }
    gchar *on = read_sys("/sys/devices/system/cpu/online");
    g_string_append_printf(out, "%sCPUs online: %s of %d",
                           out->len ? "   |   " : "No battery found   |   ",
                           on ? on : "?", A.ncpu);
    g_free(on);
    gtk_label_set_text(GTK_LABEL(A.lbl_bat), out->str);
    g_string_free(out, TRUE);
    return TRUE;
}

/* ------------------------------------------------------------ run engine */
static void set_busy(gboolean b)
{
    A.busy = b;
    gtk_widget_set_sensitive(A.buttons, !b);
}

static gboolean on_output(GIOChannel *ch, GIOCondition cond, gpointer unused)
{
    (void)unused;
    if (cond & G_IO_IN) {
        gchar *line = NULL; gsize len;
        GIOStatus st = g_io_channel_read_line(ch, &line, &len, NULL, NULL);
        if (st == G_IO_STATUS_NORMAL && line) {
            log_append(line); g_free(line);
            return TRUE;
        }
        g_free(line);
        if (st == G_IO_STATUS_AGAIN) return TRUE;
    }
    g_io_channel_unref(ch);
    return FALSE;
}

static void cpufreq_refresh(void);
static void on_child_exit(GPid pid, gint status, gpointer unused)
{
    (void)unused; (void)status;
    g_spawn_close_pid(pid);
    set_busy(FALSE);
    update_battery(NULL);
    cpufreq_refresh();
}

static void run_engine(const char *arg, gchar **env)
{
    if (A.busy) return;
    gchar *argv[] = { "/bin/bash", A.engine_path, (gchar *)arg, NULL };
    GPid pid; gint out_fd; GError *err = NULL;
    log_clear();
    if (!g_spawn_async_with_pipes(NULL, argv, env,
            G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDERR_TO_DEV_NULL,
            NULL, NULL, &pid, NULL, &out_fd, NULL, &err)) {
        log_append("Could not start: ");
        log_append(err->message);
        log_append("\n");
        g_error_free(err);
        return;
    }
    set_busy(TRUE);
    GIOChannel *ch = g_io_channel_unix_new(out_fd);
    g_io_channel_set_close_on_unref(ch, TRUE);
    g_io_channel_set_encoding(ch, NULL, NULL);
    g_io_add_watch(ch, G_IO_IN | G_IO_HUP | G_IO_ERR, on_output, NULL);
    g_child_watch_add(pid, on_child_exit, NULL);
}

static gchar **env_set(gchar **env, const char *k, const char *v)
{
    return g_environ_setenv(env, k, v, TRUE);
}

static gchar **env_seti(gchar **env, const char *k, int v)
{
    gchar buf[32];
    g_snprintf(buf, sizeof buf, "%d", v);
    return g_environ_setenv(env, k, buf, TRUE);
}

static gchar **build_env(void)
{
    gboolean flight = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(A.rb_flight));
    gchar **e = g_get_environ();
    e = env_set(e, "VPOWER_SELF", "vpower");
    e = env_set(e, "MODE_NAME", flight ? "Extreme Flight Mode" : "Power Save Mode");
    int cores = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(A.sp_cores));
    e = env_seti(e, "KEEP_CORES", cores >= A.ncpu ? 0 : cores);
    e = env_seti(e, "MAX_FREQ_PERCENT", gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(A.sp_freq)));
    e = env_seti(e, "BRIGHTNESS_PERCENT", gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(A.sp_bright)));
    e = env_set(e, "RUN_POWERTOP",
                gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(A.ck_powertop)) ? "1" : "0");

    if (flight) {
        e = env_set(e, "RFKILL_ALL", "1");
    } else {
        int r = gtk_combo_box_get_active(GTK_COMBO_BOX(A.cb_radio));
        e = env_set(e, "RFKILL_ALL", r == RADIO_ALL ? "1" : "0");
        e = env_set(e, "WIFI_MODE", (r == RADIO_WIFI || r == RADIO_BOTH) ? "off" : "powersave");
        e = env_set(e, "BLUETOOTH_OFF", (r == RADIO_BT || r == RADIO_BOTH) ? "1" : "0");
        e = env_set(e, "WWAN_OFF", "0");
    }
    return e;
}

/* ------------------------------------------------------------ callbacks */
static void on_mode(GtkToggleButton *b, gpointer unused)
{
    (void)unused;
    gboolean flight = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(A.rb_flight));
    (void)b;
    gtk_widget_set_sensitive(A.radio_row, !flight);
    if (flight) {
        gtk_combo_box_set_active(GTK_COMBO_BOX(A.cb_radio), RADIO_ALL);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_cores), A.ncpu > 2 ? 2 : 1);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_freq), 70);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_bright), 25);
    } else {
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_cores), A.ncpu);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_freq), 30);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(A.sp_bright), 70);
    }
}

static void on_apply(GtkButton *b, gpointer dry)
{
    (void)b;
    gchar **e = build_env();
    run_engine(dry ? "--dry-run" : NULL, e);
    g_strfreev(e);
}

static void on_restore(GtkButton *b, gpointer unused)
{
    (void)b; (void)unused;
    gchar **e = g_get_environ();
    e = env_set(e, "VPOWER_SELF", "vpower");
    run_engine("--restore", e);
    g_strfreev(e);
}

static void on_status(GtkButton *b, gpointer unused)
{
    (void)b; (void)unused;
    gchar **e = g_get_environ();
    e = env_set(e, "VPOWER_SELF", "vpower");
    run_engine("--status", e);
    g_strfreev(e);
}

static void on_quit(void)
{
    if (A.engine_path) { g_unlink(A.engine_path); g_free(A.engine_path); }
    gtk_main_quit();
}

/* ------------------------------------------------------------ UI */
static GtkWidget *spin_row(GtkWidget *table, int row, const char *label,
                           int min, int max, int val, const char *hint)
{
    GtkWidget *l = gtk_label_new(label);
    gtk_misc_set_alignment(GTK_MISC(l), 0, 0.5);
    GtkWidget *s = gtk_spin_button_new_with_range(min, max, 1);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(s), val);
    GtkWidget *h = gtk_label_new(hint);
    gtk_misc_set_alignment(GTK_MISC(h), 0, 0.5);
    gtk_widget_set_sensitive(h, FALSE);
    gtk_table_attach(GTK_TABLE(table), l, 0, 1, row, row + 1, GTK_FILL, 0, 4, 3);
    gtk_table_attach(GTK_TABLE(table), s, 1, 2, row, row + 1, GTK_FILL, 0, 4, 3);
    gtk_table_attach(GTK_TABLE(table), h, 2, 3, row, row + 1, GTK_FILL | GTK_EXPAND, 0, 4, 3);
    return s;
}

static GtkWidget *button(const char *label, const char *stock, GCallback cb, gpointer data)
{
    GtkWidget *b = gtk_button_new_with_mnemonic(label);
    if (stock) gtk_button_set_image(GTK_BUTTON(b),
                    gtk_image_new_from_stock(stock, GTK_ICON_SIZE_BUTTON));
    g_signal_connect(b, "clicked", cb, data);
    return b;
}

/* ------------------------------------------------------------ CPU frequency scaling (governor) */
#define CPUFREQ0 "/sys/devices/system/cpu/cpu0/cpufreq/"
static const int up_vals[] = { 95, 80, 50, 30 };
static GtkWidget *g_lbl_drv, *g_cb_gov, *g_cb_up, *g_up_row, *g_btn_gov;
static gchar **g_govs;

static void cpufreq_refresh(void)
{
    gchar *drv = read_sys(CPUFREQ0 "scaling_driver");
    gchar *gov = read_sys(CPUFREQ0 "scaling_governor");
    gchar *avail = read_sys(CPUFREQ0 "scaling_available_governors");
    gchar *txt;
    if (!drv) txt = g_strdup("Scaling driver: none (CPU frequency scaling not available)");
    else txt = g_strdup_printf("Scaling driver: %s    Current governor: %s", drv, gov ? gov : "?");
    gtk_label_set_text(GTK_LABEL(g_lbl_drv), txt);
    g_free(txt);

    /* rebuild governor list */
    GtkTreeModel *m = gtk_combo_box_get_model(GTK_COMBO_BOX(g_cb_gov));
    gtk_list_store_clear(GTK_LIST_STORE(m));
    g_strfreev(g_govs); g_govs = NULL;
    int active = -1;
    if (avail && *avail) {
        g_govs = g_strsplit_set(avail, " \t", -1);
        int i = 0;
        for (gchar **p = g_govs; *p; p++) {
            if (!**p) continue;
            gtk_combo_box_append_text(GTK_COMBO_BOX(g_cb_gov), *p);
            if (gov && !strcmp(*p, gov)) active = i;
            i++;
        }
    }
    gtk_combo_box_set_active(GTK_COMBO_BOX(g_cb_gov), active);
    gboolean can = avail && *avail;
    gtk_widget_set_sensitive(g_cb_gov, can);
    gtk_widget_set_sensitive(g_btn_gov, can);
    if (!can && drv)
        gtk_widget_set_tooltip_text(g_cb_gov, "This driver offers no governors to choose from.");

    /* current ondemand up_threshold */
    gchar *up = read_sys("/sys/devices/system/cpu/cpufreq/ondemand/up_threshold");
    if (!up) up = read_sys("/sys/devices/system/cpu/cpufreq/policy0/ondemand/up_threshold");
    int cur = up ? atoi(up) : 80, best = 1;
    for (int i = 0; i < 4; i++) if (up_vals[i] == cur) best = i;
    gtk_combo_box_set_active(GTK_COMBO_BOX(g_cb_up), best);
    g_free(up); g_free(drv); g_free(gov); g_free(avail);
}

static void on_gov_changed(GtkComboBox *c, gpointer unused)
{
    (void)unused;
    gchar *g = gtk_combo_box_get_active_text(c);
    gtk_widget_set_sensitive(g_up_row, g && !strcmp(g, "ondemand"));
    g_free(g);
}

static int write_all(const char *pattern, const char *val)
{
    int n = 0;
    glob_t gl;
    if (glob(pattern, 0, NULL, &gl) == 0) {
        for (size_t i = 0; i < gl.gl_pathc; i++)
            if (g_file_set_contents(gl.gl_pathv[i], val, -1, NULL)) n++;
            else {
                FILE *f = fopen(gl.gl_pathv[i], "w");
                if (f) { if (fputs(val, f) >= 0) n++; fclose(f); }
            }
        globfree(&gl);
    }
    return n;
}

static void on_set_governor(GtkButton *b, gpointer unused)
{
    (void)b; (void)unused;
    if (A.busy) return;
    gchar *g = gtk_combo_box_get_active_text(GTK_COMBO_BOX(g_cb_gov));
    if (!g) return;
    log_clear();
    if (geteuid() != 0) { log_append("Changing the governor needs root.\n"); g_free(g); return; }
    int n = write_all("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor", g);
    gchar *msg = g_strdup_printf("Governor set to '%s' on %d CPU(s).\n", g, n);
    log_append(msg); g_free(msg);
    if (!strcmp(g, "ondemand")) {
        int i = gtk_combo_box_get_active(GTK_COMBO_BOX(g_cb_up));
        if (i < 0) i = 1;
        gchar v[8]; g_snprintf(v, sizeof v, "%d", up_vals[i]);
        int k = write_all("/sys/devices/system/cpu/cpufreq/ondemand/up_threshold", v)
              + write_all("/sys/devices/system/cpu/cpufreq/policy*/ondemand/up_threshold", v);
        msg = k ? g_strdup_printf("Ondemand up_threshold set to %s%%.\n", v)
                : g_strdup("Could not set ondemand up_threshold.\n");
        log_append(msg); g_free(msg);
    }
    log_append("Note: Restore normal and the power modes may change the governor again.\n");
    g_free(g);
    cpufreq_refresh();
}

static GtkWidget *build_cpufreq_frame(void)
{
    GtkWidget *fr = gtk_frame_new("CPU frequency scaling");
    GtkWidget *v = gtk_vbox_new(FALSE, 4);
    gtk_container_set_border_width(GTK_CONTAINER(v), 6);
    gtk_container_add(GTK_CONTAINER(fr), v);

    g_lbl_drv = gtk_label_new("");
    gtk_misc_set_alignment(GTK_MISC(g_lbl_drv), 0, 0.5);
    gtk_box_pack_start(GTK_BOX(v), g_lbl_drv, FALSE, FALSE, 0);

    GtkWidget *h = gtk_hbox_new(FALSE, 6);
    gtk_box_pack_start(GTK_BOX(h), gtk_label_new("Governor:"), FALSE, FALSE, 0);
    g_cb_gov = gtk_combo_box_new_text();
    gtk_box_pack_start(GTK_BOX(h), g_cb_gov, FALSE, FALSE, 0);
    g_btn_gov = button("Set _governor", GTK_STOCK_EXECUTE, G_CALLBACK(on_set_governor), NULL);
    gtk_box_pack_start(GTK_BOX(h), g_btn_gov, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(v), h, FALSE, FALSE, 0);

    g_up_row = gtk_hbox_new(FALSE, 6);
    gtk_box_pack_start(GTK_BOX(g_up_row), gtk_label_new("Ondemand responsiveness:"), FALSE, FALSE, 0);
    g_cb_up = gtk_combo_box_new_text();
    gtk_combo_box_append_text(GTK_COMBO_BOX(g_cb_up), "95% - Powersave, less responsive");
    gtk_combo_box_append_text(GTK_COMBO_BOX(g_cb_up), "80% - Default");
    gtk_combo_box_append_text(GTK_COMBO_BOX(g_cb_up), "50% - Balanced, more responsive");
    gtk_combo_box_append_text(GTK_COMBO_BOX(g_cb_up), "30% - Performance, very responsive");
    gtk_widget_set_tooltip_text(g_cb_up,
        "up_threshold: the CPU load at which ondemand raises the frequency.");
    gtk_box_pack_start(GTK_BOX(g_up_row), g_cb_up, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(v), g_up_row, FALSE, FALSE, 0);

    g_signal_connect(g_cb_gov, "changed", G_CALLBACK(on_gov_changed), NULL);
    cpufreq_refresh();
    on_gov_changed(GTK_COMBO_BOX(g_cb_gov), NULL);
    return fr;
}

int main(int argc, char **argv)
{
    gtk_init(&argc, &argv);
    g_set_application_name("Easy Laptop power manager 0.1");
    A.ncpu = (int)sysconf(_SC_NPROCESSORS_CONF);
    if (A.ncpu < 1) A.ncpu = 1;

    if (!write_engine()) return 1;

    A.win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(A.win), "Easy Laptop power manager 0.1");
    gtk_window_set_wmclass(GTK_WINDOW(A.win), "Easy Laptop power manager 0.1", "Easy Laptop power manager 0.1");
    gtk_window_set_default_size(GTK_WINDOW(A.win), 680, 760);
    gtk_window_set_icon_name(GTK_WINDOW(A.win), "battery");
    gtk_container_set_border_width(GTK_CONTAINER(A.win), 10);
    g_signal_connect(A.win, "destroy", G_CALLBACK(on_quit), NULL);

    GtkWidget *vb = gtk_vbox_new(FALSE, 8);
    gtk_container_add(GTK_CONTAINER(A.win), vb);

    A.lbl_bat = gtk_label_new("");
    gtk_misc_set_alignment(GTK_MISC(A.lbl_bat), 0, 0.5);
    set_font_size(A.lbl_bat, 12);
    gtk_box_pack_start(GTK_BOX(vb), A.lbl_bat, FALSE, FALSE, 0);

    /* mode */
    GtkWidget *fm = gtk_frame_new(" Mode ");
    GtkWidget *mb = gtk_vbox_new(FALSE, 2);
    gtk_container_set_border_width(GTK_CONTAINER(mb), 6);
    gtk_container_add(GTK_CONTAINER(fm), mb);
    A.rb_flight = gtk_radio_button_new_with_mnemonic(NULL,
        "_Extreme Flight Mode — all radios off (rfkill block all), maximum saving");
    A.rb_save = gtk_radio_button_new_with_mnemonic_from_widget(GTK_RADIO_BUTTON(A.rb_flight),
        "_Power Save Mode — choose options freely");
    gtk_box_pack_start(GTK_BOX(mb), A.rb_flight, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(mb), A.rb_save, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(vb), fm, FALSE, FALSE, 0);

    /* options */
    GtkWidget *fo = gtk_frame_new(" Options ");
    GtkWidget *t = gtk_table_new(6, 3, FALSE);
    gtk_container_set_border_width(GTK_CONTAINER(t), 6);
    gtk_container_add(GTK_CONTAINER(fo), t);
    gchar *hint = g_strdup_printf("of %d (most efficient kept first)", A.ncpu);
    A.sp_cores  = spin_row(t, 0, "CPU threads kept on:", 1, A.ncpu, A.ncpu, hint);
    g_free(hint);
    A.sp_freq   = spin_row(t, 1, "CPU top speed (%):", 10, 100, 70, "100 = no cap");
    A.sp_bright = spin_row(t, 2, "Screen brightness (%):", 1, 100, 25, "");
    int tsize = default_text_size();
    A.sp_font = spin_row(t, 3, "Preview / Status text size:", TEXT_SIZE_MIN, TEXT_SIZE_MAX,
                         tsize, "points — applies right away");

    GtkWidget *rl = gtk_label_new("Wireless:");
    gtk_misc_set_alignment(GTK_MISC(rl), 0, 0.5);
    A.cb_radio = gtk_combo_box_new_text();
    gtk_combo_box_append_text(GTK_COMBO_BOX(A.cb_radio), "Keep all on (Wi-Fi power saving)");
    gtk_combo_box_append_text(GTK_COMBO_BOX(A.cb_radio), "Wi-Fi off");
    gtk_combo_box_append_text(GTK_COMBO_BOX(A.cb_radio), "Bluetooth off");
    gtk_combo_box_append_text(GTK_COMBO_BOX(A.cb_radio), "Wi-Fi and Bluetooth off");
    gtk_combo_box_append_text(GTK_COMBO_BOX(A.cb_radio), "All radios off (rfkill all)");
    gtk_combo_box_set_active(GTK_COMBO_BOX(A.cb_radio), RADIO_ALL);
    A.radio_row = gtk_hbox_new(FALSE, 0);
    gtk_box_pack_start(GTK_BOX(A.radio_row), A.cb_radio, FALSE, FALSE, 0);
    gtk_table_attach(GTK_TABLE(t), rl, 0, 1, 4, 5, GTK_FILL, 0, 4, 3);
    gtk_table_attach(GTK_TABLE(t), A.radio_row, 1, 3, 4, 5, GTK_FILL, 0, 4, 3);

    A.ck_powertop = gtk_check_button_new_with_label("Run powertop --auto-tune");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(A.ck_powertop), TRUE);
    gtk_table_attach(GTK_TABLE(t), A.ck_powertop, 0, 3, 5, 6, GTK_FILL, 0, 4, 3);
    gtk_box_pack_start(GTK_BOX(vb), fo, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(vb), build_cpufreq_frame(), FALSE, FALSE, 0);

    /* buttons */
    A.buttons = gtk_hbox_new(FALSE, 6);
    gtk_box_pack_start(GTK_BOX(A.buttons), button("_Apply", GTK_STOCK_APPLY, G_CALLBACK(on_apply), NULL), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(A.buttons), button("_Preview", GTK_STOCK_FIND, G_CALLBACK(on_apply), GINT_TO_POINTER(1)), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(A.buttons), button("_Restore normal", GTK_STOCK_UNDO, G_CALLBACK(on_restore), NULL), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(A.buttons), button("_Status", GTK_STOCK_INFO, G_CALLBACK(on_status), NULL), FALSE, FALSE, 0);
    gtk_box_pack_end(GTK_BOX(A.buttons), button("_Quit", GTK_STOCK_QUIT, G_CALLBACK(on_quit), NULL), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(vb), A.buttons, FALSE, FALSE, 0);

    /* output */
    GtkWidget *sw = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_shadow_type(GTK_SCROLLED_WINDOW(sw), GTK_SHADOW_IN);
    A.view = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(A.view), FALSE);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(A.view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(A.view), GTK_WRAP_WORD_CHAR);
    apply_text_font(tsize);
    g_signal_connect(A.sp_font, "value-changed", G_CALLBACK(on_font_size), NULL);
    gtk_container_add(GTK_CONTAINER(sw), A.view);
    gtk_box_pack_start(GTK_BOX(vb), sw, TRUE, TRUE, 0);

    g_signal_connect(A.rb_flight, "toggled", G_CALLBACK(on_mode), NULL);
    on_mode(NULL, NULL);
    update_battery(NULL);
    g_timeout_add_seconds(10, update_battery, NULL);

    if (geteuid() != 0)
        log_append("Warning: not running as root — only Preview and Status will work.\n");
    else
        log_append("Choose a mode and press Apply. Press Preview to see changes first.\n");

    gtk_widget_show_all(A.win);
    gtk_main();
    return 0;
}

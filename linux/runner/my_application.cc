#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static const gchar* lookup_string(FlValue* args, const gchar* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : nullptr;
}

static void gsettings_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    fl_method_call_respond_error(call, "invalid", "GSettings arguments required",
                                 nullptr, nullptr);
    return;
  }
  const gchar* name = lookup_string(args, "schema");
  const gchar* key = lookup_string(args, "key");
  GSettingsSchemaSource* source = g_settings_schema_source_get_default();
  if (source == nullptr || name == nullptr || key == nullptr ||
      (!g_str_equal(name, "org.gnome.system.proxy") &&
       !g_str_has_prefix(name, "org.gnome.system.proxy."))) {
    fl_method_call_respond_error(call, "invalid", "Proxy schema unavailable",
                                 nullptr, nullptr);
    return;
  }
  g_autoptr(GSettingsSchema) schema =
      g_settings_schema_source_lookup(source, name, TRUE);
  if (schema == nullptr || !g_settings_schema_has_key(schema, key) ||
      g_settings_schema_get_path(schema) == nullptr) {
    fl_method_call_respond_error(call, "invalid", "Proxy setting unavailable",
                                 nullptr, nullptr);
    return;
  }
  g_autoptr(GSettings) settings = g_settings_new_full(schema, nullptr, nullptr);
  const gchar* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "read")) {
    // User values preserve the difference between an override and its default.
    g_autoptr(GVariant) value = g_settings_get_user_value(settings, key);
    g_autofree gchar* printed = value == nullptr ? nullptr : g_variant_print(value, TRUE);
    g_autoptr(FlValue) result =
        printed == nullptr ? fl_value_new_null() : fl_value_new_string(printed);
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_str_equal(method, "writable")) {
    g_autoptr(FlValue) result = fl_value_new_bool(g_settings_is_writable(settings, key));
    fl_method_call_respond_success(call, result, nullptr);
  } else if (g_str_equal(method, "write") && g_settings_is_writable(settings, key)) {
    const gchar* raw = lookup_string(args, "value");
    if (raw == nullptr) {
      g_settings_reset(settings, key);
    } else {
      g_autoptr(GSettingsSchemaKey) schema_key = g_settings_schema_get_key(schema, key);
      g_autoptr(GVariant) value =
          g_variant_parse(g_settings_schema_key_get_value_type(schema_key),
                          raw, nullptr, nullptr, nullptr);
      if (value == nullptr || !g_settings_schema_key_range_check(schema_key, value) ||
          !g_settings_set_value(settings, key, value)) {
        fl_method_call_respond_error(call, "write", "Could not update proxy setting",
                                     nullptr, nullptr);
        return;
      }
    }
    g_settings_sync();
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_error(call, "denied", "Proxy setting is not writable",
                                 nullptr, nullptr);
  }
}

static gboolean request_close(GtkWidget*, GdkEvent*, gpointer user_data) {
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(user_data), "close",
                                  nullptr, nullptr, nullptr, nullptr);
  return TRUE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* existing =
      gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing != nullptr) {
    gtk_window_present(existing);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  gtk_window_set_title(window, "NekoProxy");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* lifecycle = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "nekoproxy/linux_lifecycle", FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(window), "nekoproxy-lifecycle", lifecycle,
                         g_object_unref);
  g_signal_connect(window, "delete-event", G_CALLBACK(request_close), lifecycle);

  FlMethodChannel* proxy = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "nekoproxy/linux_system_proxy", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(proxy, gsettings_call, nullptr,
                                             nullptr);
  g_object_set_data_full(G_OBJECT(window), "nekoproxy-linux-system-proxy",
                         proxy, g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}

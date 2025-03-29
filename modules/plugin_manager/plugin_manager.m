#include "plugin_manager.h"
#include <dlfcn.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <Foundation/Foundation.h>

#define MAX_PATH_LEN 256

void plugin_manager_init(PluginManager* manager) {
    memset(manager, 0, sizeof(PluginManager));
}

int plugin_manager_load(PluginManager* manager, const char* plugin_path) {
    if (manager->plugin_count >= MAX_PLUGINS) {
        fprintf(stderr, "Maximum number of plugins reached\n");
        return -1;
    }

    void* handle = dlopen(plugin_path, RTLD_LAZY);
    if (!handle) {
        fprintf(stderr, "Cannot open plugin %s: %s\n", plugin_path, dlerror());
        return -1;
    }

    GpumkatPlugin* plugin = dlsym(handle, "gpumkat_plugin");
    if (!plugin) {
        fprintf(stderr, "Cannot load symbol gpumkat_plugin: %s\n", dlerror());
        dlclose(handle);
        return -1;
    }

    if (plugin->initialize && plugin->initialize() != 0) {
        fprintf(stderr, "Plugin initialization failed\n");
        dlclose(handle);
        return -1;
    }

    manager->plugins[manager->plugin_count++] = plugin;
    printf("Loaded plugin: %s (version %s)\n", plugin->name, plugin->version);
    return 0;
}

int plugin_manager_execute(PluginManager* manager, const char* command) {
    for (int i = 0; i < manager->plugin_count; i++) {
        if (manager->plugins[i]->execute(command) == 0) {
            return 0; // Command was handled by a plugin
        }
    }
    return -1; // No plugin handled the command
}

void plugin_manager_cleanup(PluginManager* manager) {
    for (int i = 0; i < manager->plugin_count; i++) {
        if (manager->plugins[i]->cleanup) {
            manager->plugins[i]->cleanup();
        }
    }
    manager->plugin_count = 0;
}

int add_plugin(const char *plugin_source) {
  // Get the user's home directory
  const char *home_dir = getenv("HOME");
  if (home_dir == NULL) {
    struct passwd *pwd = getpwuid(getuid());
    if (pwd == NULL) {
      fprintf(stderr, "Unable to determine home directory\n");
      return EXIT_FAILURE;
    }
    home_dir = pwd->pw_dir;
  }

  // Define the plugin directory in the user's home
  char plugin_dir[MAX_PATH_LEN];
  snprintf(plugin_dir, sizeof(plugin_dir), "%s/.gpumkat/plugins", home_dir);
  char compile_command[1024];
  char link_command[1024];
  char plugin_name[256];
  char *dot_pos = strrchr(plugin_source, '.');

  if (dot_pos == NULL) {
    fprintf(stderr, "Invalid plugin source file name\n");
    return -1;
  }

  // Extract plugin name without extension
  strncpy(plugin_name, plugin_source, dot_pos - plugin_source);
  plugin_name[dot_pos - plugin_source] = '\0';

  // Compile the plugin as an object file
  snprintf(compile_command, sizeof(compile_command), "gcc -c -fPIC -o %s.o %s",
           plugin_name, plugin_source);

  if (system(compile_command) != 0) {
    fprintf(stderr, "Failed to compile plugin\n");
    return -1;
  }

  // Get the path of the current executable
  char executable_path[PATH_MAX];
  uint32_t size = sizeof(executable_path);
  if (_NSGetExecutablePath(executable_path, &size) != 0) {
    fprintf(stderr, "Failed to get executable path\n");
    return -1;
  }

  // Link the plugin with the main executable
  snprintf(link_command, sizeof(link_command),
           "gcc -dynamiclib -o lib%s.dylib %s.o -undefined dynamic_lookup",
           plugin_name, plugin_name);

  if (system(link_command) != 0) {
    fprintf(stderr, "Failed to create dynamic library from plugin\n");
    return -1;
  }

  // Move the dynamic library to the plugin directory
  char move_command[1024];
  snprintf(move_command, sizeof(move_command), "mv lib%s.dylib %s", plugin_name,
           plugin_dir);

  if (system(move_command) != 0) {
    fprintf(stderr, "Failed to move plugin to plugin directory\n");
    return -1;
  }

  // Clean up the object file
  remove(plugin_name);

  printf("Plugin '%s' has been successfully compiled and moved to the plugin "
         "directory.\n",
         plugin_name);
  printf("To use the plugin, you need to restart the program.\n");

  return 0;
}

int remove_plugin(const char *plugin_name) {
  // Get the user's home directory
  const char *home_dir = getenv("HOME");
  if (home_dir == NULL) {
    struct passwd *pwd = getpwuid(getuid());
    if (pwd == NULL) {
      fprintf(stderr, "Unable to determine home directory\n");
      return EXIT_FAILURE;
    }
    home_dir = pwd->pw_dir;
  }

  // Define the plugin directory in the user's home
  char plugin_dir[MAX_PATH_LEN];
  snprintf(plugin_dir, sizeof(plugin_dir), "%s/.gpumkat/plugins", home_dir);

  // Remove the plugin from the plugin directory
  char remove_command[1024];
  snprintf(remove_command, sizeof(remove_command), "rm -f %s/%s.dylib",
           plugin_dir, plugin_name);

  if (system(remove_command) != 0) {
    fprintf(stderr, "Failed to remove plugin\n");
    return -1;
  }

  printf(
      "Plugin '%s' has been successfully removed from the plugin directory.\n",
      plugin_name);

  return 0;
}

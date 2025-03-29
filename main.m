#include "modules/debug/expose_from_debug.h"
#include "modules/memory_tracker/memory_tracker.h"
#include "modules/pipeline_statistics/pipeline_statistics.h"
#include "modules/plugin_manager/plugin_manager.h"
#include "modules/update/update.h"
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#include <dirent.h>
#import <mach/mach_time.h>
#include <pthread.h>
#include <pwd.h>
#include <stdlib.h>
#include <sys/stat.h>

#define VERSION "v1.0"
#define MAX_PATH_LEN 256

// -------------------- Hot Reloading --------------------
typedef struct {
  id<MTLDevice> device;
  NSString *metallibPath;
  id<MTLLibrary> *currentLibrary;
  pthread_mutex_t library_mutex;
  volatile bool should_stop;
} HotReloadContext;

void *watch_metallib_changes(void *arg) {
  HotReloadContext *context = (HotReloadContext *)arg;
  struct stat last_stat;

  // Initial stat of the file
  if (stat([context->metallibPath fileSystemRepresentation], &last_stat) != 0) {
    NSLog(@"Error: Cannot stat initial metallib file");
    return NULL;
  }

  while (!context->should_stop) {
    // Sleep to reduce CPU usage
    sleep(1);

    struct stat current_stat;
    if (stat([context->metallibPath fileSystemRepresentation], &current_stat) !=
        0) {
      NSLog(@"Error: Cannot stat metallib file");
      continue;
    }

    // Check if file has been modified
    if (last_stat.st_mtime != current_stat.st_mtime) {
      NSLog(@"Metallib file changed. Attempting hot reload...");

      NSError *error = nil;
      id<MTLLibrary> newLibrary = [context->device
          newLibraryWithURL:[NSURL fileURLWithPath:context->metallibPath]
                      error:&error];

      if (newLibrary) {
        // Safely replace the library
        pthread_mutex_lock(&context->library_mutex);
        *context->currentLibrary = newLibrary;
        pthread_mutex_unlock(&context->library_mutex);

        NSLog(@"Shader library hot reloaded successfully!");

        // Update last modified time
        last_stat = current_stat;
      } else {
        NSLog(@"Failed to reload library: %@", error);
      }
    }
  }

  return NULL;
}

pthread_t start_hot_reload(id<MTLDevice> device, NSString *metallibPath,
                           id<MTLLibrary> *currentLibrary) {
  HotReloadContext *context = malloc(sizeof(HotReloadContext));
  context->device = device;
  context->metallibPath = metallibPath;
  context->currentLibrary = currentLibrary;
  context->should_stop = false;
  pthread_mutex_init(&context->library_mutex, NULL);

  pthread_t hot_reload_thread;
  if (pthread_create(&hot_reload_thread, NULL, watch_metallib_changes,
                     context) != 0) {
    NSLog(@"Failed to create hot reload thread");
    free(context);
    return 0;
  }

  return hot_reload_thread;
}

// -------------------- Timer Utilities --------------------
typedef struct {
  uint64_t start_time;
  uint64_t end_time;
} Timer;

static uint64_t get_time() { return mach_absolute_time(); }

static double convert_time_to_seconds(uint64_t elapsed_time) {
  mach_timebase_info_data_t timebase_info;
  mach_timebase_info(&timebase_info);
  return (double)elapsed_time * timebase_info.numer / timebase_info.denom / 1e9;
}

// -------------------- Visualization --------------------
typedef struct {
  char *name;
  double start_time;
  double end_time;
} TraceEvent;

void write_trace_event(const char *filename, TraceEvent *events, size_t count) {
  FILE *file = fopen(filename, "w");
  if (!file) {
    perror("Failed to open trace file");
    return;
  }

  fprintf(file, "[\n");
  for (size_t i = 0; i < count; ++i) {
    fprintf(file,
            "{\"name\": \"%s\", \"ph\": \"X\", \"ts\": %.6f, \"dur\": %.6f, "
            "\"pid\": 0, \"tid\": 0}%s\n",
            events[i].name, events[i].start_time,
            events[i].end_time - events[i].start_time,
            (i < count - 1) ? "," : "");
  }
  fprintf(file, "]\n");
  fclose(file);
}
// ---------------------------------------------------- Initializing
// --------------------------------------------------
void initialize_buffer(id<MTLBuffer> buffer, BufferConfig *config) {
  float *data = (float *)[buffer contents];

  // Fill with provided contents
  NSUInteger contentSize = [config->contents count];
  for (NSUInteger i = 0; i < MIN(contentSize, config->size); i++) {
    data[i] = [config->contents[i] floatValue];
  }

  // Fill remaining space with zeros if needed
  if (contentSize < config->size) {
    memset(data + contentSize, 0, (config->size - contentSize) * sizeof(float));
  }
}

id<MTLBuffer> create_buffer_with_error_checking(id<MTLDevice> device,
                                                BufferConfig *config,
                                                DebugConfig *debug) {
  id<MTLBuffer> buffer = create_tracked_buffer(
      device, config->size * sizeof(float), MTLResourceStorageModeShared);

  if (!buffer) {
    record_error(debug, ERROR_SEVERITY_ERROR, ERROR_CATEGORY_BUFFER,
                 "Failed to create Metal buffer", config->name);
    return nil;
  }

  if (config->size * sizeof(float) > [device maxBufferLength]) {
    record_error(debug, ERROR_SEVERITY_WARNING, ERROR_CATEGORY_BUFFER,
                 "Buffer size might exceed device capabilities", config->name);
  }

  return buffer;
}

// ----------------------------------------------------- Heatmap
// -------------------------------------------------

void generate_buffer_heatmap(id<MTLBuffer> buffer, const char *buffer_name,
                             bool before_execution) {
  if (!buffer || !buffer_name) {
    NSLog(@"Error: Invalid buffer or buffer name");
    return;
  }

  float *data = (float *)[buffer contents];
  size_t buffer_length = buffer.length / sizeof(float);

  if (!data || buffer_length == 0) {
    NSLog(@"Error: Buffer data is null or empty");
    return;
  }

  NSMutableString *htmlContent = [NSMutableString string];
  [htmlContent appendString:@"<!DOCTYPE html>\n<html>\n<head>\n"];
  [htmlContent appendString:@"<script "
                            @"src=\"https://cdnjs.cloudflare.com/ajax/libs/"
                            @"Chart.js/3.7.1/chart.min.js\"></script>\n"];
  [htmlContent appendString:@"<style>body { font-family: Arial; max-width: "
                            @"800px; margin: auto; }</style>\n"];
  [htmlContent appendString:@"</head>\n<body>\n"];

  // Create a unique filename based on buffer name and execution stage
  char filename[256];
  snprintf(filename, sizeof(filename), "%s_%s_heatmap.html", buffer_name,
           before_execution ? "before" : "after");

  // Prepare data for heatmap
  NSMutableArray *dataArray = [NSMutableArray array];
  for (size_t i = 0; i < buffer_length; i++) {
    if (isnan(data[i]) || isinf(data[i])) {
      NSLog(@"Warning: Buffer contains NaN or Inf at index %zu", i);
      continue;
    }
    [dataArray addObject:@[ @(i), @(data[i]) ]]; // Storing index-value pairs
  }

  if ([dataArray count] == 0) {
    NSLog(@"Error: No valid data to plot in heatmap");
    return;
  }

  [htmlContent appendFormat:@"<h2>%s Buffer Heatmap (%s Execution)</h2>\n",
                            buffer_name, before_execution ? "Before" : "After"];
  [htmlContent appendString:@"<canvas id=\"heatmapChart\"></canvas>\n"];
  [htmlContent appendString:@"<script>\n"];
  [htmlContent
      appendString:
          @"var ctx = "
          @"document.getElementById('heatmapChart').getContext('2d');\n"];
  [htmlContent appendString:@"var chart = new Chart(ctx, {\n"];
  [htmlContent appendString:@"    type: 'scatter',\n"];
  [htmlContent appendString:@"    data: {\n"];
  [htmlContent appendString:@"        datasets: [{\n"];
  [htmlContent appendString:@"            label: 'Buffer Data',\n"];
  [htmlContent
      appendString:
          @"            backgroundColor: 'rgba(75, 192, 192, 0.6)',\n"];
  [htmlContent
      appendString:@"            borderColor: 'rgba(75, 192, 192, 1)',\n"];
  [htmlContent appendString:@"            pointRadius: 3,\n"];

  // Convert data array to JSON safely
  NSError *jsonError = nil;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dataArray
                                                     options:0
                                                       error:&jsonError];

  if (jsonError) {
    NSLog(@"Error serializing JSON: %@", jsonError);
    return;
  }

  NSString *jsonString = [[NSString alloc] initWithData:jsonData
                                               encoding:NSUTF8StringEncoding];

  [htmlContent appendFormat:@"            data: %@\n", jsonString];
  [htmlContent appendString:@"        }]\n"];
  [htmlContent appendString:@"    },\n"];
  [htmlContent appendString:@"    options: {\n"];
  [htmlContent appendString:@"        plugins: {\n"];
  [htmlContent appendString:@"            title: { display: true, text: "
                            @"'Buffer Data Heatmap' },\n"];
  [htmlContent appendString:@"        },\n"];
  [htmlContent appendString:@"        scales: {\n"];
  [htmlContent
      appendString:@"            x: { type: 'linear', position: 'bottom' },\n"];
  [htmlContent appendString:@"            y: { type: 'linear' }\n"];
  [htmlContent appendString:@"        }\n"];
  [htmlContent appendString:@"    }\n"];
  [htmlContent appendString:@"});\n"];
  [htmlContent appendString:@"</script>\n"];
  [htmlContent appendString:@"</body>\n</html>"];

  // Write to file
  NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *filePath =
      [documentsPath stringByAppendingPathComponent:@(filename)];

  NSError *error;
  BOOL success = [htmlContent writeToFile:filePath
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:&error];

  if (!success) {
    NSLog(@"Error writing heatmap file: %@", error);
  } else {
    NSLog(@"Heatmap saved: %@", filePath);
  }
}

// --------------------------------------------------------------------------Main--------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    PluginManager plugin_manager;
    plugin_manager_init(&plugin_manager);

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

    // Check if the directory exists, if not, create it
    struct stat st = {0};
    if (stat(plugin_dir, &st) == -1) {
      // Create the .gpumkat directory first
      char osxiec_dir[MAX_PATH_LEN];
      snprintf(osxiec_dir, sizeof(osxiec_dir), "%s/.gpumkat", home_dir);
      if (mkdir(osxiec_dir, 0755) == -1 && errno != EEXIST) {
        fprintf(stderr, "Error creating .gpumkat directory: %s\n",
                strerror(errno));
        // Continue execution, as the program can still function without plugins
      }

      // Now create the plugins directory
      if (mkdir(plugin_dir, 0755) == -1) {
        fprintf(stderr, "Error creating plugin directory %s: %s\n", plugin_dir,
                strerror(errno));
        // Continue execution, as the program can still function without plugins
      } else {
        printf("Created plugin directory: %s\n", plugin_dir);
      }
    }

    // Load plugins from the directory
    DIR *dir = opendir(plugin_dir);
    if (dir) {
      struct dirent *entry;
      while ((entry = readdir(dir)) != NULL) {
        if (entry->d_type == DT_REG) { // Regular file
          char plugin_path[MAX_PATH_LEN];
          snprintf(plugin_path, sizeof(plugin_path), "%s/%s", plugin_dir,
                   entry->d_name);
          plugin_manager_load(&plugin_manager, plugin_path);
        }
      }
      closedir(dir);
    }
    if (argc < 2) {
      NSLog(@"Usage: gpumkat <path_to_config_file> or -help to see other "
            @"commands");
      return -1;
    } else if (strcmp(argv[1], "-update") == 0) {
      char *latest_version = fetch_latest_version();
      if (latest_version) {
        int comparison = compare_versions(VERSION, latest_version);
        if (comparison < 0) {
          printf("Update available. Latest: %s (Current: %s)\n", latest_version,
                 VERSION);

          char update_command[256];
          sprintf(update_command,
                  "curl -L -o gpumkat.tar.gz "
                  "https://github.com/Okerew/gpumkat/releases/download/%s/"
                  "gpumkat.tar.gz",
                  latest_version);

          if (system(update_command) == 0 &&
              system("tar -xvzf gpumkat.tar.gz") == 0) {
            const char *path = "gpumkat";
            if (chdir(path) != 0) {
              perror("chdir() to 'gpumkat' failed");
              return 1;
            }
            system("sudo sh install.sh");
            printf("Update successful. Please restart the profiler.\n");
            return 0;
          }
          printf(
              "Update failed. Please update manually from the repository.\n");
        } else {
          printf("Already running latest version (%s).\n", VERSION);
        }
        free(latest_version);
      } else {
        printf("Update check failed. Check internet connection.\n");
      }
      return 0;
    } else if (strcmp(argv[1], "-remove_plugin") == 0) {
      if (argc != 3) {
        fprintf(stderr, "Usage: %s -remove_plugin <plugin_name>\n", argv[0]);
        return EXIT_FAILURE;
      }
      if (geteuid() != 0) {
        fprintf(stderr, "This program must be run as root. Try using sudo.\n");
        return EXIT_FAILURE;
      }

      const char *plugin_name = argv[2];
      if (remove_plugin(plugin_name) != 0) {
        fprintf(stderr, "Failed to remove plugin: %s\n", plugin_name);
        return EXIT_FAILURE;
      }
      printf("Plugin removed successfully. Please restart the program.\n");
      return EXIT_SUCCESS; // Exit after removing plugin
    } else if (strcmp(argv[1], "-add_plugin") == 0) {
      if (argc != 3) {
        fprintf(stderr, "Usage: %s -add_plugin <plugin_source_file>\n",
                argv[0]);
        return EXIT_FAILURE;
      }
      if (geteuid() != 0) {
        fprintf(stderr, "This program must be run as root. Try using sudo.\n");
        return EXIT_FAILURE;
      }

      const char *plugin_source = argv[2];
      if (add_plugin(plugin_source) != 0) {
        fprintf(stderr, "Failed to add plugin: %s\n", plugin_source);
        return EXIT_FAILURE;
      }
      printf("Plugin added successfully. Please restart the program.\n");
      return EXIT_SUCCESS; // Exit after adding plugin
    } else if (strcmp(argv[1], "--version") == 0) {
      printf("Version: %s\n", VERSION);
      return 0;
    } else if (strcmp(argv[1], "-help") == 0) {
      printf("Usage: gpumkat <path_to_config_file>\n");
      printf("Commands:\n");
      printf("-update: Check for and download the latest version\n");
      printf("-remove_plugin <plugin_name>: Remove a plugin\n");
      printf("-add_plugin <plugin_source_file>: Add a plugin\n");
      printf("--version: Display version information\n");
      printf("-help: Display this help message\n");
      return 0;
    }

    // Initialize profiling session
    add_event_marker("ProfilerStart", "Initializing Metal profiler");

    TraceEvent events[4];
    int eventIndex = 0;

    Timer setupTimer = {get_time(), 0};

    ProfilerConfig *config = load_config(argv[1]);
    if (!config) {
      NSLog(@"Failed to load configuration");
      return -1;
    }

    // Print debug configuration if enabled
    if (config->debug.enabled) {
      NSLog(@"\n=== Debug Mode Enabled ===");
      NSLog(@"Verbosity Level: %d", config->debug.verbosity_level);
      NSLog(@"Step-by-step: %@", config->debug.step_by_step ? @"Yes" : @"No");
      NSLog(@"Variable tracking: %@",
            config->debug.print_variables ? @"Yes" : @"No");
    }

    AsyncCommandDebugExtension async_debug_ext = {0};
    if (config->debug.async_debug.config.enable_async_tracking) {
      async_debug_ext.config = config->debug.async_debug.config;
      async_debug_ext.command_count = 0;
      AsyncCommandTracker *commands =
          malloc(sizeof(AsyncCommandTracker) * MAX_ASYNC_COMMANDS);
    }

    // Initialize Low-End GPU Simulation
    LowEndGpuSimulation low_end_gpu_sim = {0};
    if (config->debug.low_end_gpu.enabled) {
      low_end_gpu_sim.enabled = true;
      low_end_gpu_sim.compute = config->debug.low_end_gpu.compute;
      low_end_gpu_sim.memory = config->debug.low_end_gpu.memory;
      low_end_gpu_sim.thermal = config->debug.low_end_gpu.thermal;
      low_end_gpu_sim.logging = config->debug.low_end_gpu.logging;
    }

    init_timeline(&config->debug);
    add_timeline_event(&config->debug, "Initialization", "SYSTEM",
                       "Starting profiler");

    NSString *metallibFilePathString =
        [NSString stringWithUTF8String:config->metallib_path];
    NSString *commandFunctionString =
        [NSString stringWithUTF8String:config->function_name];
    NSURL *metallibURL = [NSURL fileURLWithPath:metallibFilePathString];

    add_event_marker("DeviceSetup",
                     "Creating Metal device and verifying metallib");

    if (![[NSFileManager defaultManager]
            fileExistsAtPath:metallibFilePathString]) {
      NSLog(@"Metal library file does not exist: %@", metallibFilePathString);
      return -1;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL,
                   ERROR_CATEGORY_PIPELINE,
                   "Metal is not supported on this device", "DeviceSetup");
      return -1;
    }

    add_event_marker("CounterSetup", "Initializing performance counters");

    NSError *error = nil;
    add_event_marker("LibrarySetup",
                     "Loading Metal library and creating pipeline");

    id<MTLLibrary> library = [device newLibraryWithURL:metallibURL
                                                 error:&error];
    if (!library) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL, ERROR_CATEGORY_LIBRARY,
                   [[error localizedDescription] UTF8String], "LibrarySetup");
      return -1;
    }

    id<MTLFunction> function =
        [library newFunctionWithName:commandFunctionString];
    if (!function) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL, ERROR_CATEGORY_SHADER,
                   "Failed to find function in Metal library", "FunctionSetup");
      return -1;
    }
    capture_shader_state(&config->debug, function);

    id<MTLComputePipelineState> pipelineState =
        [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipelineState) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL,
                   ERROR_CATEGORY_PIPELINE,
                   [[error localizedDescription] UTF8String], "PipelineSetup");
      return -1;
    }

    pthread_t hot_reload_thread =
        start_hot_reload(device, metallibFilePathString, &library);

    setupTimer.end_time = get_time();
    events[eventIndex++] = (TraceEvent){
        .name = "Setup",
        .start_time = convert_time_to_seconds(setupTimer.start_time),
        .end_time = convert_time_to_seconds(setupTimer.end_time)};

    Timer bufferTimer = {get_time(), 0};
    add_event_marker("BufferSetup", "Creating and preparing buffers");

    NSMutableDictionary *metalBuffers = [NSMutableDictionary dictionary];

    for (NSValue *value in config->buffers) {
      BufferConfig *bufferConfig = value.pointerValue;

      // Check buffer size limits
      if (bufferConfig->size * sizeof(float) > [device maxBufferLength]) {
        record_error(&config->debug, ERROR_SEVERITY_ERROR,
                     ERROR_CATEGORY_BUFFER, "Buffer size exceeds device limits",
                     bufferConfig->name);
        continue;
      }

      id<MTLBuffer> buffer = create_buffer_with_error_checking(
          device, bufferConfig, &config->debug);
      if (!buffer) {
        continue; // Error already recorded in create_buffer_with_error_checking
      }

      track_allocation(buffer, bufferConfig->size * sizeof(float),
                       bufferConfig->name);

      // Initialize buffer with error checking
      @try {
        initialize_buffer(buffer, bufferConfig);
      } @catch (NSException *exception) {
        record_error(&config->debug, ERROR_SEVERITY_ERROR,
                     ERROR_CATEGORY_BUFFER, [[exception reason] UTF8String],
                     bufferConfig->name);
        continue;
      }

      metalBuffers[@(bufferConfig->name)] = buffer;

      if (config->debug.enabled && config->debug.print_variables) {
        print_buffer_state(buffer, bufferConfig->name,
                           bufferConfig->size * sizeof(float));
      }
    }

    bufferTimer.end_time = get_time();
    events[eventIndex++] = (TraceEvent){
        .name = "Buffer Preparation",
        .start_time = convert_time_to_seconds(bufferTimer.start_time),
        .end_time = convert_time_to_seconds(bufferTimer.end_time)};

    add_timeline_event(&config->debug, "Shader Launch", "SHADER",
                       commandFunctionString.UTF8String);

    // Command buffer creation with debug breaks
    Timer executionTimer = {get_time(), 0};
    add_event_marker("ExecutionStart", "Beginning shader execution");

    if (config->debug.enabled && config->debug.step_by_step) {
      debug_pause("About to create command buffer");
    }

    if (config->debug.enabled) {
      check_breakpoints(&config->debug, "BeforeCommandBufferCreation");
    }

    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    if (!commandQueue) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL,
                   ERROR_CATEGORY_COMMAND_QUEUE,
                   "Failed to create command queue", "CommandQueueSetup");
      return -1;
    }
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    if (!commandBuffer) {
      record_error(&config->debug, ERROR_SEVERITY_FATAL,
                   ERROR_CATEGORY_COMMAND_BUFFER,
                   "Failed to create command buffer", "CommandBufferSetup");
      return -1;
    }

    if (config->debug.enabled && config->debug.step_by_step) {
      debug_pause("Command buffer created. About to create encoder");
    }

    if (config->debug.enabled) {
      check_breakpoints(&config->debug, "BeforeEncoderCreation");
    }

    if (config->debug.async_debug.config.enable_async_tracking) {
      track_async_command(&async_debug_ext, commandBuffer, "MainCommandBuffer");
    }

    __block PipelineStats stats = {0};

    // Set up performance monitoring
    stats = collect_pipeline_statistics(commandBuffer, pipelineState);

    id<MTLComputeCommandEncoder> encoder =
        [commandBuffer computeCommandEncoder];
    if (!encoder) {
      record_error(
          &config->debug, ERROR_SEVERITY_FATAL, ERROR_CATEGORY_COMMAND_ENCODER,
          "Failed to create compute command encoder", "EncoderCreation");
      return -1;
    }

    // Dispatch kernel
    if (config->debug.enabled) {
      check_breakpoints(&config->debug, "BeforeDispatch");
    }
    [encoder setComputePipelineState:pipelineState];

    // Set buffers with debug info
    int bufferIndex = 0;
    for (NSValue *value in config->buffers) {
      BufferConfig *bufferConfig = value.pointerValue;
      [encoder setBuffer:metalBuffers[@(bufferConfig->name)]
                  offset:0
                 atIndex:bufferIndex];
      if ([value pointerValue] != (void *)[value pointerValue]) {
        record_error(&config->debug, ERROR_SEVERITY_ERROR,
                     ERROR_CATEGORY_BUFFER, "Buffer not found for index",
                     bufferConfig->name);
        continue;
      }

      if (config->debug.enabled && config->debug.verbosity_level >= 2) {
        NSLog(@"Set buffer '%s' at index %d", bufferConfig->name, bufferIndex);
      }
      capture_command_buffer_state(&config->debug, commandBuffer,
                                   bufferConfig->name);
      bufferIndex++;
    }

    // Configure and dispatch threads with debug info
    MTLSize gridSize = MTLSizeMake(1024, 1, 1);
    MTLSize threadGroupSize = MTLSizeMake(32, 1, 1);

    if (config->debug.enabled && config->debug.verbosity_level >= 1) {
      NSLog(@"\n=== Thread Configuration ===");
      NSLog(@"Grid Size: %lux%lux%lu", gridSize.width, gridSize.height,
            gridSize.depth);
      NSLog(@"Thread Group Size: %lux%lux%lu", threadGroupSize.width,
            threadGroupSize.height, threadGroupSize.depth);
    }

    [metalBuffers enumerateKeysAndObjectsUsingBlock:^(
                      NSString *key, id<MTLBuffer> buffer, BOOL *stop) {
      generate_buffer_heatmap(buffer, [key UTF8String], true);
    }];

    if (config->debug.enabled && config->debug.break_before_dispatch) {
      debug_pause("About to dispatch compute kernel");
    }

    if (low_end_gpu_sim.enabled) {
      NSLog(@"\n=== Low-End GPU Simulation Enabled ===");
      MTLSize gridSize = MTLSizeMake(1024, 1, 1);
      MTLSize threadGroupSize = MTLSizeMake(32, 1, 1);

      simulate_advanced_low_end_gpu(&low_end_gpu_sim, encoder, &gridSize,
                                    &threadGroupSize);
    } else {
      configure_thread_execution(encoder, &config->debug, &gridSize, &threadGroupSize);
    }

    configure_thread_execution(encoder, &config->debug, &gridSize, &threadGroupSize);
    [encoder endEncoding];

    if (config->debug.async_debug.config.enable_async_tracking) {
      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        if (config->debug.async_debug.config.generate_async_timeline) {
          generate_async_command_timeline(
              (AsyncCommandDebugExtension *)&async_debug_ext);
        }
      }];
    }

    if (config->debug.enabled) {
      [commandBuffer addScheduledHandler:^(id<MTLCommandBuffer> buffer) {
        NSLog(@"[DEBUG] Kernel scheduled at: %f", CACurrentMediaTime());
      }];

      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        if (buffer.error) {
          record_error(
              &config->debug, ERROR_SEVERITY_ERROR, ERROR_CATEGORY_RUNTIME,
              [[buffer.error localizedDescription] UTF8String], "Execution");
        }

        if (config->debug.enabled) {
          NSLog(@"[DEBUG] Kernel completed at: %f", CACurrentMediaTime());
        }

        // Update final statistics
        stats.gpuTime = buffer.GPUEndTime - buffer.GPUStartTime;

        NSLog(@"\n=== Performance Summary ===");

        NSLog(@"GPU Time: %.3f ms", stats.gpuTime * 1000.0);
        NSLog(@"CPU Usage: %.2f%%", stats.cpuUsage);
      }];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    executionTimer.end_time = get_time();
    events[eventIndex++] = (TraceEvent){
        .name = "Shader Execution",
        .start_time = convert_time_to_seconds(executionTimer.start_time),
        .end_time = convert_time_to_seconds(executionTimer.end_time)};

    // Results validation and performance analysis
    Timer validationTimer = {get_time(), 0};
    add_event_marker("ValidationStart", "Beginning result validation");

    // Print output data samples
    [metalBuffers enumerateKeysAndObjectsUsingBlock:^(
                      NSString *key, id<MTLBuffer> buffer, BOOL *stop) {
      float *data = (float *)[buffer contents];
      NSLog(@"\nBuffer %@ sample (first 10 elements):", key);
      for (int i = 0; i < MIN(10, buffer.length / sizeof(float)); i++) {
        NSLog(@"%@[%d] = %.2f", key, i, data[i]);
      }
    }];

    NSLog(@"\n=== Performance Summary ===");

    print_error_summary(&config->debug);

    NSLog(@"\n=== Memory Leak Check ===");
    for (int i = 0; i < allocationCount; i++) {
      NSLog(@"Potential leak: %zu bytes at %p (allocated at: %s)",
            allocations[i].size, allocations[i].address,
            allocations[i].allocation_site);
    }

    NSLog(@"\n=== Event Timeline ===");
    for (int i = 0; i < markerCount; i++) {
      double timestamp = convert_time_to_seconds(eventMarkers[i].timestamp);
      NSLog(@"[%.6f] %s: %s", timestamp, eventMarkers[i].name,
            eventMarkers[i].metadata);
    }

    validationTimer.end_time = get_time();
    events[eventIndex++] = (TraceEvent){
        .name = "Validation",
        .start_time = convert_time_to_seconds(validationTimer.start_time),
        .end_time = convert_time_to_seconds(validationTimer.end_time)};

    write_trace_event("gpumkat_trace.json", events, eventIndex);

    [metalBuffers enumerateKeysAndObjectsUsingBlock:^(
                      NSString *key, id<MTLBuffer> buffer, BOOL *stop) {
      generate_buffer_heatmap(buffer, [key UTF8String], false);
    }];

    add_event_marker("Cleanup", "Beginning resource cleanup");

    [metalBuffers enumerateKeysAndObjectsUsingBlock:^(
                      NSString *key, id<MTLBuffer> buffer, BOOL *stop) {
      untrack_allocation(buffer);
      free_tracked_buffer(buffer);
    }];

    save_timeline(&config->debug);
    cleanup_timeline(&config->debug);

    for (NSValue *value in config->buffers) {
      BufferConfig *bufferConfig = value.pointerValue;
      free((void *)bufferConfig->name);
      free((void *)bufferConfig->type);
      [bufferConfig->contents release];
      free(bufferConfig);
    }

    for (size_t i = 0; i < config->debug.breakpoint_count; i++) {
      free((void *)config->debug.breakpoints[i].condition);
      free((void *)config->debug.breakpoints[i].description);
    }
    free(config->debug.breakpoints);

    if (config->debug.async_debug.config.enable_async_tracking) {
      for (size_t i = 0; i < async_debug_ext.command_count; i++) {
        free((void *)async_debug_ext.commands[i].name);
      }
    }

    cleanup_error_collector(&config->debug.error_collector);

    if (hot_reload_thread) {
      pthread_cancel(hot_reload_thread);
      pthread_join(hot_reload_thread, NULL);
    }

    free((void *)config->metallib_path);
    free((void *)config->function_name);
    [config->buffers release];
    free(config);

    add_event_marker("ProfilerEnd", "Profiler shutdown complete");

    double totalTime = convert_time_to_seconds(validationTimer.end_time -
                                               setupTimer.start_time);
    NSLog(@"\n=== Final Timing Summary ===");
    NSLog(@"Total execution time: %.6f seconds", totalTime);

    return 0;
  }
}

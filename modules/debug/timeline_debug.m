#include "expose_from_debug.h"
#include <json-c/json.h>
#include "expose_to_debug.h"

void init_timeline(DebugConfig *debug) {
    if (!debug->timeline.enabled) return;
    
    debug->events = malloc(sizeof(TimelineEvent) * debug->timeline.max_events);
    debug->event_count = 0;
}

void add_timeline_event(DebugConfig *debug, const char *name, const char *type, const char *details) {
    if (!debug->timeline.enabled || debug->event_count >= debug->timeline.max_events) return;
    
    TimelineEvent *event = &debug->events[debug->event_count++];
    event->event_name = strdup(name);
    event->event_type = strdup(type);
    event->details = strdup(details);
    event->timestamp = get_time();
    event->depth = 0;  
}

void capture_command_buffer_state(DebugConfig *debug, id<MTLCommandBuffer> commandBuffer, const char *name) {
    if (!debug->timeline.enabled || !debug->timeline.track_buffers) return;
    
    char details[1024];
    snprintf(details, sizeof(details), 
             "Command Buffer: %s", 
             name);
    
    add_timeline_event(debug, "Command Buffer State", "COMMAND_BUFFER", details);
}
void capture_shader_state(DebugConfig *debug, id<MTLFunction> function) {
    if (!debug->timeline.enabled || !debug->timeline.track_shaders) return;
    
    NSString *functionName = [function name];
    char details[256];
    snprintf(details, sizeof(details), "Shader: %s", [functionName UTF8String]);
    
    add_timeline_event(debug, "Shader State", "SHADER", details);
}

void save_timeline(DebugConfig *debug) {
    if (!debug->timeline.enabled || debug->event_count == 0) return;
    
    json_object *root = json_object_new_object();
    json_object *events = json_object_new_array();
    
    for (size_t i = 0; i < debug->event_count; i++) {
        TimelineEvent *event = &debug->events[i];
        json_object *evt = json_object_new_object();
        
        json_object_object_add(evt, "name", json_object_new_string(event->event_name));
        json_object_object_add(evt, "type", json_object_new_string(event->event_type));
        json_object_object_add(evt, "details", json_object_new_string(event->details));
        json_object_object_add(evt, "timestamp", json_object_new_int64(event->timestamp));
        json_object_object_add(evt, "depth", json_object_new_int(event->depth));
        
        json_object_array_add(events, evt);
    }
    
    json_object_object_add(root, "events", events);
    
    FILE *f = fopen(debug->timeline.output_file, "w");
    if (f) {
        fprintf(f, "%s", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY));
        fclose(f);
    }
    
    json_object_put(root);  // Free JSON objects
}

void cleanup_timeline(DebugConfig *debug) {
    if (!debug->timeline.enabled) return;
    
    for (size_t i = 0; i < debug->event_count; i++) {
        free(debug->events[i].event_name);
        free(debug->events[i].event_type);
        free(debug->events[i].details);
    }
    
    free(debug->events);
    free(debug->timeline.output_file);
    debug->event_count = 0;
}
#ifndef SYSTEM_PROBE_H
#define SYSTEM_PROBE_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t cpu_user, cpu_system, cpu_idle, cpu_nice;
    uint64_t total_memory, used_memory, wired_memory, compressed_memory;
    uint64_t cached_memory, swap_used;
    int memory_pressure;
    int cpu_valid, memory_valid;
} RBSystemSample;

typedef struct {
    int32_t pid, parent_pid;
    uint64_t cpu_nanoseconds, physical_bytes, start_time;
    char path[4096];
} RBProcessSample;

typedef struct {
    uint32_t index;
    uint64_t received_bytes, sent_bytes;
    char name[16];
} RBNetworkSample;

typedef struct {
    int available, present, current_capacity, max_capacity;
    int on_ac, charging, charged, minutes_to_empty, minutes_to_full;
    int health_state; // 0 unknown, 1 good, 2 fair, 3 service recommended, 4 failure
    int cycle_count, design_capacity_mah, full_capacity_mah;
    int capacity_source; // 0 unavailable, 1 reported percentage, 2 capacity ratio estimate
    double maximum_capacity_percent;
} RBBatterySample;

RBSystemSample rb_system_sample(void);
RBProcessSample *rb_process_samples(size_t *count);
void rb_free_process_samples(RBProcessSample *samples);
RBNetworkSample *rb_network_samples(size_t *count, int *valid);
void rb_free_network_samples(RBNetworkSample *samples);
RBBatterySample rb_battery_sample(void);
#endif

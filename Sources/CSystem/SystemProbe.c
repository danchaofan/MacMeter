#include "SystemProbe.h"
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <libproc.h>
#include <stdlib.h>
#include <unistd.h>
#include <net/if.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if_media.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <net/route.h>
#include <string.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/IOKitLib.h>

RBSystemSample rb_system_sample(void) {
    RBSystemSample result = {0};
    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
        result.cpu_valid = 1;
        result.cpu_user = cpu.cpu_ticks[CPU_STATE_USER];
        result.cpu_system = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        result.cpu_idle = cpu.cpu_ticks[CPU_STATE_IDLE];
        result.cpu_nice = cpu.cpu_ticks[CPU_STATE_NICE];
    }
    size_t size = sizeof(result.total_memory);
    sysctlbyname("hw.memsize", &result.total_memory, &size, NULL, 0);
    vm_statistics64_data_t vm = {0};
    count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    host_page_size(host, &page_size);
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS && page_size && result.total_memory) {
        result.memory_valid = 1;
        // File-backed cache and purgeable pages are reclaimable, so exclude them.
        uint64_t used_pages = (uint64_t)vm.internal_page_count + vm.wire_count + vm.compressor_page_count;
        used_pages = used_pages > vm.purgeable_count ? used_pages - vm.purgeable_count : 0;
        result.used_memory = used_pages * page_size;
        if (result.used_memory > result.total_memory) result.used_memory = result.total_memory;
        result.wired_memory = (uint64_t)vm.wire_count * page_size;
        result.compressed_memory = (uint64_t)vm.compressor_page_count * page_size;
        result.cached_memory = ((uint64_t)vm.external_page_count + vm.purgeable_count) * page_size;
    }
    struct xsw_usage swap = {0};
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) result.swap_used = swap.xsu_used;
    size = sizeof(result.memory_pressure);
    // 1 = normal, 2 = warning, 4 = critical. Zero remains "unknown" on unsupported systems.
    sysctlbyname("kern.memorystatus_vm_pressure_level", &result.memory_pressure, &size, NULL, 0);
    mach_port_deallocate(mach_task_self(), host);
    return result;
}

RBProcessSample *rb_process_samples(size_t *count) {
    *count = 0;
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return NULL;
    capacity += capacity / 2 + 256;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    RBProcessSample *samples = calloc((size_t)capacity, sizeof(RBProcessSample));
    if (!pids || !samples) { free(pids); free(samples); return NULL; }
    int length = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (length > capacity) length = capacity;
    uid_t owner = getuid();
    for (int i = 0; i < length; ++i) {
        struct proc_bsdinfo info = {0};
        if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.pbi_uid != owner) continue;
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        RBProcessSample *s = &samples[(*count)++];
        s->pid = pids[i];
        s->parent_pid = info.pbi_ppid;
        s->cpu_nanoseconds = usage.ri_user_time + usage.ri_system_time;
        s->physical_bytes = usage.ri_phys_footprint;
        s->start_time = usage.ri_proc_start_abstime;
        proc_pidpath(pids[i], s->path, sizeof(s->path));
    }
    free(pids);
    return samples;
}

void rb_free_process_samples(RBProcessSample *samples) { free(samples); }

static int rb_interface_active(int descriptor, const char *name) {
    if (descriptor < 0) return 1;
    struct ifmediareq media = {0};
    strlcpy(media.ifm_name, name, sizeof(media.ifm_name));
    // Administrative UP / RUNNING flags can remain set on unplugged Thunderbolt ports.
    if (ioctl(descriptor, SIOCGIFMEDIA, &media) == 0 && (media.ifm_status & IFM_AVALID)) {
        return (media.ifm_status & IFM_ACTIVE) != 0;
    }
    return 1;
}

RBNetworkSample *rb_network_samples(size_t *count, int *valid) {
    *count = 0; *valid = 0;
    int mib[] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t size = 0;
    if (sysctl(mib, 6, NULL, &size, NULL, 0) != 0 || size == 0) return NULL;
    // Leave room for interfaces appearing between the size and data queries.
    size += size / 2;
    char *buffer = malloc(size);
    if (!buffer) return NULL;
    if (sysctl(mib, 6, buffer, &size, NULL, 0) != 0) { free(buffer); return NULL; }
    size_t capacity = size / sizeof(struct if_msghdr2) + 1;
    RBNetworkSample *samples = calloc(capacity, sizeof(RBNetworkSample));
    if (!samples) { free(buffer); return NULL; }
    char *end = buffer + size;
    int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    for (char *cursor = buffer; cursor + sizeof(struct if_msghdr) <= end;) {
        const struct if_msghdr *header = (const struct if_msghdr *)cursor;
        if (!header->ifm_msglen || cursor + header->ifm_msglen > end) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            const struct if_msghdr2 *info = (const struct if_msghdr2 *)cursor;
            char name[IF_NAMESIZE] = {0};
            if (if_indextoname(info->ifm_index, name) &&
                info->ifm_data.ifi_type == IFT_ETHER &&
                (info->ifm_flags & IFF_UP) && (info->ifm_flags & IFF_RUNNING) &&
                !(info->ifm_flags & (IFF_LOOPBACK | IFF_POINTOPOINT)) &&
                name[0] == 'e' && name[1] == 'n' && name[2] >= '0' && name[2] <= '9' &&
                rb_interface_active(descriptor, name)) {
                RBNetworkSample *s = &samples[(*count)++];
                s->index = info->ifm_index;
                s->received_bytes = info->ifm_data.ifi_ibytes;
                s->sent_bytes = info->ifm_data.ifi_obytes;
                strlcpy(s->name, name, sizeof(s->name));
            }
        }
        cursor += header->ifm_msglen;
    }
    *valid = 1;
    if (descriptor >= 0) close(descriptor);
    free(buffer);
    return samples;
}

void rb_free_network_samples(RBNetworkSample *samples) { free(samples); }

static int rb_number(CFDictionaryRef dictionary, CFStringRef key, int fallback) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    int number = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &number);
    return number;
}

static int rb_boolean(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
}

static int rb_registry_number(io_registry_entry_t entry, CFStringRef key, int fallback) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int number = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &number);
        CFRelease(value);
    }
    return number;
}

static int rb_battery_health(CFDictionaryRef description) {
    CFTypeRef condition = CFDictionaryGetValue(description, CFSTR(kIOPSBatteryHealthConditionKey));
    if (condition && CFEqual(condition, CFSTR(kIOPSPermanentFailureValue))) return 4;
    if (condition && CFEqual(condition, CFSTR(kIOPSCheckBatteryValue))) return 3;
    CFTypeRef health = CFDictionaryGetValue(description, CFSTR(kIOPSBatteryHealthKey));
    if (health && CFEqual(health, CFSTR(kIOPSGoodValue))) return 1;
    if (health && CFEqual(health, CFSTR(kIOPSFairValue))) return 2;
    if (health && CFEqual(health, CFSTR(kIOPSPoorValue))) return 3;
    return 0;
}

static void rb_battery_capacity(RBBatterySample *result, CFDictionaryRef description) {
    result->health_state = rb_battery_health(description);
    // Public IOPS capacity keys are consistent with each other, but not necessarily in mAh.
    int nominal = rb_number(description, CFSTR(kIOPSNominalCapacityKey), 0);
    int design = rb_number(description, CFSTR(kIOPSDesignCapacityKey), 0);
    if (nominal > 0 && design > 0) {
        result->maximum_capacity_percent = 100.0 * nominal / design;
        result->capacity_source = 2;
    }
    io_service_t battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (battery) {
        // Only read battery health properties. MaxCapacity may be a normalized 100 on Apple silicon.
        result->cycle_count = rb_registry_number(battery, CFSTR("CycleCount"), -1);
        result->design_capacity_mah = rb_registry_number(battery, CFSTR("DesignCapacity"), 0);
        result->full_capacity_mah = rb_registry_number(battery, CFSTR("NominalChargeCapacity"), 0);
        if (result->full_capacity_mah <= 100) result->full_capacity_mah = rb_registry_number(battery, CFSTR("AppleRawMaxCapacity"), 0);
        if (result->full_capacity_mah <= 100) result->full_capacity_mah = rb_registry_number(battery, CFSTR("MaxCapacity"), 0);
        if (result->full_capacity_mah <= 100) result->full_capacity_mah = 0;
        if (result->design_capacity_mah <= 100) result->design_capacity_mah = 0;
        int reported = rb_registry_number(battery, CFSTR("MaximumCapacityPercent"), -1);
        if (reported >= 0 && reported <= 100) {
            result->maximum_capacity_percent = reported;
            result->capacity_source = 1;
        } else if (result->design_capacity_mah > 0 && result->full_capacity_mah > 0) {
            result->maximum_capacity_percent = 100.0 * result->full_capacity_mah / result->design_capacity_mah;
            result->capacity_source = 2;
        }
        IOObjectRelease(battery);
    }
    if (result->maximum_capacity_percent > 100) result->maximum_capacity_percent = 100;
}

RBBatterySample rb_battery_sample(void) {
    RBBatterySample result = {0};
    result.minutes_to_empty = -1; result.minutes_to_full = -1;
    result.cycle_count = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return result;
    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (!sources) { CFRelease(info); return result; }
    result.available = 1;
    for (CFIndex index = 0; index < CFArrayGetCount(sources); ++index) {
        CFDictionaryRef description = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(sources, index));
        if (!description) continue;
        CFTypeRef type = CFDictionaryGetValue(description, CFSTR(kIOPSTypeKey));
        if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
        CFTypeRef present = CFDictionaryGetValue(description, CFSTR(kIOPSIsPresentKey));
        if (present && CFEqual(present, kCFBooleanFalse)) continue;
        result.present = 1;
        result.current_capacity = rb_number(description, CFSTR(kIOPSCurrentCapacityKey), -1);
        result.max_capacity = rb_number(description, CFSTR(kIOPSMaxCapacityKey), 0);
        CFTypeRef power = CFDictionaryGetValue(description, CFSTR(kIOPSPowerSourceStateKey));
        result.on_ac = power && CFEqual(power, CFSTR(kIOPSACPowerValue));
        result.charging = rb_boolean(description, CFSTR(kIOPSIsChargingKey));
        result.charged = rb_boolean(description, CFSTR(kIOPSIsChargedKey));
        result.minutes_to_empty = rb_number(description, CFSTR(kIOPSTimeToEmptyKey), -1);
        result.minutes_to_full = rb_number(description, CFSTR(kIOPSTimeToFullChargeKey), -1);
        rb_battery_capacity(&result, description);
        break;
    }
    CFRelease(sources); CFRelease(info);
    return result;
}

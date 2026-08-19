#include <mach/mach.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

// Mehr als das hat kein Mac; der Puffer begrenzt nur die Ausgabe.
#define MAX_CORES 128

struct cores {
  host_t host;
  processor_cpu_load_info_data_t prev_load[MAX_CORES];
  natural_t core_count;
  bool has_prev_load;

  int load[MAX_CORES];
};

static inline void cores_init(struct cores* cores) {
  // load[] wird beim ersten Durchlauf (has_prev_load == false) nicht
  // beschrieben, geht aber trotzdem an sketchybar raus -- ohne memset waere
  // das uninitialisierter Stack-Inhalt.
  memset(cores, 0, sizeof(struct cores));
  cores->host = mach_host_self();
  cores->has_prev_load = false;
}

static inline void cores_update(struct cores* cores) {
  processor_info_array_t info;
  mach_msg_type_number_t info_count;
  natural_t core_count;

  kern_return_t error = host_processor_info(cores->host,
                                            PROCESSOR_CPU_LOAD_INFO,
                                            &core_count,
                                            &info,
                                            &info_count             );

  if (error != KERN_SUCCESS) {
    printf("Error: Could not read per-core cpu load.\n");
    return;
  }

  processor_cpu_load_info_t load = (processor_cpu_load_info_t)info;
  if (core_count > MAX_CORES) core_count = MAX_CORES;

  // Nach einem Kernwechsel (theoretisch bei Hot-Plug) sind die alten Ticks
  // nicht mehr zuzuordnen -- dann eine Runde aussetzen.
  if (cores->has_prev_load && cores->core_count == core_count) {
    for (natural_t i = 0; i < core_count; ++i) {
      uint32_t delta_user = load[i].cpu_ticks[CPU_STATE_USER]
                            - cores->prev_load[i].cpu_ticks[CPU_STATE_USER];

      uint32_t delta_system = load[i].cpu_ticks[CPU_STATE_SYSTEM]
                              - cores->prev_load[i].cpu_ticks[CPU_STATE_SYSTEM];

      uint32_t delta_nice = load[i].cpu_ticks[CPU_STATE_NICE]
                            - cores->prev_load[i].cpu_ticks[CPU_STATE_NICE];

      uint32_t delta_idle = load[i].cpu_ticks[CPU_STATE_IDLE]
                            - cores->prev_load[i].cpu_ticks[CPU_STATE_IDLE];

      uint32_t delta_total = delta_user + delta_system + delta_nice + delta_idle;

      cores->load[i] = delta_total
                       ? (int)((double)(delta_user + delta_system + delta_nice)
                               / (double)delta_total * 100.0 + 0.5)
                       : 0;
    }
  }

  for (natural_t i = 0; i < core_count; ++i) cores->prev_load[i] = load[i];
  cores->core_count = core_count;
  cores->has_prev_load = true;

  // host_processor_info alloziert; ohne das laeuft der Provider voll.
  vm_deallocate(mach_task_self(),
                (vm_address_t)info,
                info_count * sizeof(natural_t));
}

#include "cores.h"
#include "../sketchybar.h"

// Die Auslastung aller Kerne geht als eine komma-separierte Liste raus statt
// als core_0=.. core_1=..: sketchybars format_message trennt an Leerzeichen,
// eine Liste ohne Leerzeichen ist damit robuster und in Lua billig zu parsen.
#define MESSAGE_SIZE (128 + MAX_CORES * 5)

int main (int argc, char** argv) {
  float update_freq;
  if (argc < 3 || (sscanf(argv[2], "%f", &update_freq) != 1)) {
    printf("Usage: %s \"<event-name>\" \"<event_freq>\"\n", argv[0]);
    exit(1);
  }

  alarm(0);
  struct cores cores;
  cores_init(&cores);

  // Setup the event in sketchybar
  char event_message[512];
  snprintf(event_message, 512, "--add event '%s'", argv[1]);
  sketchybar(event_message);

  char loads[MAX_CORES * 5];
  char trigger_message[MESSAGE_SIZE];
  for (;;) {
    cores_update(&cores);

    uint32_t caret = 0;
    for (natural_t i = 0; i < cores.core_count; ++i) {
      caret += snprintf(loads + caret,
                        sizeof(loads) - caret,
                        "%s%d",
                        i ? "," : "",
                        cores.load[i]  );
    }
    loads[caret] = '\0';

    snprintf(trigger_message,
             MESSAGE_SIZE,
             "--trigger '%s' core_count='%d' loads='%s'",
             argv[1],
             cores.core_count,
             loads                                      );

    sketchybar(trigger_message);

    usleep(update_freq * 1000000);
  }
  return 0;
}

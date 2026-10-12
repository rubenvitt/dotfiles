// Gibt die Mausposition in globalen Koordinaten aus ("x y", Ursprung oben
// links wie bei den bounding_rects aus `mbar --query`).
//
// mouse.clicked liefert nur Taste und Modifier, keine Position. Der
// Monatskalender im Uhr-Popup braucht sie, um aus einem Klick auf eine
// Wochenzeile den Tag zu bestimmen (items/calendar.lua).

#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

int main(void) {
  CGEventRef event = CGEventCreate(NULL);
  if (!event) return 1;
  CGPoint p = CGEventGetLocation(event);
  CFRelease(event);
  printf("%.1f %.1f\n", p.x, p.y);
  return 0;
}

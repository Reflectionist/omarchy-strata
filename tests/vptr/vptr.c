// vptr X Y [middle|left|right|none]: glide the pointer to logical (X, Y) on a
// 1800x1125 layout in small steps, then optionally click a button there
// (WHEEL=N then scrolls N notches).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "vp-client.h"

static struct zwlr_virtual_pointer_manager_v1 *mgr;
static struct wl_seat *seat;

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
  if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
    mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
  else if (!strcmp(iface, wl_seat_interface.name))
    seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener listener = { global, global_remove };

static uint32_t now(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: vptr X Y [middle|left|right|none]\n"); return 2; }
  int x = atoi(argv[1]), y = atoi(argv[2]);
  const char *b = argc > 3 ? argv[3] : "none";
  struct wl_display *dpy = wl_display_connect(NULL);
  if (!dpy) { fprintf(stderr, "no wayland display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry(dpy);
  wl_registry_add_listener(reg, &listener, NULL);
  wl_display_roundtrip(dpy);
  if (!mgr) { fprintf(stderr, "no virtual pointer manager\n"); return 1; }
  struct zwlr_virtual_pointer_v1 *p = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);
  const int W = 1800, H = 1125, steps = 12;
  for (int i = 0; i <= steps; i++) {
    int px = x - 48 + 48 * i / steps, py = y + 48 - 48 * i / steps;
    zwlr_virtual_pointer_v1_motion_absolute(p, now(), px, py, W, H);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_flush(dpy);
    usleep(16000);
  }
  usleep(150000);
  int code = !strcmp(b, "middle") ? 274 : !strcmp(b, "left") ? 272 : !strcmp(b, "right") ? 273 : 0;
  const char *to = getenv("DRAG_TO");
  int x2, y2;
  if (code && to && sscanf(to, "%d,%d", &x2, &y2) == 2) {
    // Press here, glide to DRAG_TO="X2,Y2" holding it (DRAG_STEPS frames),
    // wait DRAG_HOLD_US, then release (DRAG_CANCEL=1: right-click first).
    zwlr_virtual_pointer_v1_button(p, now(), code, 1); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
    usleep(80000);
    int n = getenv("DRAG_STEPS") ? atoi(getenv("DRAG_STEPS")) : 40;
    for (int i = 1; i <= n; i++) {
      zwlr_virtual_pointer_v1_motion_absolute(p, now(), x + (x2 - x) * i / n, y + (y2 - y) * i / n, W, H);
      zwlr_virtual_pointer_v1_frame(p);
      wl_display_flush(dpy);
      usleep(16000);
    }
    usleep(getenv("DRAG_HOLD_US") ? atoi(getenv("DRAG_HOLD_US")) : 200000);
    if (getenv("DRAG_CANCEL")) {
      zwlr_virtual_pointer_v1_button(p, now(), 273, 1); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
      usleep(60000);
      zwlr_virtual_pointer_v1_button(p, now(), 273, 0); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
      usleep(60000);
    }
    zwlr_virtual_pointer_v1_button(p, now(), code, 0); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
    usleep(60000);
  } else if (code) {
    for (int i = 0; i < (getenv("CLICKS") ? atoi(getenv("CLICKS")) : 1); i++) {
    zwlr_virtual_pointer_v1_button(p, now(), code, 1); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
    usleep(getenv("HOLD_US") ? atoi(getenv("HOLD_US")) : 60000);
    zwlr_virtual_pointer_v1_button(p, now(), code, 0); zwlr_virtual_pointer_v1_frame(p); wl_display_flush(dpy);
    usleep(60000);
    }
  }
  // WHEEL=N: N notches of the scroll wheel there (negative: up, positive: down).
  if (getenv("WHEEL")) {
    int n = atoi(getenv("WHEEL"));
    for (int i = 0; i < abs(n); i++) {
      zwlr_virtual_pointer_v1_axis_source(p, WL_POINTER_AXIS_SOURCE_WHEEL);
      zwlr_virtual_pointer_v1_axis_discrete(p, now(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(n < 0 ? -15 : 15), n < 0 ? -1 : 1);
      zwlr_virtual_pointer_v1_frame(p);
      wl_display_flush(dpy);
      usleep(80000);
    }
  }
  wl_display_roundtrip(dpy);
  zwlr_virtual_pointer_v1_destroy(p);
  wl_display_roundtrip(dpy);
  wl_display_disconnect(dpy);
  return 0;
}

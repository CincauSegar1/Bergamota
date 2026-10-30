
typedef void (*delay_fn)(unsigned int interval, unsigned int unit_in_ns);
typedef void (*hid_touch_fn)(int finger, int down, int x, int y);
typedef void (*hid_key_fn)(int key, int down);

#define DELAY_ADDR        0xfffffe00073742a4ULL
#define SWEET_TOUCH_ADDR  0xfffffe0007b5a28cULL
#define SWEET_KEY_ADDR    0xfffffe0007b5a1a0ULL

static void swipe_linear(hid_touch_fn touch, delay_fn delay, int x1, int y1, int x2, int y2, int steps, int step_ms) {
    touch(0, 1, x1, y1);
    delay(step_ms, 1000000);
    for (int i = 1; i < steps; i++) {
        int cur_x = x1 + ((x2 - x1) * i) / steps;
        int cur_y = y1 + ((y2 - y1) * i) / steps;
        touch(0, 1, cur_x, cur_y);
        delay(step_ms, 1000000);
    }
    touch(0, 0, x2, y2);
}

void touch_thread_marble(void) {
    delay_fn delay = (delay_fn)DELAY_ADDR;
    hid_touch_fn touch = (hid_touch_fn)SWEET_TOUCH_ADDR;
    hid_key_fn key = (hid_key_fn)SWEET_KEY_ADDR;

    // 1. Initial 10s delay for SpringBoard and backboardd initialization
    delay(10000, 1000000);

    // 2. Wake screen & dismiss any initial Hello / lock overlay
    key(3, 1);
    delay(50, 1000000);
    key(3, 0);
    delay(300, 1000000);

    // 3. Unlock Gesture: Swipe up from bottom center (540, 2300) to top (540, 400)
    swipe_linear(touch, delay, 540, 2300, 540, 400, 10, 16);
    delay(1000, 1000000);

    // 4. Confirm transition to SpringBoard Home Screen
    key(3, 1);
    delay(50, 1000000);
    key(3, 0);
    delay(4000, 1000000);

    // 5. Control Center Gesture: Swipe down from battery corner (1000, 50) to (1000, 950)
    swipe_linear(touch, delay, 1000, 50, 1000, 950, 8, 20);
    delay(4000, 1000000);

    // 6. Dismiss Control Center: Swipe up from bottom (540, 2200) to (540, 1500) back to Home Screen
    swipe_linear(touch, delay, 540, 2200, 540, 1500, 6, 20);
    delay(1000, 1000000);

    // 7. Stay in Home Screen with periodic keepalive
    while (1) {
        delay(15000, 1000000);
    }
}

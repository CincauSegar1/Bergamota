/*
 * Marble Touch Driver: Goodix GT9916R (Berlin-D) SPI Touchscreen for Poco F5 (SM7475)
 * Direct XNU Kernel Integration via SweetHIDTouch / IOHIDEventService & SweetHIDButtons.
 *
 * Bus: Cape QUPv3 SE4 SPI
 * Pins:
 *   GPIO 16: MOSI (qup0_se4 pad 0)
 *   GPIO 17: MISO (qup0_se4 pad 1)
 *   GPIO 18: CLK  (qup0_se4 pad 2)
 *   GPIO 19: CS   (qup0_se4 pad 3, Active Low)
 *   GPIO 20: RESET (Kept HIGH by ABL; NEVER touched to avoid OLED blanking/reset)
 *   GPIO 21: IRQ / INT (Falling edge / Low on contact)
 *
 * Cape TLMM GPIO Bank: 0x0f000000 (SM7475 Cape PINCTRL REG_BASE)
 *
 * NOTE: This driver is injected into the read-only __TEXT_EXEC segment (_touch_thread).
 * ALL state variables MUST reside exclusively on the execution stack. ZERO writes to
 * static/global data (.bss / .data) are allowed, as any static write causes a data abort
 * ("SWEET EARLY PANIC: Unexpected fault in kernel static region").
 *
 * INVARIANT: marble_touch_entry MUST NEVER RETURN (no ret). Thread continuation in XNU
 * has no caller return frame; returning causes kernel instruction fetch abort.
 */

#include <stdint.h>
#include <stdbool.h>

typedef void *(*ml_io_map_fn)(uint64_t phys_addr, uint64_t size);
typedef void (*delay_fn)(uint32_t interval, uint32_t unit_in_ns);
typedef void (*sweet_hid_touch_fn)(int finger, int down, int x, int y);
typedef void (*sweet_hid_key_fn)(int key, int down);
typedef int (*printf_fn)(const char *fmt, ...);

#define ML_IO_MAP_ADDR        0xfffffe00075236ccULL
#define DELAY_ADDR            0xfffffe00073742a4ULL
#define SWEET_HID_TOUCH_ADDR  0xfffffe0007b5a28cULL
#define SWEET_HID_KEY_ADDR    0xfffffe0007b5a1a0ULL
#define PRINTF_ADDR           0xfffffe00073a31d0ULL

#define TLMM_PHYS             0x0f000000ULL
#define TLMM_SIZE             0x20000ULL

#define PIN_MOSI_DEFAULT      16
#define PIN_MISO_DEFAULT      17
#define PIN_CLK               18
#define PIN_CS                19
#define PIN_INT               21

#define GOODIX_STATUS_TOUCH   0x80

struct marble_touch_ctx {
    volatile uint32_t *tlmm;
    int pin_miso;
    int pin_mosi;
};

static inline void wr(volatile uint32_t *tlmm, uint32_t reg, uint32_t val) {
    tlmm[reg >> 2] = val;
    __asm__ volatile("dmb oshst" ::: "memory");
}

static inline uint32_t rd(volatile uint32_t *tlmm, uint32_t reg) {
    uint32_t v = tlmm[reg >> 2];
    __asm__ volatile("dmb oshld" ::: "memory");
    return v;
}

#define GPIO_CFG(n) ((n) * 0x1000)
#define GPIO_IO(n)  ((n) * 0x1000 + 4)

static void gpio_cfg(volatile uint32_t *tlmm, int pin, int func, int pull, int drive, bool out) {
    wr(tlmm, GPIO_CFG(pin), (pull & 3) | ((func & 0xf) << 2) | (((drive / 2) - 1) << 6) | (out ? (1 << 9) : 0));
}

static void gpio_set(volatile uint32_t *tlmm, int pin, bool val) {
    wr(tlmm, GPIO_IO(pin), val ? 2 : 0);
}

static bool gpio_get(volatile uint32_t *tlmm, int pin) {
    return (rd(tlmm, GPIO_IO(pin)) & 1) != 0;
}

static void spi_delay(void) {
    for (volatile int i = 0; i < 300; i++) {
        __asm__ volatile("nop");
    }
}

static void spi_transfer_byte(struct marble_touch_ctx *ctx, uint8_t out, uint8_t *in) {
    uint8_t rx = 0;
    for (int b = 7; b >= 0; b--) {
        gpio_set(ctx->tlmm, ctx->pin_mosi, (out >> b) & 1);
        spi_delay();
        gpio_set(ctx->tlmm, PIN_CLK, 1);
        spi_delay();
        rx = (rx << 1) | (gpio_get(ctx->tlmm, ctx->pin_miso) ? 1 : 0);
        gpio_set(ctx->tlmm, PIN_CLK, 0);
        spi_delay();
    }
    if (in) *in = rx;
}

static bool goodix_read(struct marble_touch_ctx *ctx, uint32_t address, uint8_t *data, uint32_t length) {
    uint8_t tx[8];
    tx[0] = 0xf1;
    tx[1] = (uint8_t)(address >> 24);
    tx[2] = (uint8_t)(address >> 16);
    tx[3] = (uint8_t)(address >> 8);
    tx[4] = (uint8_t)address;
    tx[5] = 0xff; tx[6] = 0xff; tx[7] = 0xff;

    gpio_set(ctx->tlmm, PIN_CS, 0);
    spi_delay();
    for (int i = 0; i < 8; i++) {
        spi_transfer_byte(ctx, tx[i], 0);
    }
    for (uint32_t i = 0; i < length; i++) {
        spi_transfer_byte(ctx, 0xff, &data[i]);
    }
    spi_delay();
    gpio_set(ctx->tlmm, PIN_CS, 1);
    spi_delay();
    return true;
}

static bool goodix_write(struct marble_touch_ctx *ctx, uint32_t address, const uint8_t *data, uint32_t length) {
    uint8_t tx[5];
    tx[0] = 0xf0;
    tx[1] = (uint8_t)(address >> 24);
    tx[2] = (uint8_t)(address >> 16);
    tx[3] = (uint8_t)(address >> 8);
    tx[4] = (uint8_t)address;

    gpio_set(ctx->tlmm, PIN_CS, 0);
    spi_delay();
    for (int i = 0; i < 5; i++) {
        spi_transfer_byte(ctx, tx[i], 0);
    }
    for (uint32_t i = 0; i < length; i++) {
        spi_transfer_byte(ctx, data[i], 0);
    }
    spi_delay();
    gpio_set(ctx->tlmm, PIN_CS, 1);
    spi_delay();
    return true;
}

static inline uint16_t le16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

struct contact_state {
    bool down;
    uint32_t x;
    uint32_t y;
};

__attribute__((section(".text.marble_touch_entry")))
void marble_touch_entry(void) {
    ml_io_map_fn ml_io_map = (ml_io_map_fn)ML_IO_MAP_ADDR;
    delay_fn delay = (delay_fn)DELAY_ADDR;
    sweet_hid_touch_fn hid_touch = (sweet_hid_touch_fn)SWEET_HID_TOUCH_ADDR;
    sweet_hid_key_fn hid_key = (sweet_hid_key_fn)SWEET_HID_KEY_ADDR;
    printf_fn kprint = (printf_fn)PRINTF_ADDR;

    struct marble_touch_ctx ctx;
    ctx.pin_mosi = PIN_MOSI_DEFAULT; // 16
    ctx.pin_miso = PIN_MISO_DEFAULT; // 17

    // 15-second stabilization delay: wait for launchd, tzinit, and display server
    // to complete early boot initialization before touching TLMM or polling SPI.
    kprint("SWEET TOUCH: waiting 15s for early boot stabilization...\n");
    for (int s = 0; s < 15; s++) {
        delay(1000, 1000000);
    }

    kprint("SWEET TOUCH: initializing Marble Goodix GT9916R on Cape SPI (TLMM 0x%08llx)...\n", TLMM_PHYS);

    ctx.tlmm = (volatile uint32_t *)ml_io_map(TLMM_PHYS, TLMM_SIZE);
    if (!ctx.tlmm) {
        kprint("SWEET TOUCH: failed to map Cape TLMM at 0x%08llx!\n", TLMM_PHYS);
        while (1) {
            delay(1000, 1000000);
        }
    }

    // Configure GPIO pins for Cape SPI SE4 + Goodix TS.
    // Invariant: NEVER configure or set GPIO 20 (PIN_RESET). ABL keeps it HIGH.
    // Setting OE on GPIO 20 pulses active-low RESET, discharging the OLED panel
    // charge pump (producing a white flash -> black screen -> PMIC watchdog trip).
    gpio_cfg(ctx.tlmm, ctx.pin_mosi, 0, 0, 6, true);  // pin 16: MOSI out
    gpio_cfg(ctx.tlmm, ctx.pin_miso, 0, 3, 6, false); // pin 17: MISO in, pull-up
    gpio_cfg(ctx.tlmm, PIN_CLK, 0, 0, 6, true);        // pin 18: CLK out
    gpio_cfg(ctx.tlmm, PIN_CS, 0, 3, 16, true);        // pin 19: CS out, pull-up
    gpio_cfg(ctx.tlmm, PIN_INT, 0, 3, 8, false);       // pin 21: IRQ in, pull-up

    gpio_set(ctx.tlmm, PIN_CS, 1);
    gpio_set(ctx.tlmm, PIN_CLK, 0);
    gpio_set(ctx.tlmm, ctx.pin_mosi, 0);

    delay(50, 1000000); // 50ms pin stabilization

    // Read Version (0x10014, 28 bytes)
    uint8_t version[28];
    bool probed = false;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (attempt == 0) {
            ctx.pin_mosi = 16;
            ctx.pin_miso = 17;
            gpio_cfg(ctx.tlmm, 16, 0, 0, 6, true);
            gpio_cfg(ctx.tlmm, 17, 0, 3, 6, false);
        } else {
            ctx.pin_mosi = 17;
            ctx.pin_miso = 16;
            gpio_cfg(ctx.tlmm, 17, 0, 0, 6, true);
            gpio_cfg(ctx.tlmm, 16, 0, 3, 6, false);
        }
        if (goodix_read(&ctx, 0x10014, version, 28) && version[0] != 0 && version[0] != 0xff) {
            kprint("SWEET TOUCH: Goodix GT9916R found! IC=%.6s FW=%.8s (mosi=%d miso=%d)\n",
                   (const char *)version, (const char *)version + 10, ctx.pin_mosi, ctx.pin_miso);
            probed = true;
            break;
        }
    }

    if (!probed) {
        kprint("SWEET TOUCH: Goodix GT9916R probe fallback to default pinout (mosi=16 miso=17)\n");
        ctx.pin_mosi = 16;
        ctx.pin_miso = 17;
        gpio_cfg(ctx.tlmm, 16, 0, 0, 6, true);
        gpio_cfg(ctx.tlmm, 17, 0, 3, 6, false);
    }

    uint32_t touch_address = 0x10200;
    uint8_t info_hdr[2];
    if (goodix_read(&ctx, 0x10070, info_hdr, 2)) {
        uint16_t info_len = le16(info_hdr);
        if (info_len > 40 && info_len < 512) {
            uint8_t info[256];
            if (goodix_read(&ctx, 0x10070, info, sizeof(info))) {
                uint32_t offset = 2 + 16 + 10 + 4;
                for (int i = 0; i < 5 && offset < sizeof(info); i++) {
                    offset += 1 + 2 * info[offset];
                }
                if (offset + 48 < sizeof(info)) {
                    uint32_t parsed_addr = le32(info + offset + 44);
                    if (parsed_addr >= 0x10000 && parsed_addr <= 0x80000) {
                        touch_address = parsed_addr;
                    }
                }
            }
        }
    }
    if (touch_address == 0 || touch_address < 0x10000 || touch_address > 0x80000) {
        touch_address = 0x10200;
    }
    kprint("SWEET TOUCH: report address 0x%05x\n", touch_address);

    struct contact_state prev_contacts[10];
    for (int i = 0; i < 10; i++) {
        prev_contacts[i].down = false;
        prev_contacts[i].x = 0;
        prev_contacts[i].y = 0;
    }

    uint8_t report[8 + 8 * 10];
    uint8_t zero = 0;
    uint32_t report_count = 0;
    uint32_t idle_ticks = 0;

    kprint("SWEET TOUCH: Marble Goodix native hardware polling active (125 Hz). Touch ON!\n");

    while (1) {
        delay(8, 1000000); // 8ms sleep = 125 Hz
        idle_ticks++;

        // Touch Screen Polling
        bool irq_active = !gpio_get(ctx.tlmm, PIN_INT);
        if (!irq_active && (idle_ticks < 10)) {
            // No touch interrupt and not at 80ms watchdog tick
            continue;
        }
        idle_ticks = 0;

        if (!goodix_read(&ctx, touch_address, report, 8)) {
            continue;
        }

        uint8_t status = report[0];
        if (status == 0 || status == 0xff || !(status & GOODIX_STATUS_TOUCH)) {
            if (status & GOODIX_STATUS_TOUCH) {
                goodix_write(&ctx, touch_address, &zero, 1);
            }
            // Lift all contacts if no touch reported
            for (int i = 0; i < 10; i++) {
                if (prev_contacts[i].down) {
                    prev_contacts[i].down = false;
                    hid_touch(i, 0, prev_contacts[i].x, prev_contacts[i].y);
                }
            }
            continue;
        }

        uint8_t count = report[2] & 0x0f;
        if (count > 10) count = 10;

        if (count > 0) {
            goodix_read(&ctx, touch_address + 8, report + 8, count * 8);
        }

        goodix_write(&ctx, touch_address, &zero, 1);

        // Power button gesture: 3 or more fingers tap triggers power toggle (sleep/wake)
        if (count >= 3) {
            hid_key(0, 1);
            delay(40, 1000000);
            hid_key(0, 0);
            kprint("SWEET TOUCH: 3-finger power toggle dispatched!\n");
        }

        bool active[10];
        for (int i = 0; i < 10; i++) active[i] = false;

        for (uint8_t i = 0; i < count; i++) {
            const uint8_t *pt = report + 8 + i * 8;
            uint8_t id = pt[0] >> 4;
            if (id >= 10) continue;

            uint32_t raw_x = le16(pt + 2);
            uint32_t raw_y = le16(pt + 4);

            if (raw_x > 1080) raw_x = 1080;
            if (raw_y > 2400) raw_y = 2400;

            // Scale 1080x2400 physical coordinates to 1125x2436 logical canvas
            uint32_t mapped_x = (raw_x * 1125) / 1080;
            uint32_t mapped_y = (raw_y * 2436) / 2400;
            if (mapped_x > 1125) mapped_x = 1125;
            if (mapped_y > 2436) mapped_y = 2436;

            // Virtual button gestures:
            // Top-right corner tap (x > 950 && y < 100): Power toggle (sleep/wake)
            // Top-left corner tap (x < 120 && y < 100): Volume Up
            // Bottom-left corner tap (x < 120 && y > 2300): Volume Down
            if (count == 1 && !prev_contacts[id].down) {
                if (raw_x > 950 && raw_y < 100) {
                    hid_key(0, 1);
                    delay(40, 1000000);
                    hid_key(0, 0);
                    kprint("SWEET TOUCH: top-right corner power toggle dispatched!\n");
                } else if (raw_x < 120 && raw_y < 100) {
                    hid_key(1, 1);
                    delay(40, 1000000);
                    hid_key(1, 0);
                    kprint("SWEET TOUCH: top-left corner vol+ dispatched!\n");
                } else if (raw_x < 120 && raw_y > 2300) {
                    hid_key(2, 1);
                    delay(40, 1000000);
                    hid_key(2, 0);
                    kprint("SWEET TOUCH: bottom-left corner vol- dispatched!\n");
                }
            }

            active[id] = true;
            prev_contacts[id].x = mapped_x;
            prev_contacts[id].y = mapped_y;
            prev_contacts[id].down = true;

            hid_touch((int)id, 1, (int)mapped_x, (int)mapped_y);

            if (report_count < 10) {
                kprint("SWEET TOUCH: contact %u down at %u,%u (raw %u,%u)\n",
                       id, mapped_x, mapped_y, raw_x, raw_y);
            }
        }

        for (int i = 0; i < 10; i++) {
            if (prev_contacts[i].down && !active[i]) {
                prev_contacts[i].down = false;
                hid_touch(i, 0, prev_contacts[i].x, prev_contacts[i].y);
                if (report_count < 10) {
                    kprint("SWEET TOUCH: contact %u up\n", i);
                }
            }
        }
        report_count++;
    }

    // Safety fallback: NEVER return to avoid uninitialized lr instruction abort
    while (1) {
        delay(1000, 1000000);
    }
}

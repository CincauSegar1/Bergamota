/*
 * Marble Touch Driver: Goodix GT9916R (Berlin-D) SPI Touchscreen for Poco F5 (SM7475)
 * Direct XNU Kernel Integration via SweetHIDTouch / IOHIDEventService.
 *
 * Bus: QUPv3 Wrapper 0 SE4 SPI
 * Pins:
 *   GPIO 16: MISO
 *   GPIO 17: MOSI
 *   GPIO 18: CLK
 *   GPIO 19: CS (Active Low)
 *   GPIO 20: RESET (Active Low)
 *   GPIO 21: IRQ / INT (Falling edge / Low on contact)
 *
 * Base TLMM: 0x0f000000 (SM7475 Cape/Waipio PINCTRL)
 */

#include <stdint.h>
#include <stdbool.h>

typedef void *(*ml_io_map_fn)(uint64_t phys_addr, uint64_t size);
typedef void (*delay_fn)(uint32_t interval, uint32_t unit_in_ns);
typedef void (*sweet_hid_touch_fn)(int finger, int down, int x, int y);
typedef int (*printf_fn)(const char *fmt, ...);

#define ML_IO_MAP_ADDR        0xfffffe00075236ccULL
#define DELAY_ADDR            0xfffffe00073742a4ULL
#define SWEET_HID_TOUCH_ADDR  0xfffffe0007b5a28cULL
#define PRINTF_ADDR           0xfffffe00073a31d0ULL

#define TLMM_PHYS       0x0f000000ULL
#define TLMM_SIZE       0x20000ULL

#define PIN_MISO        16
#define PIN_MOSI        17
#define PIN_CLK         18
#define PIN_CS          19
#define PIN_RESET       20
#define PIN_INT         21

#define GOODIX_STATUS_TOUCH 0x80

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
    for (volatile int i = 0; i < 25; i++) {}
}

static void spi_transfer_byte(volatile uint32_t *tlmm, uint8_t out, uint8_t *in) {
    uint8_t rx = 0;
    for (int b = 7; b >= 0; b--) {
        gpio_set(tlmm, PIN_MOSI, (out >> b) & 1);
        spi_delay();
        gpio_set(tlmm, PIN_CLK, 1);
        spi_delay();
        rx = (rx << 1) | gpio_get(tlmm, PIN_MISO);
        gpio_set(tlmm, PIN_CLK, 0);
        spi_delay();
    }
    if (in) *in = rx;
}

static bool goodix_read(volatile uint32_t *tlmm, uint32_t address, uint8_t *data, uint32_t length) {
    uint8_t tx[8];
    tx[0] = 0xf1;
    tx[1] = (uint8_t)(address >> 24);
    tx[2] = (uint8_t)(address >> 16);
    tx[3] = (uint8_t)(address >> 8);
    tx[4] = (uint8_t)address;
    tx[5] = 0xff; tx[6] = 0xff; tx[7] = 0xff;

    gpio_set(tlmm, PIN_CS, 0);
    spi_delay();
    for (int i = 0; i < 8; i++) {
        spi_transfer_byte(tlmm, tx[i], 0);
    }
    for (uint32_t i = 0; i < length; i++) {
        spi_transfer_byte(tlmm, 0xff, &data[i]);
    }
    spi_delay();
    gpio_set(tlmm, PIN_CS, 1);
    spi_delay();
    return true;
}

static bool goodix_write(volatile uint32_t *tlmm, uint32_t address, const uint8_t *data, uint32_t length) {
    uint8_t tx[5];
    tx[0] = 0xf0;
    tx[1] = (uint8_t)(address >> 24);
    tx[2] = (uint8_t)(address >> 16);
    tx[3] = (uint8_t)(address >> 8);
    tx[4] = (uint8_t)address;

    gpio_set(tlmm, PIN_CS, 0);
    spi_delay();
    for (int i = 0; i < 5; i++) {
        spi_transfer_byte(tlmm, tx[i], 0);
    }
    for (uint32_t i = 0; i < length; i++) {
        spi_transfer_byte(tlmm, data[i], 0);
    }
    spi_delay();
    gpio_set(tlmm, PIN_CS, 1);
    spi_delay();
    return true;
}

static inline uint16_t le16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

struct contact_state {
    bool down;
    uint32_t x;
    uint32_t y;
};

void marble_touch_entry(void) {
    ml_io_map_fn ml_io_map = (ml_io_map_fn)ML_IO_MAP_ADDR;
    delay_fn delay = (delay_fn)DELAY_ADDR;
    sweet_hid_touch_fn hid_touch = (sweet_hid_touch_fn)SWEET_HID_TOUCH_ADDR;
    printf_fn kprint = (printf_fn)PRINTF_ADDR;

    // Initial stabilization delay (2 seconds)
    delay(2000, 1000000);

    kprint("SWEET TOUCH: initializing Marble Goodix GT9916R on SPI...\n");

    volatile uint32_t *tlmm = (volatile uint32_t *)ml_io_map(TLMM_PHYS, TLMM_SIZE);
    if (!tlmm) {
        kprint("SWEET TOUCH: failed to map TLMM at 0x%08llx!\n", TLMM_PHYS);
        return;
    }

    // Configure GPIO pins
    gpio_cfg(tlmm, PIN_MISO, 0, 0, 6, false); // in, no pull
    gpio_cfg(tlmm, PIN_MOSI, 0, 0, 6, true);  // out
    gpio_cfg(tlmm, PIN_CLK, 0, 0, 6, true);   // out
    gpio_cfg(tlmm, PIN_CS, 0, 3, 16, true);   // out, pull up
    gpio_cfg(tlmm, PIN_RESET, 0, 3, 8, true); // out, pull up
    gpio_cfg(tlmm, PIN_INT, 0, 3, 8, false);  // in, pull up

    gpio_set(tlmm, PIN_CS, 1);
    gpio_set(tlmm, PIN_CLK, 0);
    gpio_set(tlmm, PIN_MOSI, 0);

    // Pulse reset: low 10ms, high 50ms
    gpio_set(tlmm, PIN_RESET, 0);
    delay(10, 1000000);
    gpio_set(tlmm, PIN_RESET, 1);
    delay(50, 1000000);

    // Read Version (0x10014, 28 bytes)
    uint8_t version[28];
    if (goodix_read(tlmm, 0x10014, version, 28)) {
        kprint("SWEET TOUCH: Goodix GT9916R IC=%.6s FW=%.8s\n", (const char *)version, (const char *)version + 10);
    }

    uint32_t touch_address = 0x10200;
    uint8_t info_hdr[2];
    if (goodix_read(tlmm, 0x10070, info_hdr, 2)) {
        uint16_t info_len = le16(info_hdr);
        if (info_len > 40 && info_len < 512) {
            uint8_t info[256];
            if (goodix_read(tlmm, 0x10070, info, sizeof(info))) {
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

    kprint("SWEET TOUCH: Marble Goodix polling active (125 Hz). Touch ON!\n");

    while (1) {
        delay(8, 1000000); // 8ms sleep = 125 Hz

        if (gpio_get(tlmm, PIN_INT)) {
            // No touch active: lift up any down fingers
            for (int i = 0; i < 10; i++) {
                if (prev_contacts[i].down) {
                    prev_contacts[i].down = false;
                    hid_touch(i, 0, prev_contacts[i].x, prev_contacts[i].y);
                }
            }
            continue;
        }

        if (!goodix_read(tlmm, touch_address, report, 8)) {
            continue;
        }

        uint8_t status = report[0];
        if (!(status & GOODIX_STATUS_TOUCH)) {
            goodix_write(tlmm, touch_address, &zero, 1);
            continue;
        }

        uint8_t count = report[2] & 0x0f;
        if (count > 10) count = 10;

        if (count > 0) {
            goodix_read(tlmm, touch_address + 8, report + 8, count * 8);
        }

        goodix_write(tlmm, touch_address, &zero, 1);

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

            active[id] = true;
            prev_contacts[id].x = raw_x;
            prev_contacts[id].y = raw_y;
            prev_contacts[id].down = true;

            hid_touch((int)id, 1, (int)raw_x, (int)raw_y);

            if (report_count < 10) {
                kprint("SWEET TOUCH: contact %u down at %u,%u\n", id, raw_x, raw_y);
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
}

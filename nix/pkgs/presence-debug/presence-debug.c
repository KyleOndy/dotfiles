/*
 * presence-debug — SEN0557 (LD2410) sensor dump tool for cogsworth
 *
 * Reads UART frames from /dev/ttyAMA3 (57600 8N1) and samples GPIO17 on
 * /dev/gpiochip0 for each frame, then prints a tab-aligned row per frame.
 *
 * Frame format (header already consumed):
 *   [0-3]   misc / length fields
 *   [4]     state: 0=none 1=motion 2=static 3=motion+static
 *   [5-6]   motion target distance, cm, little-endian uint16
 *   [7]     reserved
 *   [8-9]   static target distance, cm, little-endian uint16
 *   [10-14] reserved
 *   [15-18] footer: f8 f7 f6 f5
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* ── GPIO v2 UAPI (mirrors linux/gpio.h) ─────────────────────────────── */

#define GPIO_V2_GET_LINE_IOCTL        0xC250B407UL
#define GPIO_V2_LINE_GET_VALUES_IOCTL 0xC010B40EUL

#define GPIO_V2_LINE_FLAG_INPUT        (UINT64_C(1) << 2)
#define GPIO_V2_LINE_FLAG_BIAS_PULL_UP (UINT64_C(1) << 8)

struct gpio_v2_line_attribute {
    uint32_t id;
    uint32_t padding;
    uint64_t data;          /* union: flags / values / debounce_us */
};

struct gpio_v2_line_config_attribute {
    struct gpio_v2_line_attribute attr;
    uint64_t mask;
};

struct gpio_v2_line_config {
    uint64_t flags;
    uint32_t num_attrs;
    uint32_t padding[5];
    struct gpio_v2_line_config_attribute attrs[10];
};

struct gpio_v2_line_request {
    uint32_t offsets[64];
    char     consumer[32];
    struct gpio_v2_line_config config;
    uint32_t num_lines;
    uint32_t event_buffer_size;
    uint32_t padding[5];
    int32_t  fd;
};

struct gpio_v2_line_values {
    uint64_t bits;
    uint64_t mask;
};

_Static_assert(sizeof(struct gpio_v2_line_config)  == 272, "gpio_v2_line_config size");
_Static_assert(sizeof(struct gpio_v2_line_request) == 592, "gpio_v2_line_request size");
_Static_assert(sizeof(struct gpio_v2_line_values)  == 16,  "gpio_v2_line_values size");

/* ── SEN0557 frame constants ────────────────────────────────────────── */

static const uint8_t HEADER[4] = {0xf4, 0xf3, 0xf2, 0xf1};
static const uint8_t FOOTER[4] = {0xf8, 0xf7, 0xf6, 0xf5};
#define FRAME_LEN 19   /* bytes read after the 4-byte header */

/* ── Wiring ─────────────────────────────────────────────────────────── */

#define GPIO_CHIP  "/dev/gpiochip0"
#define GPIO_LINE  17
#define UART_DEV   "/dev/ttyAMA3"
#define UART_BAUD  B57600

/* ── GPIO ──────────────────────────────────────────────────────────── */

static int gpio_open(void)
{
    int chip = open(GPIO_CHIP, O_RDONLY | O_CLOEXEC);
    if (chip < 0) {
        perror("open " GPIO_CHIP);
        return -1;
    }

    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof(req));
    req.offsets[0]   = GPIO_LINE;
    req.num_lines    = 1;
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT | GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    strncpy(req.consumer, "presence-debug", sizeof(req.consumer) - 1);

    int ret = ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req);
    close(chip);

    if (ret < 0) {
        perror("GPIO_V2_GET_LINE_IOCTL");
        return -1;
    }
    return req.fd;
}

/* Returns 1=present, 0=absent, -1=error. */
static int gpio_read(int line_fd)
{
    struct gpio_v2_line_values v;
    v.bits = 0;
    v.mask = 1;
    if (ioctl(line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0)
        return -1;
    return (v.bits & 1) ? 1 : 0;
}

/* ── UART ──────────────────────────────────────────────────────────── */

static int uart_open(void)
{
    int fd = open(UART_DEV, O_RDONLY | O_NOCTTY);
    if (fd < 0) {
        perror("open " UART_DEV);
        return -1;
    }

    struct termios t;
    if (tcgetattr(fd, &t) < 0) {
        perror("tcgetattr");
        close(fd);
        return -1;
    }

    cfmakeraw(&t);
    cfsetispeed(&t, UART_BAUD);
    cfsetospeed(&t, UART_BAUD);
    t.c_cflag &= (unsigned)~CSIZE;
    t.c_cflag |= CS8 | CREAD | CLOCAL;
    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 20;  /* 2 s — gives the read loop a chance to notice SIGINT */

    if (tcsetattr(fd, TCSANOW, &t) < 0) {
        perror("tcsetattr");
        close(fd);
        return -1;
    }
    return fd;
}

/* Returns 1=got byte, 0=timeout, -1=error. */
static int read_byte(int fd, uint8_t *b)
{
    ssize_t n = read(fd, b, 1);
    if (n < 0)  return -1;
    if (n == 0) return 0;
    return 1;
}

/* ── Formatting ─────────────────────────────────────────────────────── */

static const char *state_str(uint8_t s)
{
    switch (s) {
    case 0: return "none";
    case 1: return "motion";
    case 2: return "static";
    case 3: return "motion+static";
    default: return "unknown";
    }
}

static void timestamp(char *buf, size_t len)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm *tm = localtime(&ts.tv_sec);
    strftime(buf, len, "%Y-%m-%dT%H:%M:%S", tm);
    snprintf(buf + 19, len - 19, ".%03ld", ts.tv_nsec / 1000000L);
}

/* ── Main ──────────────────────────────────────────────────────────── */

int main(void)
{
    int gpio_fd = gpio_open();
    if (gpio_fd < 0)
        fprintf(stderr, "warning: GPIO unavailable — gpio column will show -\n");

    int uart_fd = uart_open();
    if (uart_fd < 0) {
        if (gpio_fd >= 0) close(gpio_fd);
        return 1;
    }

    fprintf(stderr, "uart: %s @ 57600  gpio: %s line %d\n",
            UART_DEV, GPIO_CHIP, GPIO_LINE);

    printf("%-26s  %-8s  %-13s  %9s  %9s\n",
           "time", "gpio", "state", "motion_cm", "static_cm");
    fflush(stdout);

    uint8_t b;
    for (;;) {
        /* scan for header: f4 f3 f2 f1 */
        int r = read_byte(uart_fd, &b);
        if (r < 0) { perror("read"); break; }
        if (r == 0 || b != HEADER[0]) continue;

        if (read_byte(uart_fd, &b) != 1 || b != HEADER[1]) continue;
        if (read_byte(uart_fd, &b) != 1 || b != HEADER[2]) continue;
        if (read_byte(uart_fd, &b) != 1 || b != HEADER[3]) continue;

        /* read 19-byte payload */
        uint8_t frame[FRAME_LEN];
        int n = 0;
        while (n < FRAME_LEN) {
            ssize_t nr = read(uart_fd, frame + n, (size_t)(FRAME_LEN - n));
            if (nr <= 0) goto resync;
            n += (int)nr;
        }

        /* verify footer at bytes 15-18 */
        if (frame[15] != FOOTER[0] || frame[16] != FOOTER[1] ||
            frame[17] != FOOTER[2] || frame[18] != FOOTER[3])
            continue;

        uint8_t  state     = frame[4];
        uint16_t motion_cm = (uint16_t)(frame[5] | ((uint16_t)frame[6] << 8));
        uint16_t static_cm = (uint16_t)(frame[8] | ((uint16_t)frame[9] << 8));

        char tbuf[32];
        timestamp(tbuf, sizeof(tbuf));

        int pres = (gpio_fd >= 0) ? gpio_read(gpio_fd) : -1;
        const char *gpio_col = (pres < 0) ? "-" : (pres ? "present" : "absent");

        printf("%-26s  %-8s  %-13s  %9u  %9u\n",
               tbuf, gpio_col, state_str(state), motion_cm, static_cm);
        fflush(stdout);
        continue;
resync:;
    }

    close(uart_fd);
    if (gpio_fd >= 0) close(gpio_fd);
    return 0;
}

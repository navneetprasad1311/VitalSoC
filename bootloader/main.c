// Minimal resident bootloader for PicoRV32.
//
// Protocol (matches host/upload.py):
//   1. Host sends a 4-byte little-endian length N.
//   2. Host sends N raw bytes -- the compiled application image.
//   3. Bootloader writes those N bytes starting at APP_BASE, then jumps
//      there.
//
// There is no timeout and no "run last app automatically" fallback: App
// RAM is volatile, so after every reset there is nothing to fall back to
// -- the bootloader always waits for a fresh upload, every time.

#define UART_DATA   (*(volatile unsigned int *)0x20000000)
#define UART_STATUS (*(volatile unsigned int *)0x20000004)
#define LED_REG     (*(volatile unsigned int *)0x30000000)
#define APP_BASE    ((volatile unsigned char *)0x10000000)

#define TX_BUSY  0x1
#define RX_VALID 0x2

typedef void (*app_entry_t)(void);

static unsigned char uart_getc(void)
{
    while (!(UART_STATUS & RX_VALID))
        ;
    return (unsigned char)UART_DATA;
}

static void uart_putc(unsigned char c)
{
    while (UART_STATUS & TX_BUSY)
        ;
    UART_DATA = c;
}

int main(void)
{
    LED_REG = 0x0001;   // LED pattern: waiting for an upload

    unsigned int len = 0;
    len |= (unsigned int)uart_getc();
    len |= (unsigned int)uart_getc() << 8;
    len |= (unsigned int)uart_getc() << 16;
    len |= (unsigned int)uart_getc() << 24;

    LED_REG = 0x0003;   // LED pattern: receiving

    volatile unsigned char *dst = APP_BASE;
    for (unsigned int i = 0; i < len; i++)
        dst[i] = uart_getc();

    LED_REG = 0xFFFF;   // LED pattern: about to jump

    uart_putc('K');     // simple ack byte the host script waits for

    ((app_entry_t)APP_BASE)();

    while (1)
        ;   // should never get here
}

#ifndef FIR_H
#define FIR_H

#include <stdint.h>
#include <stdbool.h>

/* VitalSoC Register Specification Rev 0.1
 * FIR accelerator base: 0x5000_0000
 * Peripheral registers are full 32-bit word aligned.
 */
#ifndef FIR_BASE
#define FIR_BASE            0x50000000u
#endif

#define FIR_REG(off)        (*(volatile uint32_t *)((FIR_BASE) + (off)))

/* Register offsets per Spec §7.2 */
#define FIR_CTRL_OFF        0x00u
#define FIR_STATUS_OFF      0x04u
#define FIR_DATA_IN_OFF     0x08u
#define FIR_DATA_OUT_OFF    0x0Cu
#define FIR_COEF_ADDR_OFF   0x10u
#define FIR_COEF_DATA_OFF   0x14u

#define FIR_CTRL            FIR_REG(FIR_CTRL_OFF)
#define FIR_STATUS          FIR_REG(FIR_STATUS_OFF)
#define FIR_DATA_IN         FIR_REG(FIR_DATA_IN_OFF)
#define FIR_DATA_OUT        (*(volatile int32_t *)((FIR_BASE) + (FIR_DATA_OUT_OFF)))
#define FIR_COEF_ADDR       FIR_REG(FIR_COEF_ADDR_OFF)
#define FIR_COEF_DATA       FIR_REG(FIR_COEF_DATA_OFF)

/* Legacy shorthand names */
#define FIR_DIN             FIR_DATA_IN
#define FIR_DOUT            FIR_DATA_OUT
#define FIR_CADDR           FIR_COEF_ADDR
#define FIR_CDATA           FIR_COEF_DATA

/* Bitfield definitions */
#define FIR_CTRL_START      (1u << 0)
#define FIR_CTRL_IRQ_EN     (1u << 1)
#define FIR_CTRL_CH_SHIFT   8u

#define FIR_STATUS_BUSY     (1u << 0)
#define FIR_STATUS_DONE     (1u << 1)

#define FIR_NCH             4
#define FIR_TAPS            64

/**
 * fir_load_coeffs - Write 64 Q1.15 coefficients into channel bank ch (0..3)
 * Address encoding: (ch << 6) | tap
 */
static inline void fir_load_coeffs(int ch, const int16_t *c) {
    for (int k = 0; k < FIR_TAPS; k++) {
        FIR_COEF_ADDR = ((uint32_t)ch << 6) | (uint32_t)k;
        FIR_COEF_DATA = (uint16_t)c[k];
    }
}

/**
 * fir_init - Spec §7.9 & §7.10 Init procedure:
 * 1. Load all 4 coefficient banks (if provided).
 * 2. Flush every channel by feeding 64 zero samples to clear stale history.
 * Returns true on success, false if timeout occurred.
 */
static inline bool fir_init(const int16_t coeffs[FIR_NCH][FIR_TAPS]) {
    if (coeffs != 0) {
        for (int ch = 0; ch < FIR_NCH; ch++) {
            fir_load_coeffs(ch, coeffs[ch]);
        }
    }
    /* Flush pipeline/delay lines with 64 zero samples per channel */
    for (int ch = 0; ch < FIR_NCH; ch++) {
        for (int i = 0; i < FIR_TAPS; i++) {
            FIR_DATA_IN = 0;
            FIR_CTRL = ((uint32_t)ch << FIR_CTRL_CH_SHIFT) | FIR_CTRL_START;
            uint32_t timeout = 10000;
            while (!(FIR_STATUS & FIR_STATUS_DONE)) {
                if (--timeout == 0) {
                    return false; /* Timeout error */
                }
            }
            FIR_STATUS = FIR_STATUS_DONE; /* Clear DONE */
        }
    }
    return true;
}

/**
 * fir_step_poll - Process one sample with timeout (polling)
 * Returns true on success, false on timeout.
 * Note: If timeout_cycles == 0, defaults to safe default (100000 cycles) to prevent infinite loops.
 */
static inline bool fir_step_poll(int ch, int16_t x, int16_t *y, uint32_t timeout_cycles) {
    if (timeout_cycles == 0) timeout_cycles = 100000;
    FIR_DATA_IN = (uint16_t)x;
    FIR_CTRL = ((uint32_t)ch << FIR_CTRL_CH_SHIFT) | FIR_CTRL_START;
    while (!(FIR_STATUS & FIR_STATUS_DONE)) {
        if (--timeout_cycles == 0) {
            return false;
        }
    }
    if (y) *y = (int16_t)FIR_DATA_OUT;
    FIR_STATUS = FIR_STATUS_DONE; /* Clear DONE */
    return true;
}

/**
 * fir_step - Convenience polling step matching legacy signature
 */
static inline int16_t fir_step(int ch, int16_t x) {
    int16_t out = 0;
    if (!fir_step_poll(ch, x, &out, 100000)) {
        return 0;
    }
    return out;
}

/**
 * fir_start_irq - Spec §7.10 Interrupt-driven trigger:
 * Sets sample, enables irq[4] and fires START.
 */
static inline void fir_start_irq(int ch, int16_t x) {
    FIR_DATA_IN = (uint16_t)x;
    FIR_CTRL = ((uint32_t)ch << FIR_CTRL_CH_SHIFT) | FIR_CTRL_IRQ_EN | FIR_CTRL_START;
}

/**
 * fir_result - Read result and clear DONE in ISR
 */
static inline int16_t fir_result(void) {
    int16_t out = (int16_t)FIR_DATA_OUT;
    FIR_STATUS = FIR_STATUS_DONE; /* Write 1 to clear DONE (RW1C) */
    return out;
}

#endif /* FIR_H */

// gemv_accel.h — MMIO interface for GEMV hardware accelerator
//
// ACCEL base: ACCEL_START_W << 2 = 0x0810_0000 << 2 = 0x2040_0000
// Register map (word-aligned byte offsets):
//   0x00  MAT_ADDR   (W)  DMEM byte address of matrix base
//   0x04  VEC_ADDR   (W)  DMEM byte address of input vector base
//   0x08  OUT_ADDR   (W)  DMEM byte address of output base
//   0x0C  ROWS       (W)  number of matrix rows (M)
//   0x10  COLS       (W)  number of matrix cols / vector length (K)
//   0x14  CTRL       (W)  bit[0] = start (write 1 to launch)
//   0x18  STATUS     (R)  bit[0] = done, bit[1] = busy

#ifndef GEMV_ACCEL_H_
#define GEMV_ACCEL_H_

#include <stdint.h>

#define ACCEL_BASE      0x20400000UL

#define ACCEL_MAT_ADDR  (*(volatile uint32_t *)(ACCEL_BASE + 0x00))
#define ACCEL_VEC_ADDR  (*(volatile uint32_t *)(ACCEL_BASE + 0x04))
#define ACCEL_OUT_ADDR  (*(volatile uint32_t *)(ACCEL_BASE + 0x08))
#define ACCEL_ROWS      (*(volatile uint32_t *)(ACCEL_BASE + 0x0C))
#define ACCEL_COLS      (*(volatile uint32_t *)(ACCEL_BASE + 0x10))
#define ACCEL_CTRL      (*(volatile uint32_t *)(ACCEL_BASE + 0x14))
#define ACCEL_STATUS    (*(volatile uint32_t *)(ACCEL_BASE + 0x18))

// Launch a GEMV operation and block until completion.
//   out[rows] = mat[rows][cols] * vec[cols]   (int32 Q12)
static inline void gemv_hw(const int32_t *mat,
                            const int32_t *vec,
                            int32_t       *out,
                            int            rows,
                            int            cols)
{
  ACCEL_MAT_ADDR = (uint32_t)(uintptr_t)mat;
  ACCEL_VEC_ADDR = (uint32_t)(uintptr_t)vec;
  ACCEL_OUT_ADDR = (uint32_t)(uintptr_t)out;
  ACCEL_ROWS     = (uint32_t)rows;
  ACCEL_COLS     = (uint32_t)cols;
  ACCEL_CTRL     = 1u;                 // start
  while (!(ACCEL_STATUS & 1u)) {       // poll done
    // CPU naturally stalls here; no DMEM access needed
  }
}

#endif  // GEMV_ACCEL_H_

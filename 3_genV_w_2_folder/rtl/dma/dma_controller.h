#ifndef DMA_CONTROLLER_H_
#define DMA_CONTROLLER_H_

#include <stdint.h>

#define DMA_BASE        0x20900000UL

#define DMA_SRC_ADDR    (*(volatile uint32_t *)(DMA_BASE + 0x00))
#define DMA_DST_ADDR    (*(volatile uint32_t *)(DMA_BASE + 0x04))
#define DMA_LEN         (*(volatile uint32_t *)(DMA_BASE + 0x08))
#define DMA_CTRL        (*(volatile uint32_t *)(DMA_BASE + 0x0C))
#define DMA_STATUS      (*(volatile uint32_t *)(DMA_BASE + 0x10))

#define SPM_BASE        0x20800000UL

static inline void dma_to_spm(uint32_t dmem_src,
                               uint32_t spm_offset,
                               uint32_t n_words)
{
    DMA_SRC_ADDR = dmem_src;
    DMA_DST_ADDR = SPM_BASE + spm_offset;
    DMA_LEN      = n_words;
    DMA_CTRL     = 1u;
    while (!(DMA_STATUS & 1u)) { /* poll done */ }
}

static inline void dma_from_spm(uint32_t spm_offset,
                                 uint32_t dmem_dst,
                                 uint32_t n_words)
{
    DMA_SRC_ADDR = SPM_BASE + spm_offset;
    DMA_DST_ADDR = dmem_dst;
    DMA_LEN      = n_words;
    DMA_CTRL     = 1u;
    while (!(DMA_STATUS & 1u)) { /* poll done */ }
}

#endif

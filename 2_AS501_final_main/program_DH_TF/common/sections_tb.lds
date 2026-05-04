/*//////////////////////////////////////////////////////////////////////////////
// AS501/AS603
// Linker Descriptor for Baseline Hardware
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2026 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
//////////////////////////////////////////////////////////////////////////////*/

/* Linker for running in Testbench.
 * KEY CHANGE: .rodata → DATARAM_L  (Transformer const arrays are ~32MB,
 *             too large for INSTRAM 128KB)                                    */
MEMORY
{
    INSTRAM   (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00020000   /* INSTR MEM: 128KB */
    DATARAM_L (rwx) : ORIGIN = 0x00200000, LENGTH = 0x04000000   /* DATA  MEM: 64MB  ← 16MB→64MB */
    DATARAM_H (rwx) : ORIGIN = 0x20000000, LENGTH = 0x00080000   /* IO    MEM: 512KB */
}

PROVIDE(_isramstart = ORIGIN(INSTRAM));
PROVIDE(_dsramstart = ORIGIN(DATARAM_L));
PROVIDE(_estack     = ORIGIN(DATARAM_L) + LENGTH(DATARAM_L));  /* Stack grows downward */

SECTIONS
{
  /* --- IMEM: code only (.rodata 제거 — Transformer 가중치가 너무 큼) --- */
  .text :
  {
    PROVIDE(_start = .);
    . = ALIGN(4);
    _stext = .;
    *(.text) *(.text*)
    . = ALIGN(4);
    _etext = .;
  } > INSTRAM

  /* --- DMEM --- */
  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    PROVIDE(__global_pointer$ = . + 2048);
    *(.data) *(.data*) *(.sdata) *(.sdata*)
    . = ALIGN(4);
    _edata = .;
  } > DATARAM_L

  /* rodata (const 배열) → DATARAM_L
   * 기존에는 INSTRAM에 배치했으나 Transformer 가중치(~32MB)가
   * INSTRAM(128KB)을 초과하므로 DATARAM_L로 이동                            */
  .rodata :
  {
    . = ALIGN(4);
    *(.rodata) *(.rodata*) *(.srodata) *(.srodata*)
    . = ALIGN(4);
  } > DATARAM_L

  .weights :
  {
    . = ALIGN(4);
    _sweights = .;
    *(.weights)
    . = ALIGN(4);
    _eweights = .;
  } > DATARAM_L

  .label :
  {
    . = ALIGN(4);
    _slabel = .;
    *(.label)
    . = ALIGN(4);
    _elabel = .;
  } > DATARAM_L

  .arena (NOLOAD) : { . = ALIGN(4); *(.arena) } > DATARAM_L
  .bss   (NOLOAD) :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss) *(.bss*) *(.sbss) *(.sbss*) *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DATARAM_L
  .heap  (NOLOAD) : { . = ALIGN(4); _heap_start = .; } > DATARAM_L

  /* --- IOMEM --- */
  .input :
  {
    . = ALIGN(4);
    _sinput = .;
    *(.input)
    . = ALIGN(4);
    _einput = .;
  } > DATARAM_H
  PROVIDE(_input_base = ADDR(.input));

  .result :
  {
    . = ALIGN(4);
    _sresult = .;
    *(.result)
    . = ALIGN(4);
    _eresult = .;
  } > DATARAM_H
  PROVIDE(_result_base = ADDR(.result));
}

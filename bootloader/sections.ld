MEMORY
{
    ROM (rwx) : ORIGIN = 0x00000000, LENGTH = 2K
}

SECTIONS
{
    . = 0x00000000;

    .text : {
        *(.text*)
    } > ROM

    .rodata : {
        *(.rodata*)
    } > ROM

    .data : {
        *(.data*)
    } > ROM

    .bss : {
        *(.bss*)
        *(COMMON)
    } > ROM
}

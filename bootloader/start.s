.section .text
.global _start

_start:
    la   sp, 0x000007fc   /* small stack near the top of the 2 KB boot ROM */
    call main
hang:
    j    hang             /* main() jumps into the app and never returns */

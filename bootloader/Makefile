TOOLCHAIN_PREFIX = riscv-none-elf-

CFLAGS  = -march=rv32i -mabi=ilp32 -mno-relax -O2 -ffreestanding -Wall
LDFLAGS = -T sections.ld -nostdlib -Wl,--no-relax

ROM_WORDS = 512

all: bootloader.hex

bootloader.elf: start.s main.c sections.ld
	$(TOOLCHAIN_PREFIX)gcc $(CFLAGS) $(LDFLAGS) -o bootloader.elf start.s main.c

bootloader.bin: bootloader.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary bootloader.elf bootloader.bin

bootloader.hex: bootloader.bin ../app/makehex.py
	python3 ../app/makehex.py bootloader.bin $(ROM_WORDS) > bootloader.hex

clean:
	rm -f bootloader.elf bootloader.bin bootloader.hex

.PHONY: all clean

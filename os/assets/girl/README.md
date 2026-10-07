# the girl, as raw pixels

Raw 8-bit grayscale (0 = black, 255 = white), row-major, no header. Made from `girl_panic.gif` and the still JPG.

- `panic128.bin`: 16 frames × 128×128 (the panicking GIF, 20 ms per frame in the original)
- `panic64.bin`: 16 frames × 64×64
- `still128.bin`, `still64.bin`: the still image

Use them from a program's `assets.mjs` (dither, quantise, compress, encrypt...).


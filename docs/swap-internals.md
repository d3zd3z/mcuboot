# Swap Algorithm Internals

This document describes the three swap algorithm implementations in
`boot/bootutil/src/` from a code perspective — how they work, how
they differ, and how to choose between them. For the on-flash format
and protocol details, see [design.md](design.md).

## Overview

MCUboot supports six upgrade modes (see
[code-architecture.md](code-architecture.md)), three of which
perform a swap: moving the secondary slot image into the primary slot
while preserving the old image for possible revert. These three are:

| Mode | Config macro | Source file | Scratch area needed | States per sector |
|---|---|---|---|---|
| Swap using scratch | `MCUBOOT_SWAP_USING_SCRATCH` *(default)* | `swap_scratch.c` | Yes | 3 |
| Swap using move | `MCUBOOT_SWAP_USING_MOVE` | `swap_move.c` | No | 3 |
| Swap using offset | `MCUBOOT_SWAP_USING_OFFSET` | `swap_offset.c` | No | 2 |

**For new designs, prefer `MCUBOOT_SWAP_USING_OFFSET`.** It is
preferred over `MCUBOOT_SWAP_USING_MOVE`, which is in turn preferred
over the default scratch-based algorithm. The scratch algorithm is
the default only for backwards compatibility with existing
deployments.

All three algorithms:
- Are resumable after a power failure at any point
- Track progress via swap status bytes written to the image trailer
- Share a common interface defined in `swap_priv.h` and the shared
  code in `swap_misc.c`
- Use `boot_copy_region()` (in `loader.c`) as the primitive for
  moving data between flash regions

## Shared Interface (`swap_priv.h` / `swap_misc.c`)

`swap_misc.c` contains the code shared across all three algorithms:

- **`swap_run()`** — the entry point called by `loader.c`. Reads
  existing status (resuming if interrupted), then dispatches to the
  algorithm-specific implementation.
- **`swap_read_status()` / `swap_read_status_bytes()`** — reads the
  swap status bytes from flash to determine where a previous swap
  was interrupted.
- **`swap_status_source()`** — locates the swap status: it may be
  in the primary slot, the scratch area (scratch mode only), or
  absent.
- **`swap_status_init()`** — writes the initial status metadata to
  start a new swap.
- **`swap_erase_trailer_sectors()`** — erases trailer sectors before
  writing (on devices requiring erase-before-write).
- **`swap_scramble_trailer_sectors()`** — removes swap status
  without erasing (for devices not requiring erase).
- **`swap_set_copy_done()`** — marks the image in the primary slot
  as fully copied.
- **`swap_set_image_ok()`** — marks the primary slot image as
  confirmed (preventing revert).

## Status Tracking

Each swap algorithm tracks progress by writing status bytes into the
**image trailer** — the reserved region at the end of each flash
slot (see `bootutil_priv.h` for the layout diagram).

The swap status region records the state of each sector index,
written incrementally. Because flash cannot be overwritten without
an erase, each sector uses multiple records: scratch and move modes
use 3 bytes per sector; offset mode uses 2 bytes per sector. This
means:

- Swap status size =
  `BOOT_MAX_IMG_SECTORS × BOOT_MAX_ALIGN × states_per_sector`
- With defaults (128 sectors, 4-byte alignment, 3 states):
  **1536 bytes**

The `BOOT_MAX_IMG_SECTORS` config option can be tuned down to save
flash at the cost of supporting fewer sectors per image.

## Scratch-Based Swap (`swap_scratch.c`)

### How it works

Uses a dedicated scratch area in flash as temporary storage. For
each sector (iterating from highest index to lowest):

1. Copy `secondary[i]` → scratch
2. Copy `primary[i]` → secondary (overwriting)
3. Copy scratch → `primary[i]`

After each copy step, a status byte is written to the primary slot
trailer (or scratch trailer for the last sector region). This gives
3 states per sector.

### Power-fail recovery

On resume, `swap_status_source()` checks both the primary slot and
the scratch area for a valid magic value. If found in scratch, the
swap was interrupted during the last-sector copy. The `swap_info`
field identifies which image the scratch belongs to (important for
multi-image boots).

### When to use

Only for existing products already using this mode. The scratch area
represents additional flash overhead and additional flash wear.

### Flash requirements

- Requires a separately-defined scratch area
  (`FLASH_AREA_IMAGE_SCRATCH`)
- Scratch area must be large enough to hold the largest flash sector
- Primary and secondary slot sizes must be equal
- Maximum image size: `slot_size - trailer_size`

## Move-Based Swap (`swap_move.c`)

### How it works

Eliminates the scratch area by using one extra sector in the primary
slot as a temporary buffer.

Phase 1 (MOVE): Shifts all sectors of the primary slot up by one
position, freeing sector 0.
Phase 2 (SWAP): For each sector `i` from 0 upward:
1. Copy `secondary[i]` → `primary[i]`
2. Copy `primary[i+1]` (the moved-up copy) → `secondary[i]`

Two status bytes per operation, three states per sector.

### Power-fail recovery

The status region is always in the primary slot. On resume, the `op`
field in `boot_status` distinguishes between the MOVE phase and the
SWAP phase.

### When to use

Prefer `swap_offset` for new designs. Use `swap_move` only for
existing products that are already deployed with it and where
changing the slot layout is not feasible.

### Flash requirements

- No scratch area needed
- Primary slot should be exactly one sector larger than the
  secondary slot (plus swap status area), though equal sizes are
  permitted with wasted space
- All sectors must be the same size
- Write block sizes of both slots must match
  (`MCUBOOT_SLOT0_EXPECTED_WRITE_SIZE` /
  `MCUBOOT_SLOT1_EXPECTED_WRITE_SIZE`)
- Maximum image size: `(N-1) × sector_size - trailer_sectors_size`
  where N is the number of sectors in the primary slot

## Offset-Based Swap (`swap_offset.c`)

### How it works

Uses the first sector of the secondary slot as a temporary buffer
rather than a scratch area or an extra primary slot sector.

The update image must be placed **starting at the second sector** of
the secondary slot (offset by one sector). The first sector of the
secondary slot is left empty as working space.

For each sector `i`:
1. Copy `primary[i]` → `secondary[i]` (the empty "offset" position)
2. Copy `secondary[i+1]` → `primary[i]`

Two status bytes per sector (one less than the other algorithms),
resulting in a smaller swap status area.

### Unprotected TLV sizes

The offset algorithm has one additional trailer field not present in
the others: the unprotected TLV sizes for both slots. This is needed
because during a swap, the TLV area of an image moves between slots,
and the bootloader needs to know where the TLVs end when resuming an
interrupted swap. These sizes are stored in
`boot_loader_state.imgs[i][slot].unprotected_tlv_size` and written
to the trailer by `boot_write_unprotected_tlv_sizes()`.

### Power-fail recovery

Status is always in the primary slot. Recovery is simpler than
scratch mode because status is never in a secondary area.

### When to use

**Preferred for all new designs.** The offset approach uses less
flash for the swap status area (2 states vs. 3), does not require a
separate scratch partition, and has simpler recovery logic.

### Flash requirements

- No scratch area needed
- Secondary slot should be exactly one sector larger than the
  primary slot; equal sizes are allowed
- All sectors must be the same size
- Write block sizes of both slots must match
- Update image must be placed at an offset of one sector into the
  secondary slot (imgtool handles this)
- Maximum image size: `N × sector_size - trailer_sectors_size`
  where N is the number of sectors in the primary slot

## `boot_copy_region()` — The Common Primitive

All three swap algorithms use `boot_copy_region()` (in `loader.c`)
to move data between flash regions. Its signature varies slightly
depending on whether encryption is enabled and which swap mode is
active:

```c
// Standard version
int boot_copy_region(struct boot_loader_state *state,
                     const struct flash_area *fap_src,
                     const struct flash_area *fap_dst,
                     uint32_t off_src, uint32_t off_dst, uint32_t sz);

// With MCUBOOT_SWAP_USING_OFFSET + MCUBOOT_ENC_IMAGES
int boot_copy_region(struct boot_loader_state *state,
                     const struct flash_area *fap_src,
                     const struct flash_area *fap_dst,
                     uint32_t off_src, uint32_t off_dst, uint32_t sz,
                     uint32_t sector_off);
```

`boot_copy_region()` handles on-the-fly decryption/re-encryption
when `MCUBOOT_ENC_IMAGES` is enabled: it decrypts when copying from
secondary to primary (the AES-CTR counter is keyed to the sector
offset) and re-encrypts when copying from primary to secondary
during a revert.

## Adding a New Swap Algorithm

If you need to implement a new swap strategy:

1. Add a new `MCUBOOT_SWAP_USING_*` guard to `bootutil_priv.h`'s
   exclusivity check.
2. Implement the functions declared in `swap_priv.h`:
   `swap_status_source()`, `swap_read_status_bytes()`, and a
   `swap_run()` variant. The existing `.c` files are good models.
3. Add the new macro to the `swap_misc.c` compilation guards.
4. Add a feature flag to `sim/mcuboot-sys/Cargo.toml` and a config
   header under `sim/mcuboot-sys/csupport/`.
5. Add it to the CI test matrix in `.github/workflows/sim.yaml`.
6. Write simulator tests in `sim/tests/core.rs` exercising
   untimely-reset scenarios — this is the primary correctness
   validation for swap algorithms.

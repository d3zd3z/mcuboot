# MCUboot Code Architecture

This document describes the internal structure of `boot/bootutil/`
for developers who want to understand, modify, or extend MCUboot.
For the protocol and on-flash format specification, see
[design.md](design.md). For porting to a new OS, see
[PORTING.md](PORTING.md).

## Two-Layer Structure

MCUboot is split into two layers:

- **`boot/bootutil/`** — the OS-agnostic library that performs all
  bootloader logic
- **`boot/<os>/`** — the OS-specific boot application that calls
  into bootutil and handles the final jump to the main image

The reason for this split is testability: a library can be
unit-tested (via the Rust simulator in `sim/`), while an application
cannot. All bootloader logic should go in bootutil; the OS-specific
layer only provides the platform integration and chain-loading.

## Source File Map

Files are grouped below by concern. All files are under
`boot/bootutil/src/` unless otherwise noted.

### Boot Orchestration

| File | Role |
|---|---|
| `loader.c` | Top-level boot logic. Contains `boot_go()`, `context_boot_go()`, and the per-image decision loops. This is the entry point into all bootutil logic. |
| `bootutil_loader.c` | Helper functions used by `loader.c`: header reading/validation, image checking, version comparison, security counter update, shared data population. |
| `bootutil_loader.h` | Internal header for `bootutil_loader.c`; also defines the `TARGET_STATIC` macro used to control stack vs. global allocation on-target vs. in the simulator. |
| `bootutil_priv.h` | The central internal header. Defines `boot_loader_state`, `boot_status`, all internal function prototypes, and accessor macros. Every internal `.c` file includes this. |

### Swap Algorithms

| File | Role |
|---|---|
| `swap_misc.c` | Code shared by all swap modes: status reading/writing, trailer management, `swap_run()` dispatcher. |
| `swap_priv.h` | Internal interface for the swap subsystem: the `swap_*` function signatures that `swap_misc.c` and `loader.c` call, and that each algorithm implements. |
| `swap_scratch.c` | Scratch-based swap algorithm (`MCUBOOT_SWAP_USING_SCRATCH`). This is the **default** if no upgrade mode is specified. |
| `swap_move.c` | Move-based swap algorithm (`MCUBOOT_SWAP_USING_MOVE`). No scratch area needed. |
| `swap_offset.c` | Offset-based swap algorithm (`MCUBOOT_SWAP_USING_OFFSET`). Preferred for new designs. |

See [swap-internals.md](swap-internals.md) for a detailed comparison.

### Flash Area Abstraction

| File | Role |
|---|---|
| `bootutil_area.c` | Trailer size calculations (`boot_status_sz`, `boot_trailer_sz`), region erase/scramble operations, slot invalidation. |
| `bootutil_area.h` | Internal header for `bootutil_area.c`. |

### Image Validation

| File | Role |
|---|---|
| `image_validate.c` | Top-level image validation: magic check, TLV parsing, SHA hash verification, signature dispatch, security counter check. Entry point: `bootutil_img_validate()`. |
| `tlv.c` | TLV iterator: `bootutil_tlv_iter_begin()` and `bootutil_tlv_iter_next()`. Handles both protected and unprotected TLV areas. |
| `bootutil_img_hash.c` | Hash computation helper used during validation. |
| `bootutil_find_key.c` | Key lookup: matches `KEYHASH` or `PUBKEY` TLVs against the bootloader's embedded key set. |
| `bootutil_img_security_cnt.c` | Security counter extraction from images, used by hardware rollback protection. |

### Signature Verification

Exactly one of these is compiled, selected by the corresponding
`MCUBOOT_SIGN_*` option. All implement `bootutil_verify_sig()`.

| File | Config macro | Algorithm |
|---|---|---|
| `image_rsa.c` | `MCUBOOT_SIGN_RSA` | RSA-2048 or RSA-3072 with PSS padding |
| `image_ecdsa.c` | `MCUBOOT_SIGN_EC256` or `MCUBOOT_SIGN_EC384` | ECDSA |
| `image_ed25519.c` | `MCUBOOT_SIGN_ED25519` | Ed25519 |
| `ed25519_psa.c` | `MCUBOOT_SIGN_ED25519` + `MCUBOOT_USE_PSA_CRYPTO` | Ed25519 via PSA Crypto |

### Encryption

One of these is compiled, depending on `MCUBOOT_USE_PSA_CRYPTO`.

| File | Config macro | Notes |
|---|---|---|
| `encrypted.c` | `MCUBOOT_ENC_IMAGES` (without PSA) | Key unwrapping via direct MbedTLS API. Supports RSA-OAEP, AES-KW, ECIES-P256, ECIES-X25519. |
| `encrypted_psa.c` | `MCUBOOT_ENC_IMAGES` + `MCUBOOT_USE_PSA_CRYPTO` | Same schemes via PSA Crypto API. Preferred for new ports. |

### Special Boot Modes

| File | Config macro | Role |
|---|---|---|
| `ram_load.c` | `MCUBOOT_RAM_LOAD` | Copies the image from flash into RAM before validation and execution. |

### Security Hardening

| File | Role |
|---|---|
| `fault_injection_hardening.c` | Provides FIH (Fault Injection Hardening) primitives: `FIH_SUCCESS`/`FIH_FAILURE` encoded return values, Control Flow Integrity counter, and panic loop. |
| `fault_injection_hardening_delay_rng_mbedtls.c` | Random execution delay for `MCUBOOT_FIH_PROFILE_MAX` — adds timing unpredictability to resist fault injection attacks. |

### Attestation

| File | Role |
|---|---|
| `boot_record.c` | Builds the measured boot record (CBOR-encoded) and writes it to the shared data area between bootloader and runtime firmware. Used when `MCUBOOT_MEASURED_BOOT` is enabled. |

### Public API

| File | Role |
|---|---|
| `bootutil_public.c` | Functions accessible to OS-specific code and applications: swap state reading, image-OK marking, magic values, `boot_swap_table` for swap type determination. |
| `bootutil_misc.c` | Miscellaneous internal utilities. |
| `caps.c` | `boot_get_caps()` — returns a bitmask of compile-time capabilities (swap mode, encryption, etc.) at runtime. |

## Key Data Structures

### `struct boot_loader_state` (`bootutil_priv.h`)

The central state object, stack-allocated in `context_boot_go()`.
It lives only during the boot process.

```c
struct boot_loader_state {
    // Per-image, per-slot data
    struct {
        struct image_header hdr;     // Cached image header
        const struct flash_area *area; // Flash region handle
        boot_sector_t *sectors;      // Sector layout array
        uint32_t num_sectors;
        uint16_t unprotected_tlv_size; // swap_offset only
    } imgs[BOOT_IMAGE_NUMBER][BOOT_NUM_SLOTS];

    struct { ... } scratch;          // swap_scratch only

    uint8_t swap_type[BOOT_IMAGE_NUMBER]; // BOOT_SWAP_TYPE_*
    uint32_t write_sz[BOOT_IMAGE_NUMBER]; // Flash write block size
    uint32_t secondary_offset[BOOT_IMAGE_NUMBER]; // swap_offset only

    struct enc_key_data enc[...];    // MCUBOOT_ENC_IMAGES only

    // MCUBOOT_DIRECT_XIP or MCUBOOT_RAM_LOAD only:
    struct slot_usage_t {
        uint32_t active_slot;
        bool slot_available[BOOT_NUM_SLOTS];
        uint32_t img_dst;  // ram_load only
        uint32_t img_sz;   // ram_load only
        struct boot_swap_state swap_state; // revert support
    } slot_usage[BOOT_IMAGE_NUMBER];
};
```

The `imgs` array is indexed `[image_index][slot]` where `slot` is
`BOOT_SLOT_PRIMARY` (0) or `BOOT_SLOT_SECONDARY` (1). The macro
`BOOT_IMG(state, slot)` accesses the current image's slot using
`state->curr_img_idx`.

### `struct boot_status` (`bootutil_priv.h`)

Tracks progress of an in-progress swap operation, used for
power-fail recovery.

```c
struct boot_status {
    uint32_t idx;        // Which sector is being swapped
    uint8_t  state;      // BOOT_STATUS_STATE_0/1/2 — which sub-step
    uint8_t  op;         // BOOT_STATUS_OP_MOVE or BOOT_STATUS_OP_SWAP
    uint8_t  use_scratch; // Whether status bytes go to scratch
    uint8_t  swap_type;  // BOOT_SWAP_TYPE_*
    uint32_t swap_size;  // Total bytes being swapped
    int      source;     // Where status was found on resume
    // Plus encryption keys if MCUBOOT_ENC_IMAGES
};
```

`boot_status` is written into the image trailer on flash after each
sector operation, enabling exact resume after a reset.

### `struct boot_swap_state` (`include/bootutil/bootutil_public.h`)

The on-flash trailer state as seen from outside bootutil (public
API). Contains `magic`, `swap_type`, `copy_done`, and `image_ok`
fields read from the end of a slot.

## Boot Flow

```
boot_go()
  └─ context_boot_go()
       ├─ boot_open_all_flash_areas()
       ├─ boot_read_sectors()               [swap modes only]
       │
       │  [Loop 1: resume interrupted swaps]
       ├─ IMAGES_ITER: boot_read_image_headers(require_all=false, bs)
       │     └─ swap_read_status() → populates bs if swap in progress
       │     └─ swap_run() if bs indicates incomplete swap
       │
       │  [Loop 2: determine swap types]
       ├─ IMAGES_ITER: boot_read_image_headers(require_all=true, bs=NULL)
       │     └─ boot_check_header_valid()
       │
       │  [Swap type determination from trailers]
       ├─ IMAGES_ITER: boot_check_image(secondary slot)
       │     └─ bootutil_img_validate()
       │           ├─ tlv.c: iterate TLVs
       │           ├─ hash verification
       │           └─ bootutil_verify_sig()   [image_rsa/ecdsa/ed25519.c]
       │
       │  [Loop 3: dependency check — multi-image only]
       │
       │  [Loop 4: perform swaps]
       ├─ IMAGES_ITER: swap_run() if BOOT_IS_UPGRADE(swap_type)
       │     └─ swap_scratch/move/offset.c
       │           └─ boot_copy_region()
       │
       │  [Loop 5: validate selected primary slot]
       ├─ IMAGES_ITER: boot_check_image(primary slot)
       │
       ├─ boot_add_shared_data()             [MCUBOOT_MEASURED_BOOT]
       ├─ boot_update_security_counter()     [MCUBOOT_HW_ROLLBACK_PROT]
       ├─ boot_close_all_flash_areas()
       └─ populate boot_rsp → return to OS-specific code
```

For `MCUBOOT_DIRECT_XIP` and `MCUBOOT_RAM_LOAD`, the flow is
different: it selects between slots by version number rather than
swapping, and `ram_load.c` handles copying to SRAM.

## Configuration Macro → Code Path Mapping

### Upgrade Mode (mutually exclusive; exactly one must be set)

| Macro | Source file(s) activated | Notes |
|---|---|---|
| *(none set)* | `swap_scratch.c` | Default when nothing is specified |
| `MCUBOOT_SWAP_USING_SCRATCH` | `swap_scratch.c` | Explicit scratch mode |
| `MCUBOOT_SWAP_USING_MOVE` | `swap_move.c` | No scratch; preferred over scratch |
| `MCUBOOT_SWAP_USING_OFFSET` | `swap_offset.c` | **Preferred for new designs** |
| `MCUBOOT_OVERWRITE_ONLY` | *(no swap files)* | Simple overwrite, no revert |
| `MCUBOOT_DIRECT_XIP` | *(loader.c direct-xip path)* | Run from either slot |
| `MCUBOOT_RAM_LOAD` | `ram_load.c` | Copy to RAM before execution |
| `MCUBOOT_FIRMWARE_LOADER` | *(loader.c firmware loader path)* | |
| `MCUBOOT_SINGLE_APPLICATION_SLOT` | *(loader.c single-slot path)* | |

### Signature Algorithm (mutually exclusive)

| Macro | Source file |
|---|---|
| `MCUBOOT_SIGN_RSA` | `image_rsa.c` |
| `MCUBOOT_SIGN_EC256` or `MCUBOOT_SIGN_EC384` | `image_ecdsa.c` |
| `MCUBOOT_SIGN_ED25519` | `image_ed25519.c` (or `ed25519_psa.c` if PSA) |

### Crypto Backend

| Macro | Effect |
|---|---|
| `MCUBOOT_USE_PSA_CRYPTO` | **Preferred.** Selects `encrypted_psa.c` over `encrypted.c`; selects `ed25519_psa.c` |
| `MCUBOOT_USE_MBED_TLS` | **Deprecated** — direct Mbed TLS API path. Retained for existing ports only. |
| `MCUBOOT_USE_TINYCRYPT` | **Deprecated** — TinyCrypt for ECDSA. Retained for existing ports only. |

### Encryption

| Macro | Effect |
|---|---|
| `MCUBOOT_ENC_IMAGES` | Enables encrypted image support; activates `encrypted.c` or `encrypted_psa.c` |
| `MCUBOOT_ENCRYPT_RSA` | Key wrap method: RSA-OAEP |
| `MCUBOOT_ENCRYPT_KW` | Key wrap method: AES key wrap |
| `MCUBOOT_ENCRYPT_EC256` | Key wrap method: ECIES-P256 |
| `MCUBOOT_ENCRYPT_X25519` | Key wrap method: ECIES-X25519 |
| `MCUBOOT_SWAP_SAVE_ENCTLV` | Saves encrypted TLVs (not plaintext keys) to scratch/status area — required when scratch is on external flash |

### Other Features

| Macro | Effect |
|---|---|
| `MCUBOOT_VALIDATE_PRIMARY_SLOT` | Validates primary slot signature on every boot, not just after swap |
| `MCUBOOT_DOWNGRADE_PREVENTION` | Rejects downgrades (only with `MCUBOOT_OVERWRITE_ONLY`) |
| `MCUBOOT_HW_ROLLBACK_PROT` | Hardware security counter check during validation |
| `MCUBOOT_MEASURED_BOOT` | Writes boot record to shared RAM for attestation services |
| `MCUBOOT_DATA_SHARING` | Enables sharing app-specific data via shared RAM |
| `MCUBOOT_BOOTSTRAP` | Allows installing a first image into an empty primary slot |
| `MCUBOOT_IMAGE_NUMBER` | Number of independently-updated images (default 1) |
| `BOOT_MAX_IMG_SECTORS` | Max sectors per slot (default 128); affects swap status size |
| `BOOT_MAX_ALIGN` | Flash write alignment (default 8); affects trailer layout |
| `MCUBOOT_FIH_PROFILE_*` | Fault Injection Hardening level (OFF, LOW, MEDIUM, HIGH, MAX) |

## The Simulator

The Rust simulator in `sim/` wraps bootutil via FFI to run the C
boot logic in tests. The C code is compiled by
`sim/mcuboot-sys/build.rs` with feature-specific config headers
from `sim/mcuboot-sys/csupport/config-*.h`. The `__BOOTSIM__`
preprocessor define is set during simulator builds and gates a few
simulator-specific behaviors (notably `TARGET_STATIC` becomes
stack-allocated, and RAM load uses a per-thread buffer).

When adding new C compile-time configuration, add the corresponding
feature flag to `sim/mcuboot-sys/Cargo.toml` and a `config-*.h`
file, and add it to the CI matrix in
`.github/workflows/sim.yaml`.

## Public vs. Internal API

**Public** (safe to call from OS-specific code):
- `boot/bootutil/include/bootutil/bootutil.h`: `boot_go()`,
  `boot_rsp`, `image_trailer`
- `boot/bootutil/include/bootutil/bootutil_public.h`: swap state
  read/write, `boot_swap_table`, image-OK functions
- `boot/bootutil/include/bootutil/image.h`: `image_header`,
  `image_version`, TLV type constants

**Internal** (should not be called from outside bootutil):
- Everything in `boot/bootutil/src/bootutil_priv.h`
- `swap_priv.h`, `bootutil_loader.h`, `bootutil_area.h`,
  `bootutil_misc.h`

The distinction matters for porting: the OS-specific boot app should
only call the public API. The simulator bypasses this by linking the
full library.

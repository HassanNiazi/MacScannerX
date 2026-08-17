// Raw USB transport for HP LEDM scanners.
//
// HP all-in-ones such as the DeskJet 2300 expose an HTTP server on a
// vendor-specific USB interface (class 0xFF, subclass 0x04, protocol 0x01).
// This layer only moves bytes on that interface's bulk pipes; HTTP framing and
// the LEDM protocol live in Swift.

#ifndef HPUSB_H
#define HPUSB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HPUSB_MAX_DEVICES 16

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;      // stable per physical port; used as the open key
    char     product[128];
    char     serial[64];
    uint8_t  interface_number;
    uint8_t  has_ledm_interface;
} hpusb_device_info;

typedef struct hpusb_handle hpusb_handle;

/// Fills `out` with HP devices that expose an LEDM-shaped vendor interface.
/// Returns the number written, or a negative errno-style code.
int hpusb_enumerate(hpusb_device_info *out, int max);

/// Opens the device at `location_id` and claims its LEDM interface.
/// Returns NULL on failure; `err` receives the IOReturn when non-NULL.
hpusb_handle *hpusb_open(uint32_t location_id, int32_t *err);

void hpusb_close(hpusb_handle *h);

/// Returns bytes written, or negative on failure.
int hpusb_write(hpusb_handle *h, const void *buf, uint32_t len, uint32_t timeout_ms);

/// Returns bytes read. Zero is normal and means the device sent a zero-length
/// packet — it is still working, so the caller should keep waiting.
/// Negative means a real transfer error.
int hpusb_read(hpusb_handle *h, void *buf, uint32_t len, uint32_t timeout_ms);

/// Discards anything left in the IN pipe and clears both pipe stalls, so a new
/// request starts from a known state. Reads until the pipe stays quiet, or `ms`
/// elapses. Returns how many stale bytes were discarded — non-zero means the
/// previous exchange had been abandoned mid-flight.
long hpusb_drain(hpusb_handle *h, uint32_t ms);

/// Last IOReturn seen on this handle, for diagnostics.
int32_t hpusb_last_error(hpusb_handle *h);

/// Re-syncs the endpoint data toggles. Cheap; fixes writes that fail after an
/// abandoned transfer. Returns 0 on success.
int hpusb_reset_pipes(hpusb_handle *h);

/// Full USB device reset — the only recovery when the printer's own HTTP server
/// has wedged. Requires that the device could be opened. Returns 0 on success.
int hpusb_reset_device(hpusb_handle *h);

#ifdef __cplusplus
}
#endif

#endif /* HPUSB_H */

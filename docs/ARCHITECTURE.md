# Architecture

How MacScannerX reaches a scanner, what it does to the pixels afterwards, and
why the awkward parts are shaped the way they are.

- [Scanner backends](#scanner-backends)
- [HP LEDM over USB](#ledmbackend--hp-ledm-over-usb)
- [Image pipeline](#image-pipeline)
- [Source layout](#source-layout)
- [Releases](#releases)

---

## Scanner backends

Four backends run together and merge into one device list. Each conforms to
`ScannerBackend` (`Sources/MacScannerX/Scanner/ScannerBackend.swift`): discover
devices, report capabilities, acquire pages, cancel.

LEDM is listed first when the same physical unit appears on more than one path,
because on an HP with no ICA driver it is the only one that can actually
acquire.

### `LEDMBackend` — HP LEDM over USB

**This is the one that makes a USB DeskJet 2300 work on macOS**, and it exists
because nothing else can reach it:

- the printer's USB printer interface is `7/1/`**`2`** (bidirectional), not
  `7/1/`**`4`**, so it has **no IPP-USB** — therefore no driverless AirScan;
- `system_profiler SPPrintersDataType` reports `Scanning support: No`, and the
  CUPS queue is bound to a generic *HP LaserJet PCL 4/5* PPD;
- `/Library/Image Capture/Devices/` is empty — no ICA scanner driver is
  installed, so `ImageCaptureCore` enumerates nothing.

The DeskJet 2300 exposes four USB interfaces:

| Interface | Class | Subclass | Protocol | Endpoints | Role |
|---|---|---|---|---|---|
| 0 | 0xFF | 0xCC | 0x00 | 3 | HP MLC / IEEE-1284.4 |
| 1 | 0x07 | 0x01 | 0x02 | 2 | bidirectional printer |
| **2** | **0xFF** | **0x04** | **0x01** | **2** | **HP HTTP server** |
| 3 | 0xFF | 0x04 | 0x01 | 2 | vendor |

Interface 2 serves **bare HTTP/1.1 on its bulk pipes** — no MLC framing, no
1284.4 packet layer. Behind it is HP's LEDM API:

```
GET  /DevMgmt/DiscoveryTree.xml   → resource tree
GET  /Scan/ScanJobManifest.xml    → the scan resource map
GET  /Scan/ScanCaps               → model, platen extent, resolutions, colour types
POST /Scan/Jobs                   → 201 + Location
GET  {Location}                   → poll until <BinaryURL> appears
GET  {BinaryURL}                  → JPEG page data
DELETE {Location}                 → release the job
```

Three device quirks drive the transport design in `USBHTTPClient`:

1. **Zero-length packets.** The server emits ZLPs while the carriage moves. A
   read loop that treats a ZLP as end-of-response will see every reply arrive
   one request late. The loop runs on a wall-clock deadline instead, and any
   real data resets it.
2. **`Connection: close` on every response,** so the pipes are drained and both
   stalls cleared before each request.
3. **Chunked bodies** far more often than `Content-Length`.

`Sources/CHPUSB` is a small C target over IOKit's `IOUSBLib` that claims
interface 2 and moves bytes; all HTTP and LEDM logic is Swift. One further
IOKit quirk: `IOServiceMatching("IOUSBDevice")` **ignores an `idVendor` filter
unless `idProduct` accompanies it**, so enumeration matches all USB devices and
filters on vendor in code.

Geometry is in 1/300 inch, the same unit eSCL uses. 1-bit (`K1`) is Raw-only on
these devices, so scans are always acquired at 8 bits and thresholded in the
pipeline — better results anyway.

### `ImageCaptureBackend` — ImageCaptureCore

Covers any scanner macOS already has a driver for: USB, Apple's AirScan, or a
scanner shared from another Mac. Drives `ICScannerDevice` directly — opens a
session, selects the flatbed functional unit, sets scan area in centimetres
(TWAIN has no millimetre unit), snaps the requested dpi to the nearest value the
hardware advertises, and receives pages file-based into a spool directory.

### `ESCLBackend` — AirScan / eSCL over the network

Reaches a network scanner with **no vendor software installed at all**.
Discovers `_uscan._tcp` / `_uscans._tcp` via Bonjour, parses
`ScannerCapabilities` for the real platen size and resolution list, then
`POST /eSCL/ScanJobs` → `GET {job}/NextDocument` → `DELETE {job}` to cancel.
Printers ship self-signed certificates, so the HTTPS variant uses a permissive
trust delegate.

### `SimulatedBackend`

A synthetic DeskJet 2300 that renders a scanner-plausible target (paper white
with platen falloff, text blocks, a colour bar, a greyscale step wedge,
registration marks, resolution-scaled sensor noise), so the whole app is
exercisable with no hardware attached. It is dropped automatically as soon as
real hardware appears — unless you pick it deliberately.

---

## Image pipeline

`ImagePipeline` applies the Crop/Filter/Color settings via Core Image:

```
crop → rotate → mirror → restore → descreen → grain → tone → colour → sharpen → threshold
```

Sharpening is deliberately last, so it does not amplify the noise the earlier
stages removed. Notable pieces:

- **Auto levels** reads a real 256-bin luminance histogram (`CIAreaHistogram`)
  and clips at the requested percentiles — that is what the black/white point
  sliders actually control.
- **Auto white balance** and **restore colors** measure mean channel response
  (`CIAreaAverage`) and apply a per-channel correction matrix.
- **Descreen** picks its blur radius from `scan dpi ÷ screen frequency`, so
  setting the frequency to match the original's print process matters.
- **Auto crop** finds the page edges by thresholding a downscaled greyscale copy
  and taking the non-white bounding box.

Output goes through `CGImageDestination` (JPEG/PNG/TIFF, multi-page TIFF for
feeder batches) and a `CGContext` PDF writer. Searchable PDFs run Vision OCR and
draw the recognised text in rendering mode 3 — invisible, but selectable.

---

## Source layout

```
Package.swift
build.sh                       compile + assemble + ad-hoc sign, optional DMG
Resources/
  Info.plist                   bundle id, Bonjour services, local-network usage
  MacScannerX.entitlements     unsandboxed; USB + network client
  AppIcon.icns                 app icon, rendered by Tools/MakeAppIcon.swift
Tools/
  MakeAppIcon.swift            draws the icon in Core Graphics, one slot per size
Sources/CHPUSB/
  include/hpusb.h              C API: enumerate, open, bulk read/write, drain
  hpusb.c                      IOKit IOUSBLib transport for HP's LEDM interface
Sources/MacScannerX/
  MacScannerXApp.swift         @main, menu commands, window sizing
  SelfTest.swift               --selftest, --devices, --testscan harnesses
  Model/
    ScanSettings.swift         every knob, JSON-persisted
    ScanController.swift       orchestration, discovery merge, debounced reprocess
  Scanner/
    ScannerBackend.swift       backend protocol and shared types
    LEDMBackend.swift          HP LEDM over USB — scan caps, jobs, page fetch
    USBHTTPClient.swift        HTTP/1.1 over USB bulk pipes (ZLP + chunked)
    ImageCaptureBackend.swift  ImageCaptureCore (USB / AirScan / shared)
    ESCLBackend.swift          Bonjour + eSCL REST, capability XML parsing
    SimulatedBackend.swift     synthetic DeskJet 2300
  Imaging/
    ImagePipeline.swift        Core Image processing chain
    OutputWriter.swift         JPEG/PNG/TIFF/PDF/OCR, file-name templates
  UI/
    ContentView.swift          split layout, tab strip, action buttons, log
    PreviewCanvas.swift        preview with draggable crop rectangle
    Controls.swift             option rows, sliders, measurement fields
    Panels/                    Input, Crop, Filter, Color, Output, Prefs
```

Settings persist to `~/Library/Application Support/MacScannerX/settings.json`.

The self-test writes PNG captures of all six tabs through a real
`NSHostingView` — `ImageRenderer` cannot draw AppKit-backed views such as
`HSplitView`, so `cacheDisplay(in:to:)` walks the live view tree instead.

---

## Releases

`.github/workflows/ci.yml` builds and self-tests every push and pull request on
a macOS runner. `.github/workflows/release.yml` runs on a `v*` tag: it stamps
`VERSION`/`BUILD_NUMBER` into the bundle, builds the DMG, and publishes it to a
GitHub Release with a SHA-256 sidecar.

Cutting a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The app is **ad-hoc signed**, so first launch needs the Gatekeeper override
described in the README. Adding Developer ID signing later means adding a
`codesign --sign "Developer ID Application: …"` pass plus `xcrun notarytool
submit --wait` and `xcrun stapler staple` to `release.yml`, with the certificate
and Apple ID credentials held as repository secrets — no other part of the
pipeline changes.

# MacScannerX

A VueScan-style scanning app for macOS, built for the **HP DeskJet 2300 series**.

Native SwiftUI. No Xcode required — Command Line Tools and SwiftPM are enough.

```bash
./build.sh release
open build/MacScannerX.app
```

---

## What it does

The six-tab options panel mirrors VueScan's layout, and every control is wired to
real work — nothing is decorative.

| Tab | Controls |
|---|---|
| **Input** | task, device, flatbed/feeder, media type, bit depth, scan & preview resolution, samples, rotation, mirror, auto-skew, auto-rotate, batch |
| **Crop** | Auto / Maximum / Manual / A4 / A5 / Letter / Legal / 4×6 / 5×7 / 8×10, X-Y offset, width, height, aspect lock, border %, auto-crop buffer, live output-size and file-size readout |
| **Filter** | restore colors, restore fading, descreen (by screen frequency), grain reduction, sharpen, line-art threshold |
| **Color** | colour balance (none/neutral/auto-levels/auto-white/landscape/manual), white & black point, tone curve with live graph, brightness, saturation, per-channel R/G/B gain, output colour space, invert |
| **Output** | folder, `scan+.jpg`-style auto-numbered names, JPEG / TIFF / PNG / PDF / OCR text, JPEG quality, TIFF compression, multi-page PDF, PDF paper size, searchable PDF, OCR language |
| **Prefs** | units, advanced options, settings file location, reset |

Plus a draggable crop rectangle on the preview with eight resize handles, a
timestamped log pane, and a progress/status bar.

---

## How it reaches the scanner

Four backends, tried together and merged into one device list.

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

Reaches the printer over Wi-Fi with **no HP software installed at all**.
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

LEDM is listed first when the same physical unit appears on more than one path,
because on an HP with no ICA driver it is the only one that can actually
acquire.

---

## Image pipeline

`ImagePipeline` applies the Crop/Filter/Color settings via Core Image, in
VueScan's order:

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

## Verifying it

The binary ships a self-test that drives the whole non-interactive path:

```bash
build/MacScannerX.app/Contents/MacOS/MacScannerX --selftest /tmp/msx-check
```

```
  ok    acquisition          1275×1754 px at 150 dpi
  ok    pipeline crop+rotate 709×591 px
  ok    pipeline bilevel     2 distinct luminance levels
  ok    pipeline invert      mean 0.878 → 0.544
  ok    naming               scan0001 → scan0002, 20260817-page0001.tif
  ok    output               7 files, PDF 2 pages @ 297×419 pt
  ok    auto crop            found (50, 120, 200, 300)
  ok    eSCL XML             well-formed, 2550×3300 units, RGB24, Platen
  ok    eSCL caps            HP DeskJet 2300 series, 215.9×297.0 mm, 5 resolutions, flatbed only
  ok    UI render            ui-input.png, ui-crop.png, ui-filter.png, ui-color.png, ui-output.png, ui-prefs.png

PASS — all checks green
```

It also writes PNG captures of all six tabs to the output directory, rendered
through a real `NSHostingView` (`ImageRenderer` cannot draw AppKit-backed views
such as `HSplitView`).

Two hardware diagnostics, which do touch the scanner:

```bash
# What each backend can see, plus a capability probe of the first real device.
build/MacScannerX.app/Contents/MacOS/MacScannerX --devices 8

# Acquire one real page, run the full pipeline, write it out.
build/MacScannerX.app/Contents/MacOS/MacScannerX --testscan 200 /tmp/page.jpg
```

Verified against a real DeskJet 2300 over USB:

```
HP LEDM over USB: 1 device(s)
  • DeskJet 2300 All-in-One Printer series
      transport  USB
      bed        215.9×297.0 mm
      sources    Flatbed
      dpi        75, 100, 200, 300, 600, 1200
PASS — scanner reachable
```

---

## HP DeskJet 2300 notes

Flatbed only — no document feeder, no duplex, no transparency unit. 1200 × 1200
dpi optical sensor, A4 platen (215.9 × 297 mm), colour and 8-bit grey, values
read live from `/Scan/ScanCaps`.

- **USB**: driven over HP LEDM. This works with no HP software and no ICA
  driver — and it is the *only* thing that works, since the device has no
  IPP-USB interface and macOS therefore exposes no scanner for it at all.
- **Wi-Fi**: advertises AirScan; MacScannerX drives it over standard eSCL.

If the scanner does not appear:

- quit **HP Smart** and **HP Easy Scan** — they hold the USB interface open;
- over Wi-Fi, allow MacScannerX under **System Settings → Privacy & Security →
  Local Network**;
- press the refresh button next to the Source picker to re-browse, or run
  `--devices` for a per-backend report.

Note that the printer showing up in **Printers & Scanners** proves nothing about
scanning: that entry is a CUPS print queue. `system_profiler SPPrintersDataType`
reports the truth under `Scanning support:`.

---

## Layout

```
Package.swift
build.sh                       compile + assemble + ad-hoc sign the .app
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
    Controls.swift             VueScan-style option rows
    Panels/                    Input, Crop, Filter, Color, Output, Prefs
```

Settings persist to `~/Library/Application Support/MacScannerX/settings.json`.

---

## Keyboard

| | |
|---|---|
| `⌘P` | Preview |
| `⌘↩` | Scan |
| `⌘S` | Save again (re-process and re-write without re-scanning) |
| `⌘.` | Cancel |
| `⌘R` | Look for scanners |

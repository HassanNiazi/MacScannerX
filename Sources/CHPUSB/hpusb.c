#include "include/hpusb.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define HP_VENDOR_ID 0x03F0

// The interface HP uses for its embedded HTTP/LEDM server.
#define LEDM_CLASS    0xFF
#define LEDM_SUBCLASS 0x04
#define LEDM_PROTOCOL 0x01

struct hpusb_handle {
    IOUSBDeviceInterface942    **device;
    IOUSBInterfaceInterface942 **interface;
    io_service_t                 service;
    uint8_t                      out_pipe;
    uint8_t                      in_pipe;
    int                          device_opened;
    int32_t                      last_error;
};

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static void cf_string(CFTypeRef ref, char *out, size_t size) {
    out[0] = 0;
    if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)ref, out, (CFIndex)size, kCFStringEncodingUTF8);
    }
}

static uint32_t cf_number(CFTypeRef ref) {
    uint32_t v = 0;
    if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt32Type, &v);
    }
    return v;
}

/// Iterates every USB device. IOKit's IOUSBDevice matching only honours a
/// vendor filter when a product ID accompanies it, so callers filter on
/// `device_vendor()` themselves rather than putting idVendor in the dictionary.
static io_iterator_t usb_device_iterator(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return 0;
    return iter;
}

static uint16_t device_vendor(io_service_t service) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBVendorID), NULL, 0);
    uint16_t v = (uint16_t)cf_number(ref);
    if (ref) CFRelease(ref);
    return v;
}

static IOUSBDeviceInterface942 **device_interface(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS
        || !plugin) {
        return NULL;
    }
    IOUSBDeviceInterface942 **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    return dev;
}

static IOUSBInterfaceInterface942 **interface_interface(io_service_t service) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS
        || !plugin) {
        return NULL;
    }
    IOUSBInterfaceInterface942 **itf = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942), (LPVOID *)&itf);
    (*plugin)->Release(plugin);
    return itf;
}

/// True when this interface looks like HP's LEDM HTTP channel.
static int is_ledm_interface(IOUSBInterfaceInterface942 **itf, uint8_t *number) {
    UInt8 cls = 0, sub = 0, proto = 0, num = 0;
    (*itf)->GetInterfaceClass(itf, &cls);
    (*itf)->GetInterfaceSubClass(itf, &sub);
    (*itf)->GetInterfaceProtocol(itf, &proto);
    (*itf)->GetInterfaceNumber(itf, &num);
    if (number) *number = num;
    return cls == LEDM_CLASS && sub == LEDM_SUBCLASS && proto == LEDM_PROTOCOL;
}

int hpusb_enumerate(hpusb_device_info *out, int max) {
    if (!out || max <= 0) return -1;
    io_iterator_t iter = usb_device_iterator();
    if (!iter) return 0;

    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) && count < max) {
        if (device_vendor(service) != HP_VENDOR_ID) {
            IOObjectRelease(service);
            continue;
        }
        hpusb_device_info info;
        memset(&info, 0, sizeof(info));
        info.vendor_id = HP_VENDOR_ID;

        CFTypeRef ref = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductID), NULL, 0);
        info.product_id = (uint16_t)cf_number(ref);
        if (ref) CFRelease(ref);

        ref = IORegistryEntryCreateCFProperty(service, CFSTR("locationID"), NULL, 0);
        info.location_id = cf_number(ref);
        if (ref) CFRelease(ref);

        ref = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), NULL, 0);
        cf_string(ref, info.product, sizeof(info.product));
        if (ref) CFRelease(ref);

        ref = IORegistryEntryCreateCFProperty(service, CFSTR("USB Serial Number"), NULL, 0);
        cf_string(ref, info.serial, sizeof(info.serial));
        if (ref) CFRelease(ref);

        // Walk the interfaces without opening the device: opening here would
        // fight whatever else is talking to the printer.
        io_iterator_t child_iter = 0;
        if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &child_iter) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(child_iter))) {
                CFTypeRef c = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceClass"), NULL, 0);
                CFTypeRef s = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceSubClass"), NULL, 0);
                CFTypeRef p = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceProtocol"), NULL, 0);
                CFTypeRef n = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceNumber"), NULL, 0);
                // Several interfaces share the LEDM signature; the lowest
                // numbered one is the HTTP channel, so keep the first match.
                if (!info.has_ledm_interface
                    && cf_number(c) == LEDM_CLASS && cf_number(s) == LEDM_SUBCLASS
                    && cf_number(p) == LEDM_PROTOCOL) {
                    info.has_ledm_interface = 1;
                    info.interface_number = (uint8_t)cf_number(n);
                }
                if (c) CFRelease(c);
                if (s) CFRelease(s);
                if (p) CFRelease(p);
                if (n) CFRelease(n);
                IOObjectRelease(child);
            }
            IOObjectRelease(child_iter);
        }

        if (info.has_ledm_interface) {
            out[count++] = info;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return count;
}

hpusb_handle *hpusb_open(uint32_t location_id, int32_t *err) {
    if (err) *err = 0;
    io_iterator_t iter = usb_device_iterator();
    if (!iter) return NULL;

    io_service_t service, found = 0;
    while ((service = IOIteratorNext(iter))) {
        if (device_vendor(service) != HP_VENDOR_ID) {
            IOObjectRelease(service);
            continue;
        }
        CFTypeRef ref = IORegistryEntryCreateCFProperty(service, CFSTR("locationID"), NULL, 0);
        uint32_t loc = cf_number(ref);
        if (ref) CFRelease(ref);
        if (loc == location_id) { found = service; break; }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    if (!found) return NULL;

    IOUSBDeviceInterface942 **dev = device_interface(found);
    if (!dev) { IOObjectRelease(found); return NULL; }

    // Deliberately NOT calling USBDeviceOpen. Claiming the whole device is
    // exclusive, so anything else holding a device-level user client (a browser
    // with WebUSB, for instance) would lock us out. Interfaces are claimed
    // independently, and iterating them needs no device open at all.
    int device_opened = ((*dev)->USBDeviceOpen(dev) == kIOReturnSuccess);
    if (!device_opened) {
        // Not fatal: interfaces are claimed separately below. Only device-level
        // operations (reset, configuration changes) need this, and we use none.
        device_opened = ((*dev)->USBDeviceOpenSeize(dev) == kIOReturnSuccess);
    }

    IOUSBFindInterfaceRequest req = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t itf_iter = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &itf_iter) != kIOReturnSuccess) {
        if (device_opened) (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        IOObjectRelease(found);
        return NULL;
    }

    IOUSBInterfaceInterface942 **chosen = NULL;
    uint8_t out_pipe = 0, in_pipe = 0;
    io_service_t itf_service;
    while ((itf_service = IOIteratorNext(itf_iter))) {
        IOUSBInterfaceInterface942 **itf = interface_interface(itf_service);
        IOObjectRelease(itf_service);
        if (!itf) continue;

        uint8_t number = 0;
        if (!is_ledm_interface(itf, &number)) { (*itf)->Release(itf); continue; }
        IOReturn open_result = (*itf)->USBInterfaceOpen(itf);
        if (open_result == kIOReturnExclusiveAccess) {
            // A stale handle — ours from a killed process, or another app that
            // grabbed the printer and never let go — locks the scanner out
            // permanently otherwise. Seize is the documented way back in.
            open_result = (*itf)->USBInterfaceOpenSeize(itf);
        }
        if (open_result != kIOReturnSuccess) {
            if (err) *err = open_result;
            (*itf)->Release(itf);
            continue;
        }

        UInt8 endpoints = 0;
        (*itf)->GetNumEndpoints(itf, &endpoints);
        uint8_t o = 0, i = 0;
        for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
            UInt8 dir = 0, num = 0, type = 0, interval = 0;
            UInt16 max_packet = 0;
            if ((*itf)->GetPipeProperties(itf, pipe, &dir, &num, &type, &max_packet, &interval)
                != kIOReturnSuccess) continue;
            if ((type & 0x03) != kUSBBulk) continue;
            if (dir == kUSBOut && !o) o = pipe;
            if (dir == kUSBIn && !i) i = pipe;
        }
        if (o && i) {
            chosen = itf; out_pipe = o; in_pipe = i;
            break;
        }
        // A vendor interface without a bulk pair is not the HTTP channel.
        (*itf)->USBInterfaceClose(itf);
        (*itf)->Release(itf);
    }
    IOObjectRelease(itf_iter);

    if (!chosen) {
        if (device_opened) (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        IOObjectRelease(found);
        return NULL;
    }
    if (err) *err = 0;

    // After a seize — or any abandoned transfer — the host and device endpoint
    // data toggles can disagree, which makes writes fail outright. ResetPipe
    // puts both ends back to a known state; ClearPipeStallBothEnds alone does not.
    (*chosen)->ResetPipe(chosen, out_pipe);
    (*chosen)->ResetPipe(chosen, in_pipe);

    hpusb_handle *h = calloc(1, sizeof(hpusb_handle));
    h->device_opened = device_opened;
    h->device = dev;
    h->interface = chosen;
    h->service = found;
    h->out_pipe = out_pipe;
    h->in_pipe = in_pipe;
    return h;
}

void hpusb_close(hpusb_handle *h) {
    if (!h) return;
    if (h->interface) {
        (*h->interface)->USBInterfaceClose(h->interface);
        (*h->interface)->Release(h->interface);
    }
    if (h->device) {
        if (h->device_opened) (*h->device)->USBDeviceClose(h->device);
        (*h->device)->Release(h->device);
    }
    if (h->service) IOObjectRelease(h->service);
    free(h);
}

int hpusb_write(hpusb_handle *h, const void *buf, uint32_t len, uint32_t timeout_ms) {
    if (!h || !h->interface) return -1;
    IOReturn r = (*h->interface)->WritePipeTO(h->interface, h->out_pipe, (void *)buf, len,
                                              timeout_ms, timeout_ms * 2);
    h->last_error = r;
    return r == kIOReturnSuccess ? (int)len : -1;
}

int hpusb_read(hpusb_handle *h, void *buf, uint32_t len, uint32_t timeout_ms) {
    if (!h || !h->interface) return -1;
    UInt32 n = len;
    IOReturn r = (*h->interface)->ReadPipeTO(h->interface, h->in_pipe, buf, &n,
                                             timeout_ms, timeout_ms * 2);
    h->last_error = r;
    if (r == kIOReturnSuccess) return (int)n;
    // A timeout with nothing pending is normal while the scanner works.
    if (r == kIOReturnTimeout || r == kIOUSBTransactionTimeout) return 0;
    return -1;
}

long hpusb_drain(hpusb_handle *h, uint32_t ms) {
    if (!h || !h->interface) return 0;
    enum { CHUNK = 65536, QUIET_READS = 4 };
    char *buf = malloc(CHUNK);
    double deadline = now_ms() + ms;
    long total = 0;
    int quiet = 0;

    // An abandoned high-resolution page leaves megabytes queued in the device.
    // Bailing out early leaves that data to be spliced into the next response,
    // which desynchronises every request that follows, so read until the pipe
    // is genuinely quiet rather than for a fixed slice of time.
    while (now_ms() < deadline) {
        UInt32 n = CHUNK;
        IOReturn r = (*h->interface)->ReadPipeTO(h->interface, h->in_pipe, buf, &n, 150, 300);
        if (r != kIOReturnSuccess) break;
        if (n == 0) {
            if (++quiet >= QUIET_READS) break;
            continue;
        }
        quiet = 0;
        total += n;
    }
    free(buf);
    (*h->interface)->ClearPipeStallBothEnds(h->interface, h->in_pipe);
    (*h->interface)->ClearPipeStallBothEnds(h->interface, h->out_pipe);
    return total;
}

int32_t hpusb_last_error(hpusb_handle *h) {
    return h ? h->last_error : 0;
}

int hpusb_reset_pipes(hpusb_handle *h) {
    if (!h || !h->interface) return -1;
    IOReturn a = (*h->interface)->ResetPipe(h->interface, h->out_pipe);
    IOReturn b = (*h->interface)->ResetPipe(h->interface, h->in_pipe);
    return (a == kIOReturnSuccess && b == kIOReturnSuccess) ? 0 : -1;
}

int hpusb_reset_device(hpusb_handle *h) {
    if (!h || !h->device || !h->device_opened) return -1;
    // A full USB reset is the only way back when the printer's own HTTP server
    // has wedged on an abandoned job; pipe resets only fix the host side.
    IOReturn r = (*h->device)->ResetDevice(h->device);
    h->last_error = r;
    return r == kIOReturnSuccess ? 0 : -1;
}

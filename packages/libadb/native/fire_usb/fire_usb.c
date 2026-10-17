/*
 * fire_usb: process-owned libusb device handles.
 *
 * Hot restart tears down Dart isolates but keeps this static table.
 * New Dart calls fire_usb_close / fire_usb_open to release_interface + close.
 */

#include "fire_usb.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef SSIZE_T fire_ssize;
typedef HMODULE fire_lib;
#define FIRE_LOAD(path) LoadLibraryA(path)
#define FIRE_SYM(lib, name) GetProcAddress(lib, name)
#define FIRE_UNLOAD(lib) FreeLibrary(lib)
#else
#include <dlfcn.h>
typedef ssize_t fire_ssize;
typedef void *fire_lib;
#define FIRE_LOAD(path) dlopen(path, RTLD_NOW)
#define FIRE_SYM(lib, name) dlsym(lib, name)
#define FIRE_UNLOAD(lib) dlclose(lib)
#endif

enum {
  kFireUsbError = -1000,
  kMaxSessions = 16,
  kMaxPorts = 8,
  kAdbClass = 0xff,
  kAdbSubclass = 0x42,
  kAdbProtocol = 0x01,
  kDbcClass = 0xdc,
  kDbcSubclass = 0x02,
  kBulk = 2,
  kEndpointIn = 0x80,
};

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;
typedef struct libusb_config_descriptor libusb_config_descriptor;

typedef struct libusb_device_descriptor {
  uint8_t bLength;
  uint8_t bDescriptorType;
  uint16_t bcdUSB;
  uint8_t bDeviceClass;
  uint8_t bDeviceSubClass;
  uint8_t bDeviceProtocol;
  uint8_t bMaxPacketSize0;
  uint16_t idVendor;
  uint16_t idProduct;
  uint16_t bcdDevice;
  uint8_t iManufacturer;
  uint8_t iProduct;
  uint8_t iSerialNumber;
  uint8_t bNumConfigurations;
} libusb_device_descriptor;

typedef struct libusb_endpoint_descriptor {
  uint8_t bLength;
  uint8_t bDescriptorType;
  uint8_t bEndpointAddress;
  uint8_t bmAttributes;
  uint16_t wMaxPacketSize;
  uint8_t bInterval;
  uint8_t bRefresh;
  uint8_t bSynchAddress;
  const unsigned char *extra;
  int extra_length;
} libusb_endpoint_descriptor;

typedef struct libusb_interface_descriptor {
  uint8_t bLength;
  uint8_t bDescriptorType;
  uint8_t bInterfaceNumber;
  uint8_t bAlternateSetting;
  uint8_t bNumEndpoints;
  uint8_t bInterfaceClass;
  uint8_t bInterfaceSubClass;
  uint8_t bInterfaceProtocol;
  uint8_t iInterface;
  const libusb_endpoint_descriptor *endpoint;
  const unsigned char *extra;
  int extra_length;
} libusb_interface_descriptor;

typedef struct libusb_interface {
  const libusb_interface_descriptor *altsetting;
  int num_altsetting;
} libusb_interface;

struct libusb_config_descriptor {
  uint8_t bLength;
  uint8_t bDescriptorType;
  uint16_t wTotalLength;
  uint8_t bNumInterfaces;
  uint8_t bConfigurationValue;
  uint8_t iConfiguration;
  uint8_t bmAttributes;
  uint8_t MaxPower;
  const libusb_interface *interface;
  const unsigned char *extra;
  int extra_length;
};

typedef int (*fn_init)(libusb_context **);
typedef void (*fn_exit)(libusb_context *);
typedef fire_ssize (*fn_get_device_list)(libusb_context *, libusb_device ***);
typedef void (*fn_free_device_list)(libusb_device **, int);
typedef int (*fn_get_device_descriptor)(libusb_device *,
                                         libusb_device_descriptor *);
typedef int (*fn_get_active_config_descriptor)(libusb_device *,
                                               libusb_config_descriptor **);
typedef int (*fn_get_config_descriptor)(libusb_device *, uint8_t,
                                        libusb_config_descriptor **);
typedef void (*fn_free_config_descriptor)(libusb_config_descriptor *);
typedef uint8_t (*fn_get_bus_number)(libusb_device *);
typedef uint8_t (*fn_get_device_address)(libusb_device *);
typedef int (*fn_get_port_numbers)(libusb_device *, uint8_t *, int);
typedef int (*fn_open)(libusb_device *, libusb_device_handle **);
typedef void (*fn_close)(libusb_device_handle *);
typedef int (*fn_claim_interface)(libusb_device_handle *, int);
typedef int (*fn_release_interface)(libusb_device_handle *, int);
typedef int (*fn_set_auto_detach)(libusb_device_handle *, int);
typedef int (*fn_get_configuration)(libusb_device_handle *, int *);
typedef int (*fn_set_configuration)(libusb_device_handle *, int);
typedef int (*fn_get_string_descriptor_ascii)(libusb_device_handle *, uint8_t,
                                              unsigned char *, int);
typedef libusb_device *(*fn_get_device)(libusb_device_handle *);

typedef struct fire_libusb {
  fire_lib lib;
  fn_init init;
  fn_exit exit;
  fn_get_device_list get_device_list;
  fn_free_device_list free_device_list;
  fn_get_device_descriptor get_device_descriptor;
  fn_get_active_config_descriptor get_active_config_descriptor;
  fn_get_config_descriptor get_config_descriptor;
  fn_free_config_descriptor free_config_descriptor;
  fn_get_bus_number get_bus_number;
  fn_get_device_address get_device_address;
  fn_get_port_numbers get_port_numbers;
  fn_open open;
  fn_close close;
  fn_claim_interface claim_interface;
  fn_release_interface release_interface;
  fn_set_auto_detach set_auto_detach_kernel_driver;
  fn_get_configuration get_configuration;
  fn_set_configuration set_configuration;
  fn_get_string_descriptor_ascii get_string_descriptor_ascii;
  fn_get_device get_device;
} fire_libusb;

typedef struct fire_session {
  int used;
  char port_path[128];
  libusb_context *context;
  libusb_device_handle *handle;
  int interface_number;
} fire_session;

static fire_libusb g_api;
static int g_api_ready;
static fire_session g_sessions[kMaxSessions];

static const char *default_libusb_name(void) {
#ifdef _WIN32
  return "libusb-1.0.dll";
#elif defined(__APPLE__)
  return "libusb-1.0.dylib";
#else
  return "libusb-1.0.so.0";
#endif
}

static int ensure_api(const char *libusb_path) {
  if (g_api_ready) return 0;
  const char *path =
      (libusb_path && libusb_path[0]) ? libusb_path : default_libusb_name();
  fire_lib lib = FIRE_LOAD(path);
  if (!lib) return kFireUsbError;

  g_api.lib = lib;
  g_api.init = (fn_init)FIRE_SYM(lib, "libusb_init");
  g_api.exit = (fn_exit)FIRE_SYM(lib, "libusb_exit");
  g_api.get_device_list =
      (fn_get_device_list)FIRE_SYM(lib, "libusb_get_device_list");
  g_api.free_device_list =
      (fn_free_device_list)FIRE_SYM(lib, "libusb_free_device_list");
  g_api.get_device_descriptor =
      (fn_get_device_descriptor)FIRE_SYM(lib, "libusb_get_device_descriptor");
  g_api.get_active_config_descriptor =
      (fn_get_active_config_descriptor)FIRE_SYM(
          lib, "libusb_get_active_config_descriptor");
  g_api.get_config_descriptor =
      (fn_get_config_descriptor)FIRE_SYM(lib, "libusb_get_config_descriptor");
  g_api.free_config_descriptor =
      (fn_free_config_descriptor)FIRE_SYM(lib, "libusb_free_config_descriptor");
  g_api.get_bus_number =
      (fn_get_bus_number)FIRE_SYM(lib, "libusb_get_bus_number");
  g_api.get_device_address =
      (fn_get_device_address)FIRE_SYM(lib, "libusb_get_device_address");
  g_api.get_port_numbers =
      (fn_get_port_numbers)FIRE_SYM(lib, "libusb_get_port_numbers");
  g_api.open = (fn_open)FIRE_SYM(lib, "libusb_open");
  g_api.close = (fn_close)FIRE_SYM(lib, "libusb_close");
  g_api.claim_interface =
      (fn_claim_interface)FIRE_SYM(lib, "libusb_claim_interface");
  g_api.release_interface =
      (fn_release_interface)FIRE_SYM(lib, "libusb_release_interface");
  g_api.set_auto_detach_kernel_driver =
      (fn_set_auto_detach)FIRE_SYM(lib, "libusb_set_auto_detach_kernel_driver");
  g_api.get_configuration =
      (fn_get_configuration)FIRE_SYM(lib, "libusb_get_configuration");
  g_api.set_configuration =
      (fn_set_configuration)FIRE_SYM(lib, "libusb_set_configuration");
  g_api.get_string_descriptor_ascii =
      (fn_get_string_descriptor_ascii)FIRE_SYM(
          lib, "libusb_get_string_descriptor_ascii");
  g_api.get_device = (fn_get_device)FIRE_SYM(lib, "libusb_get_device");

  if (!g_api.init || !g_api.exit || !g_api.get_device_list ||
      !g_api.free_device_list || !g_api.get_device_descriptor ||
      !g_api.get_active_config_descriptor || !g_api.get_config_descriptor ||
      !g_api.free_config_descriptor || !g_api.get_bus_number ||
      !g_api.get_device_address || !g_api.get_port_numbers || !g_api.open ||
      !g_api.close || !g_api.claim_interface || !g_api.release_interface ||
      !g_api.set_auto_detach_kernel_driver || !g_api.get_configuration ||
      !g_api.set_configuration || !g_api.get_string_descriptor_ascii ||
      !g_api.get_device) {
    FIRE_UNLOAD(lib);
    memset(&g_api, 0, sizeof(g_api));
    return kFireUsbError;
  }
  g_api_ready = 1;
  return 0;
}

static fire_session *find_session(const char *port_path) {
  for (int i = 0; i < kMaxSessions; i++) {
    if (g_sessions[i].used &&
        strcmp(g_sessions[i].port_path, port_path) == 0) {
      return &g_sessions[i];
    }
  }
  return NULL;
}

static fire_session *alloc_session(void) {
  for (int i = 0; i < kMaxSessions; i++) {
    if (!g_sessions[i].used) return &g_sessions[i];
  }
  return NULL;
}

static void close_session(fire_session *session) {
  if (!session || !session->used) return;
  if (session->handle) {
    if (session->interface_number >= 0) {
      g_api.release_interface(session->handle, session->interface_number);
    }
    g_api.close(session->handle);
  }
  if (session->context) g_api.exit(session->context);
  memset(session, 0, sizeof(*session));
}

static int make_port_path(libusb_device *device, char *out, size_t out_size) {
  uint8_t ports[kMaxPorts];
  int bus = g_api.get_bus_number(device);
  int count = g_api.get_port_numbers(device, ports, kMaxPorts);
  if (count <= 0) {
    return snprintf(out, out_size, "%d-%d", bus,
                    g_api.get_device_address(device));
  }
  int written = snprintf(out, out_size, "%d-", bus);
  if (written < 0 || (size_t)written >= out_size) return -1;
  for (int i = 0; i < count; i++) {
    int part = snprintf(out + written, out_size - (size_t)written, "%s%d",
                        i == 0 ? "" : ".", ports[i]);
    if (part < 0) return -1;
    written += part;
    if ((size_t)written >= out_size) return -1;
  }
  return written;
}

static int is_adb_iface(uint8_t cls, uint8_t sub, uint8_t proto) {
  if (proto != kAdbProtocol) return 0;
  if (cls == kAdbClass && sub == kAdbSubclass) return 1;
  return cls == kDbcClass && sub == kDbcSubclass;
}

static int find_adb_match(const libusb_config_descriptor *config, int *iface,
                          int *ep_in, int *ep_out, int *max_packet) {
  for (int i = 0; i < config->bNumInterfaces; i++) {
    const libusb_interface *intf = &config->interface[i];
    if (intf->num_altsetting <= 0) continue;
    const libusb_interface_descriptor *alt = &intf->altsetting[0];
    if (!is_adb_iface(alt->bInterfaceClass, alt->bInterfaceSubClass,
                      alt->bInterfaceProtocol)) {
      continue;
    }
    int in = -1;
    int out = -1;
    int packet = 0;
    for (int e = 0; e < alt->bNumEndpoints; e++) {
      const libusb_endpoint_descriptor *ep = &alt->endpoint[e];
      if ((ep->bmAttributes & 0x03) != kBulk) continue;
      if ((ep->bEndpointAddress & kEndpointIn) != 0) {
        in = ep->bEndpointAddress;
        packet = ep->wMaxPacketSize & 0x07ff;
      } else {
        out = ep->bEndpointAddress;
        packet = ep->wMaxPacketSize & 0x07ff;
      }
    }
    if (in >= 0 && out >= 0) {
      *iface = alt->bInterfaceNumber;
      *ep_in = in;
      *ep_out = out;
      *max_packet = packet;
      return 1;
    }
  }
  return 0;
}

static int load_config(libusb_device *device, libusb_config_descriptor **out) {
  int code = g_api.get_active_config_descriptor(device, out);
  if (code == 0) return 0;
  return g_api.get_config_descriptor(device, 0, out);
}

static void fill_serial(libusb_device_handle *handle, char *out,
                        size_t out_size) {
  out[0] = '\0';
  libusb_device *device = g_api.get_device(handle);
  if (!device) return;
  libusb_device_descriptor desc;
  if (g_api.get_device_descriptor(device, &desc) != 0) return;
  if (desc.iSerialNumber == 0) return;
  unsigned char buffer[256];
  int length = g_api.get_string_descriptor_ascii(
      handle, desc.iSerialNumber, buffer, (int)sizeof(buffer) - 1);
  if (length <= 0) return;
  if ((size_t)length >= out_size) length = (int)out_size - 1;
  memcpy(out, buffer, (size_t)length);
  out[length] = '\0';
}

FIRE_USB_API int fire_usb_close(const char *port_path) {
  if (!port_path || !port_path[0]) return kFireUsbError;
  if (!g_api_ready) return 0;
  fire_session *session = find_session(port_path);
  if (!session) return 0;
  close_session(session);
  return 1;
}

FIRE_USB_API int fire_usb_close_all(void) {
  if (!g_api_ready) return 0;
  int closed = 0;
  for (int i = 0; i < kMaxSessions; i++) {
    if (!g_sessions[i].used) continue;
    close_session(&g_sessions[i]);
    closed++;
  }
  return closed;
}

FIRE_USB_API int fire_usb_is_open(const char *port_path) {
  if (!port_path) return 0;
  return find_session(port_path) != NULL;
}

FIRE_USB_API int fire_usb_open(const char *libusb_path, const char *port_path,
                               fire_usb_info *out) {
  if (!port_path || !port_path[0] || !out) return kFireUsbError;
  int loaded = ensure_api(libusb_path);
  if (loaded != 0) return loaded;

  /* Close leftover session from a previous isolate, then open. */
  fire_usb_close(port_path);

  libusb_context *context = NULL;
  int code = g_api.init(&context);
  if (code != 0) return code;

  libusb_device **list = NULL;
  fire_ssize count = g_api.get_device_list(context, &list);
  if (count < 0) {
    g_api.exit(context);
    return (int)count;
  }

  libusb_device *matched = NULL;
  int iface = -1;
  int ep_in = -1;
  int ep_out = -1;
  int max_packet = 0;
  char path[128];

  for (fire_ssize i = 0; i < count; i++) {
    libusb_device *device = list[i];
    if (make_port_path(device, path, sizeof(path)) < 0) continue;
    if (strcmp(path, port_path) != 0) continue;
    libusb_config_descriptor *config = NULL;
    if (load_config(device, &config) != 0) continue;
    int ok = find_adb_match(config, &iface, &ep_in, &ep_out, &max_packet);
    g_api.free_config_descriptor(config);
    if (!ok) continue;
    matched = device;
    break;
  }

  if (!matched) {
    g_api.free_device_list(list, 1);
    g_api.exit(context);
    return kFireUsbError;
  }

  libusb_device_handle *handle = NULL;
  code = g_api.open(matched, &handle);
  g_api.free_device_list(list, 1);
  if (code != 0) {
    g_api.exit(context);
    return code;
  }

  g_api.set_auto_detach_kernel_driver(handle, 1);
  int configuration = 0;
  if (g_api.get_configuration(handle, &configuration) == 0 &&
      configuration == 0) {
    g_api.set_configuration(handle, 1);
  }
  code = g_api.claim_interface(handle, iface);
  if (code != 0) {
    g_api.close(handle);
    g_api.exit(context);
    return code;
  }

  fire_session *session = alloc_session();
  if (!session) {
    g_api.release_interface(handle, iface);
    g_api.close(handle);
    g_api.exit(context);
    return kFireUsbError;
  }
  session->used = 1;
  session->context = context;
  session->handle = handle;
  session->interface_number = iface;
  snprintf(session->port_path, sizeof(session->port_path), "%s", port_path);

  memset(out, 0, sizeof(*out));
  out->context = context;
  out->handle = handle;
  out->interface_number = iface;
  out->endpoint_in = ep_in;
  out->endpoint_out = ep_out;
  out->max_packet_size = max_packet;
  snprintf(out->port_path, sizeof(out->port_path), "%s", port_path);
  fill_serial(handle, out->serial, sizeof(out->serial));
  return 0;
}

/* Matches libusb 1.0 transfer layout on Win64 / LP64 (size 64, buffer @48). */
typedef struct fire_libusb_transfer {
  void *dev_handle;
  uint8_t flags;
  unsigned char endpoint;
  unsigned char type;
  unsigned int timeout;
  int status;
  int length;
  int actual_length;
  void *callback;
  void *user_data;
  unsigned char *buffer;
  int num_iso_packets;
} fire_libusb_transfer;

FIRE_USB_API void fire_usb_transfer_cb(void *transfer) {
  fire_libusb_transfer *t = (fire_libusb_transfer *)transfer;
  fire_usb_transfer_slot *slot;
  if (t == NULL) {
    return;
  }
  slot = (fire_usb_transfer_slot *)t->user_data;
  if (slot == NULL) {
    return;
  }
  slot->status = t->status;
  slot->actual = t->actual_length;
  slot->ready = 1;
}

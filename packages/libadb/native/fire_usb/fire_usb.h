#ifndef FIRE_USB_H_
#define FIRE_USB_H_

#ifdef _WIN32
#ifdef FIRE_USB_BUILD
#define FIRE_USB_API __declspec(dllexport)
#else
#define FIRE_USB_API __declspec(dllimport)
#endif
#else
#define FIRE_USB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opened session. Handles are owned by this library. */
typedef struct fire_usb_info {
  void *context;       /* libusb_context* */
  void *handle;        /* libusb_device_handle* */
  int interface_number;
  int endpoint_in;
  int endpoint_out;
  int max_packet_size;
  char serial[256];
  char port_path[128];
} fire_usb_info;

/*
 * Open and claim the ADB interface for port_path.
 * Closes any existing session for the same path first (hot-restart reclaim).
 * Returns 0 on success, libusb error (negative) or -1000 on load/arg failure.
 */
FIRE_USB_API int fire_usb_open(const char *libusb_path,
                               const char *port_path,
                               fire_usb_info *out);

/* Returns 1 if a session was closed, 0 if none, negative on error. */
FIRE_USB_API int fire_usb_close(const char *port_path);
/* Returns how many sessions were closed. */
FIRE_USB_API int fire_usb_close_all(void);
FIRE_USB_API int fire_usb_is_open(const char *port_path);

/*
 * Completion slot for async bulk transfers. user_data of libusb_transfer
 * points here. Filled only from fire_usb_transfer_cb (C, same thread as
 * libusb_handle_events) — no Dart reentry during the FFI block.
 */
typedef struct fire_usb_transfer_slot {
  int ready;
  int status;
  int actual;
} fire_usb_transfer_slot;

/* libusb_transfer_cb_fn. Pass as transfer->callback. */
FIRE_USB_API void fire_usb_transfer_cb(void *transfer);

#ifdef __cplusplus
}
#endif

#endif /* FIRE_USB_H_ */

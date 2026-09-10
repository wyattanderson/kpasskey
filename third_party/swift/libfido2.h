#include <fido.h>
#include <fido/es256.h>

// libfido2 has no public vendor-command API. These declarations expose the
// bundled static library's existing transport routines (src/extern.h), avoiding
// a second HID implementation. Verify these signatures when upgrading libfido2.
// No C implementation or interoperability shim is needed; Swift calls them.
int fido_tx(fido_dev_t *, uint8_t, const void *, size_t, int *);
int fido_rx(fido_dev_t *, uint8_t, void *, size_t, int *);

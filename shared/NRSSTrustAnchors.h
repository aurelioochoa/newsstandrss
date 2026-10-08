#include <stddef.h>
#include "bearssl.h"

// Root certificates for the BearSSL fallback (generated, see scripts/make-trust-anchors.py).
extern const br_x509_trust_anchor NRSSTrustAnchors[];
extern const size_t NRSSTrustAnchorCount;

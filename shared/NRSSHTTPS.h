#ifndef NRSS_HTTPS_H
#define NRSS_HTTPS_H

#include <stddef.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// One HTTPS GET over BearSSL (TLS 1.2 with AES-GCM / ChaCha20, which iOS 6's own TLS lacks).
// Bodies are de-chunked and gunzipped. Redirects are not followed; the caller sees status and location.
typedef struct {
    int status;
    char *location;      // malloc'd Location header, or NULL
    char *content_type;  // malloc'd Content-Type header, or NULL
    unsigned char *body; // malloc'd, body_length bytes
    size_t body_length;
    char error[160];     // set when the call returns non-zero
} nrss_https_response;

int nrss_https_get(const char *host, int port, const char *target, const char *user_agent, const char *accept,
                   size_t max_body, int timeout_seconds, nrss_https_response *response);
void nrss_https_response_free(nrss_https_response *response);

__END_DECLS

#endif

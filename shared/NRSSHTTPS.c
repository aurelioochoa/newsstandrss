#include "NRSSHTTPS.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <zlib.h>
#include "bearssl.h"
#include "NRSSTrustAnchors.h"

typedef struct {
    unsigned char *data;
    size_t length, capacity;
} nrss_buffer;

static int nrss_append(nrss_buffer *buffer, const void *bytes, size_t length) {
    if (buffer->length + length + 1 > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 16384;
        while (capacity < buffer->length + length + 1)
            capacity *= 2;
        unsigned char *data = realloc(buffer->data, capacity);
        if (!data)
            return -1;
        buffer->data = data;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, bytes, length);
    buffer->length += length;
    buffer->data[buffer->length] = 0;
    return 0;
}

static int nrss_fail(nrss_https_response *response, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(response->error, sizeof response->error, format, arguments);
    va_end(arguments);
    return -1;
}

static int nrss_connect(const char *host, int port, int timeout, nrss_https_response *response) {
    struct addrinfo hints, *list = NULL, *address;
    char service[8];
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(service, sizeof service, "%d", port);
    if (getaddrinfo(host, service, &hints, &list) != 0 || !list) {
        nrss_fail(response, "Could not find the server %s.", host);
        return -1;
    }
    int fd = -1;
    for (address = list; address && fd < 0; address = address->ai_next) {
        fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0)
            continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int connected = connect(fd, address->ai_addr, address->ai_addrlen) == 0;
        if (!connected && errno == EINPROGRESS) {
            struct pollfd waiter = {fd, POLLOUT, 0};
            int error = 0;
            socklen_t length = sizeof error;
            connected = poll(&waiter, 1, timeout * 1000) == 1
                && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
        }
        if (!connected) {
            close(fd);
            fd = -1;
            continue;
        }
        fcntl(fd, F_SETFL, flags);
        struct timeval limit = {timeout, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof limit);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof limit);
    }
    freeaddrinfo(list);
    if (fd < 0)
        nrss_fail(response, "Could not connect to %s.", host);
    return fd;
}

static int nrss_socket_read(void *context, unsigned char *bytes, size_t length) {
    for (;;) {
        ssize_t count = read(*(int *)context, bytes, length);
        if (count > 0)
            return (int)count;
        if (count < 0 && errno == EINTR)
            continue;
        return -1;
    }
}

static int nrss_socket_write(void *context, const unsigned char *bytes, size_t length) {
    for (;;) {
        ssize_t count = write(*(int *)context, bytes, length);
        if (count > 0)
            return (int)count;
        if (count < 0 && errno == EINTR)
            continue;
        return -1;
    }
}

static char *nrss_header(const char *headers, const char *name) {
    size_t name_length = strlen(name);
    for (const char *line = strstr(headers, "\r\n"); line && line[2] && !(line[2] == '\r' && line[3] == '\n');
         line = strstr(line + 2, "\r\n")) {
        const char *start = line + 2;
        if (strncasecmp(start, name, name_length) != 0 || start[name_length] != ':')
            continue;
        const char *value = start + name_length + 1;
        while (*value == ' ' || *value == '\t')
            value++;
        const char *end = strstr(value, "\r\n");
        size_t length = end ? (size_t)(end - value) : strlen(value);
        while (length && (value[length - 1] == ' ' || value[length - 1] == '\t'))
            length--;
        char *copy = malloc(length + 1);
        if (copy) {
            memcpy(copy, value, length);
            copy[length] = 0;
        }
        return copy;
    }
    return NULL;
}

// Returns 1 when a chunked body is complete, -1 when malformed, 0 when more data is needed.
static int nrss_dechunk(const unsigned char *bytes, size_t length, nrss_buffer *out, size_t max_body) {
    size_t position = 0;
    out->length = 0;
    for (;;) {
        const unsigned char *line_end = memchr(bytes + position, '\n', length - position);
        if (!line_end)
            return 0;
        unsigned long size = strtoul((const char *)bytes + position, NULL, 16);
        position = (size_t)(line_end - bytes) + 1;
        if (size == 0)
            return 1;
        if (size > max_body || out->length + size > max_body)
            return -1;
        if (position + size + 2 > length)
            return 0;
        if (nrss_append(out, bytes + position, size) != 0)
            return -1;
        position += size + 2;
    }
}

static int nrss_gunzip(const unsigned char *bytes, size_t length, nrss_buffer *out, size_t max_body) {
    z_stream stream;
    memset(&stream, 0, sizeof stream);
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK)
        return -1;
    stream.next_in = (Bytef *)bytes;
    stream.avail_in = (uInt)length;
    unsigned char chunk[16384];
    int status;
    do {
        stream.next_out = chunk;
        stream.avail_out = sizeof chunk;
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END)
            break;
        if (nrss_append(out, chunk, sizeof chunk - stream.avail_out) != 0 || out->length > max_body) {
            status = Z_MEM_ERROR;
            break;
        }
    } while (status != Z_STREAM_END && stream.avail_in > 0);
    inflateEnd(&stream);
    return status == Z_STREAM_END || (status == Z_OK && out->length) ? 0 : -1;
}

int nrss_https_get(const char *host, int port, const char *target, const char *user_agent, const char *accept,
                   size_t max_body, int timeout_seconds, nrss_https_response *response) {
    memset(response, 0, sizeof *response);
    int fd = nrss_connect(host, port, timeout_seconds, response);
    if (fd < 0)
        return -1;

    int result = -1;
    nrss_buffer raw = {0}, decoded = {0};
    char *request = NULL, *encoding = NULL, *transfer = NULL, *length_header = NULL;
    br_ssl_client_context *client = calloc(1, sizeof *client);
    br_x509_minimal_context *validator = calloc(1, sizeof *validator);
    unsigned char *io_buffer = malloc(BR_SSL_BUFSIZE_BIDI);
    if (!client || !validator || !io_buffer) {
        nrss_fail(response, "Out of memory.");
        goto done;
    }
    br_ssl_client_init_full(client, validator, NRSSTrustAnchors, NRSSTrustAnchorCount);
    br_ssl_engine_set_buffer(&client->eng, io_buffer, BR_SSL_BUFSIZE_BIDI, 1);
    if (!br_ssl_client_reset(client, host, 0)) {
        nrss_fail(response, "TLS setup failed (%d).", br_ssl_engine_last_error(&client->eng));
        goto done;
    }
    br_sslio_context io;
    br_sslio_init(&io, &client->eng, nrss_socket_read, &fd, nrss_socket_write, &fd);

    char host_header[300];
    if (port == 443)
        snprintf(host_header, sizeof host_header, "%s", host);
    else
        snprintf(host_header, sizeof host_header, "%s:%d", host, port);
    int request_length = asprintf(&request, "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nAccept: %s\r\n"
                                  "Accept-Encoding: gzip\r\nConnection: close\r\n\r\n", target, host_header, user_agent, accept);
    if (request_length < 0 || br_sslio_write_all(&io, request, (size_t)request_length) != 0 || br_sslio_flush(&io) != 0) {
        nrss_fail(response, "A secure connection to %s could not be made (TLS error %d).", host, br_ssl_engine_last_error(&client->eng));
        goto done;
    }

    // Read until the body is complete by its framing, or the server closes the connection.
    size_t header_end = 0;
    long content_length = -1;
    int chunked = 0;
    unsigned char chunk[8192];
    for (;;) {
        int count = br_sslio_read(&io, chunk, sizeof chunk);
        if (count <= 0)
            break;
        if (nrss_append(&raw, chunk, (size_t)count) != 0 || raw.length > max_body + 65536) {
            nrss_fail(response, "The download is too large.");
            goto done;
        }
        if (!header_end) {
            unsigned char *end = (unsigned char *)strstr((const char *)raw.data, "\r\n\r\n");
            if (!end)
                continue;
            header_end = (size_t)(end - raw.data) + 4;
            raw.data[header_end - 2] = 0; // terminate the header block for parsing; restored below
            length_header = nrss_header((const char *)raw.data, "Content-Length");
            transfer = nrss_header((const char *)raw.data, "Transfer-Encoding");
            raw.data[header_end - 2] = '\r';
            content_length = length_header ? strtol(length_header, NULL, 10) : -1;
            chunked = transfer && strcasestr(transfer, "chunked");
        }
        if (content_length >= 0 && !chunked && raw.length - header_end >= (size_t)content_length)
            break;
        if (chunked && raw.length >= header_end + 5 && memcmp(raw.data + raw.length - 5, "0\r\n\r\n", 5) == 0)
            break;
    }
    if (!header_end) {
        int error = br_ssl_engine_last_error(&client->eng);
        nrss_fail(response, error ? "A secure connection to %s could not be made (TLS error %d)." : "%s closed the connection.", host, error);
        goto done;
    }

    raw.data[header_end - 2] = 0;
    const char *headers = (const char *)raw.data;
    if (sscanf(headers, "HTTP/%*d.%*d %d", &response->status) != 1) {
        nrss_fail(response, "%s sent an invalid response.", host);
        goto done;
    }
    response->location = nrss_header(headers, "Location");
    response->content_type = nrss_header(headers, "Content-Type");
    encoding = nrss_header(headers, "Content-Encoding");

    const unsigned char *body = raw.data + header_end;
    size_t body_length = raw.length - header_end;
    nrss_buffer dechunked = {0};
    if (chunked) {
        if (nrss_dechunk(body, body_length, &dechunked, max_body) != 1) {
            free(dechunked.data);
            nrss_fail(response, "The download from %s was incomplete.", host);
            goto done;
        }
        body = dechunked.data;
        body_length = dechunked.length;
    } else if (content_length >= 0) {
        if (body_length < (size_t)content_length) {
            nrss_fail(response, "The download from %s was incomplete.", host);
            goto done;
        }
        body_length = (size_t)content_length;
    }
    if (encoding && strcasestr(encoding, "gzip")) {
        int status = nrss_gunzip(body, body_length, &decoded, max_body);
        free(dechunked.data);
        if (status != 0) {
            nrss_fail(response, "The download from %s could not be decompressed.", host);
            goto done;
        }
        response->body = decoded.data;
        response->body_length = decoded.length;
        decoded.data = NULL;
    } else {
        if (body_length > max_body) {
            free(dechunked.data);
            nrss_fail(response, "The download is too large.");
            goto done;
        }
        response->body = malloc(body_length + 1);
        if (response->body) {
            memcpy(response->body, body, body_length);
            response->body[body_length] = 0;
            response->body_length = body_length;
        }
        free(dechunked.data);
    }
    result = response->body || !body_length ? 0 : nrss_fail(response, "Out of memory.");

done:
    close(fd);
    free(request);
    free(encoding);
    free(transfer);
    free(length_header);
    free(raw.data);
    free(decoded.data);
    free(io_buffer);
    free(validator);
    free(client);
    return result;
}

void nrss_https_response_free(nrss_https_response *response) {
    free(response->location);
    free(response->content_type);
    free(response->body);
    memset(response, 0, sizeof *response);
}

#ifndef CLIO_ZSTD_H
#define CLIO_ZSTD_H

#include <stddef.h>

typedef struct ZSTD_DCtx_s ZSTD_DStream;

typedef struct {
    const void *src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct {
    void *dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

ZSTD_DStream *ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream *stream);
size_t ZSTD_DStreamOutSize(void);
size_t ZSTD_decompressStream(ZSTD_DStream *stream, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
unsigned ZSTD_isError(size_t code);

#endif

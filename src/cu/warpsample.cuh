#ifndef GPLDA_WARPSAMPLER_H
#define GPLDA_WARPSAMPLER_H

#include "stdint.h"

namespace gplda {

__global__ void compute_d_idx(uint32_t* d_len, uint32_t* d_idx, size_t n_docs);

__global__ void warp_sample_topics(size_t size, uint32_t n_docs, uint32_t *z, uint32_t *w, uint32_t *d_len, uint32_t *d_idx);

}

#endif

// src/prefill/group_gpu.cu - STRATA_PF_GROUP_GPU=1: the MoE grouping of a streamed prompt chunk computed on the GPU
// instead of on the host.  The MMQ path used to download the chunk's routed ids (T*K int32), count, prefix-sum and
// scatter them on one host core and upload slot/src back - one stream synchronize per layer with the GPU idle, which
// measured 28.9% of prompt time on 2x Tesla P40 (Xeon E5-2620 v4, 2026-11-02).  Here the same three tables are built
// by the kernels below; the host downloads only the expert counts (n_expert int32, 2 KiB) to size its groups and
// bounds, while the quantize/gather chain is already enqueued.  slot/src keep the exact consumer contract (the rows
// of one expert form [off(e), off(e)+cnt(e)), the order within an expert is whatever the atomics give: every reader
// finds a row's expert through the bounds or through slot[i], and the combine still adds a token's K rows in rank
// order, so the outputs are bit-identical to the host grouping.
#include "strata/prefill/group_gpu.hpp"

#include <cuda_runtime.h>

#include <algorithm>

namespace strata::prefill::gpu_group {

namespace {

__global__ void hist_kernel(const int32_t* __restrict__ ids, int64_t n, int ne, int32_t* __restrict__ cnt) {
    extern __shared__ int sh[];
    for (int i = threadIdx.x; i < ne; i += blockDim.x) sh[i] = 0;
    __syncthreads();
    const int64_t stride = (int64_t) gridDim.x * blockDim.x;
    for (int64_t i = (int64_t) blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride) {
        const int32_t e = ids[i];
        if (e >= 0 && e < ne) atomicAdd(&sh[e], 1);
    }
    __syncthreads();
    for (int i = threadIdx.x; i < ne; i += blockDim.x) if (sh[i]) atomicAdd(&cnt[i], sh[i]);
}

// the prefix sums of <= 1024 counts: one thread, sequential - a couple of microseconds, and it keeps `fill`
// (the scatter's cursor) starting exactly at off.
__global__ void scan_kernel(const int32_t* __restrict__ cnt, int ne, int32_t* __restrict__ off,
                            int32_t* __restrict__ fill) {
    int64_t run = 0;
    for (int i = 0; i < ne; ++i) {
        off[i] = (int32_t) run;
        fill[i] = (int32_t) run;
        run += cnt[i];
    }
    off[ne] = (int32_t) run;   // the total, for the caller's sum check
}

__global__ void scatter_kernel(const int32_t* __restrict__ ids, int64_t n, int k, int ne, int32_t* __restrict__ fill,
                               int32_t* __restrict__ slot, int32_t* __restrict__ src) {
    const int64_t stride = (int64_t) gridDim.x * blockDim.x;
    for (int64_t i = (int64_t) blockIdx.x * blockDim.x + threadIdx.x; i < n; i += stride) {
        const int32_t e = ids[i];
        if (e < 0 || e >= ne) continue;   // hist stayed quiet about it too: the caller's sum check catches it
        const int32_t p = atomicAdd(&fill[e], 1);
        slot[i] = p;
        src[p] = (int32_t) (i / k);
    }
}

}  // namespace

bool group_on_gpu(const int32_t* ids, int64_t n, int k, int n_expert, int32_t* cnt_dev, int32_t* off_dev,
                  int32_t* fill_dev, int32_t* slot, int32_t* src, int nsm, void* stream) {
    if (n <= 0 || n_expert <= 0 || n_expert > kMaxExpert) return false;
    const cudaStream_t s = (cudaStream_t) stream;
    cudaMemsetAsync(cnt_dev, 0, (size_t) n_expert * sizeof(int32_t), s);
    const unsigned hb = (unsigned) std::min<int64_t>((n + 1023) / 1024, 4 * (int64_t) std::max(nsm, 1));
    hist_kernel<<<hb, 256, (size_t) n_expert * sizeof(int), s>>>(ids, n, n_expert, cnt_dev);
    scan_kernel<<<1, 1, 0, s>>>(cnt_dev, n_expert, off_dev, fill_dev);
    const unsigned sb = (unsigned) std::min<int64_t>((n + 255) / 256, 8 * (int64_t) std::max(nsm, 1));
    scatter_kernel<<<sb, 256, 0, s>>>(ids, n, k, n_expert, fill_dev, slot, src);
    return cudaGetLastError() == cudaSuccess;
}

}  // namespace strata::prefill::gpu_group

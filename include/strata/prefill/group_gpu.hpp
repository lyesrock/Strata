// include/strata/prefill/group_gpu.hpp - STRATA_PF_GROUP_GPU=1: build the prompt path's MoE grouping tables (expert
// counts, offsets, the slot/src scatter) on the GPU instead of downloading the routed ids and sorting on the host.
// See src/prefill/group_gpu.cu for the contract and why the outputs stay bit-identical to the host grouping.
#pragma once

#include <cstdint>

namespace strata::prefill::gpu_group {

constexpr int kMaxExpert = 1024;   // the scan kernel's one-thread reach (the model families stop at 512)

/// One stream-ordered chain on `stream`: zero the counts, histogram `ids` (n = tokens * K entries, ids in token-
/// major, K a token's expert ids), prefix-sum into off_dev/fill_dev, and scatter so slot[i] is i's row inside its
/// expert's block and src[slot[i]] = i / k.  The caller reads cnt_dev back (n_expert int32, plus off_dev[n_expert]
/// as the total) to build its group bounds, and checks the total against n.  `nsm` sizes the grids.  False when the
/// launches failed or n_expert is out of reach.
bool group_on_gpu(const int32_t* ids, int64_t n, int k, int n_expert, int32_t* cnt_dev, int32_t* off_dev,
                  int32_t* fill_dev, int32_t* slot, int32_t* src, int nsm, void* stream);

}  // namespace strata::prefill::gpu_group

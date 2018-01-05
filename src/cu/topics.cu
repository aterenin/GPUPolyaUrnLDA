#include "topics.cuh"

namespace gpulda {

__global__ void compute_d_idx(u32* d_len, u32* d_idx, u32 n_docs) {
  typedef cub::BlockScan<i32, GPULDA_COMPUTE_D_IDX_BLOCKDIM> BlockScan;
  __shared__ typename BlockScan::TempStorage temp;

  if(blockIdx.x == 0) {
    i32 thread_d;
    i32 initial_value = 0;
    i32 total_value;
    for(i32 offset = 0; offset < n_docs / blockDim.x + 1; ++offset) {
      i32 i = threadIdx.x + offset * blockDim.x;
      if(i < n_docs) {
        thread_d = d_len[i];
      } else {
        thread_d = 0;
      }

      BlockScan(temp).ExclusiveScan(thread_d, thread_d, 0, cub::Sum(), total_value);

      // workaround for CUB bug: apply offset manually
      __syncthreads();
      thread_d = thread_d + initial_value;
      initial_value = total_value + initial_value;

      if(i < n_docs) {
        d_idx[i] = thread_d;
      }
    }
  }
}




__global__ void sample_topics(u32 size, u32 n_docs,
    u32* z, u32* w, u32* d_len, u32* d_idx, u32* K_d, u64* hash, f32* mPhi,
    u32 K, u32 V, u32 max_N_d,
    f32* Phi_dense, f32* sigma_a,
    f32** prob, u32** alias, u32 table_size, curandStatePhilox4_32_10_t* rng) {
  // initialize variables
  i32 lane_idx = threadIdx.x % warpSize;
  // i32 warp_idx = threadIdx.x / warpSize;
  curandStatePhilox4_32_10_t warp_rng = rng[0];
  __shared__ HashMap m[1];
  __shared__ typename cub::WarpScan<f32>::TempStorage warp_scan_temp[1];

  // loop over documents
  for(i32 i = 0; i < n_docs; ++i) {
    // count topics in document
    u32 warp_d_len = d_len[i];
    u32 warp_d_idx = d_idx[i];
    __syncthreads(); // ensure init has finished
    count_topics(z + warp_d_idx * sizeof(u32), warp_d_len, m, lane_idx);
    //
    // loop over words
    for(i32 j = 0; j < warp_d_len; ++j) {
      // load z,w from global memory
      u32 warp_z = z[warp_d_idx + j];
      u32 warp_w = w[warp_d_idx + j];

      // remove current z from sufficient statistic
      m->insert2(warp_z, lane_idx < 16 ? -1 : 0); // don't branch

      // compute m*phi and sigma_b
      f32 warp_sigma_a = sigma_a[warp_w];
      f32 sigma_b = compute_product_cumsum(mPhi, m, Phi_dense, lane_idx, warp_scan_temp);

      // update z
      f32 u1 = curand_uniform(&warp_rng);
      f32 u2 = curand_uniform(&warp_rng);
      if(u1 * (warp_sigma_a + sigma_b) > warp_sigma_a) {
        // sample from m*Phi
        warp_z = draw_wary_search(u2, m, mPhi, sigma_b, lane_idx);
      } else {
        // sample from alias table
        warp_z = draw_alias(u2, prob[warp_w], alias[warp_w], table_size, lane_idx); // TODO: fix this
      }
  constexpr u32 ring_buffer_size = (GPULDA_SAMPLE_TOPICS_BLOCKDIM/16)*2;
  __shared__ u64 ring_buffer[ring_buffer_size];
  __shared__ u32 ring_buffer_queue[ring_buffer_size];
  m->init(hash, 2*max_N_d, max_N_d, ring_buffer, ring_buffer_queue, ring_buffer_size, &block_rng, blockDim.x);

      // add new z to sufficient statistic
      m->insert2(warp_z, lane_idx < 16 ? 1 : 0); // don't branch
      if(lane_idx == 0) {
        z[warp_d_idx + j] = warp_z;
      }
    }
  }
}

}

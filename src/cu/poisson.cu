#include "assert.h"
#include "error.cuh"
#include "poisson.cuh"
#include "train.cuh"

namespace gplda {


__device__ __forceinline__ unsigned int warp_lane_id_bits(int lane_idx) {
  return ((unsigned int) 1) << lane_idx;
}

__device__ __forceinline__ unsigned int warp_lane_offset(unsigned int lane_bits) {
  return __popc((~(((unsigned int) 4294967295) << (threadIdx.x % 32))) & lane_bits);
}

__device__ __forceinline__ int queue_wraparound(int idx) {
  return idx;
}

__device__ __forceinline__ void warp_queue_pair_push(int value, int conditional, int* q1, int* q2, int* q1_end, int* q2_end) {
  // determine which threads write to which queue
  unsigned int warp_q1_bits = __ballot(conditional);
  unsigned int warp_q2_bits = __ballot(~conditional); // note: some threads may be inactive
  // determine how many writes are in the warp's view for each queue
  int warp_num_q1 = __popc(warp_q1_bits);
  int warp_num_q2 = __popc(warp_q2_bits);
  // increment the queue's size, only once per warp, then broadcast to all lanes in the warp
  int warp_q1_start;
  int warp_q2_start;
  if(threadIdx.x % 32 == 0) {
    warp_q1_start = atomicAdd(q1_end, warp_num_q1);
    warp_q2_start = atomicAdd(q2_end, warp_num_q2);
  }
  warp_q1_start = __shfl(warp_q1_start, 0);
  warp_q2_start = __shfl(warp_q2_start, 0);
  // if current thread has elements, determine where to write them
  int* write_queue;
  int write_idx;
  if(conditional) {
    write_queue = q1;
    write_idx = warp_q1_start + warp_lane_offset(warp_q1_bits);
  } else {
    write_queue = q2;
    write_idx = warp_q2_start + warp_lane_offset(warp_q2_bits);
  }
  // write elements to both queues
  write_queue[queue_wraparound(write_idx)] = value;
}

__device__ __forceinline__ int warp_queue_pair_pop(int& size, int* start, int* end1, int* end2) {
  return 1;
}

__global__ void build_poisson(float** prob, float** alias, float beta, int table_size) {
  assert(blockDim.x % 32 == 0); // kernel will fail if warpSize != 32
  int warp_idx = threadIdx.x / warpSize;
  int num_warps = blockDim.x / warpSize + 1;
  int lane_idx = threadIdx.x % warpSize;
  // determine constants
  int lambda = blockIdx.x; // each block builds one table
  float L = lambda + beta;
  float cutoff = 1.0/((float) table_size);
  // populate PMF
  for(int offset = 0; offset < table_size / blockDim.x + 1; ++offset) {
    int i = threadIdx.x + offset * blockDim.x;
    float x = i;
    if(i < table_size) {
      prob[lambda][i] = expf(x*logf(L) - L - lgammaf(x + 1));
    }
  }
  __syncthreads();
  // initialize queues
  __shared__ int num_active_warps[1];
  __shared__ int queue_pair_start[1];
  /*extern*/ __shared__ int large[200];
  __shared__ int large_end[1];
  /*extern*/ __shared__ int small[200];
  __shared__ int small_end[1];
  if(threadIdx.x == 0) {
    num_active_warps[0] = num_warps;
    queue_pair_start[0] = 0;
    large_end[0] = 0;
    small_end[0] = 0;
  }
  __syncthreads();
  // loop over PMF, build large queue
  for(int offset = 0; offset < table_size / blockDim.x + 1; ++offset) {
    int i = threadIdx.x + offset * blockDim.x;
    if(i < table_size) {
      float thread_prob = prob[lambda][i];
      warp_queue_pair_push(i, thread_prob >= cutoff, large, large_end, small, small_end);
    }
  }

  // grab a set of indices from both queues for the warp to work on
  for(int warp_num_elements = warpSize; warp_num_elements > 0; /*no increment*/) {
    // try to grab an index, determine how many were grabbed
    warp_num_elements = warpSize;
    int warp_queue_idx = warp_queue_pair_pop(warp_num_elements, queue_pair_start, large_end, small_end);
    // if got an index, fill it
    if(lane_idx < warp_num_elements) {
      int thread_large_idx = large[queue_wraparound(warp_queue_idx + lane_idx)];
      float thread_large_prob = prob[lambda][thread_large_idx];
      int thread_small_idx = small[queue_wraparound(warp_queue_idx + lane_idx)];
      float thread_small_prob = prob[lambda][thread_small_idx];
      // determine new probability and fill the index
      thread_large_prob = (thread_large_prob + thread_small_prob) - 1.0;
      alias[lambda][thread_small_idx] = thread_large_idx;
      // if large prob became small, write it to its corresponding slot
      if(thread_large_prob < cutoff) {
        prob[lambda][thread_large_idx] = thread_large_prob;
      }
      // finally, push remaining values back onto queues
      warp_queue_pair_push(thread_large_idx, thread_large_prob >= cutoff, large, large_end, small, small_end);
    }
  }
  // at this point, both queues should now be near empty, so finish them using one warp
  if(atomicSub(num_active_warps, 1) == 1) {
    printf("Finishing remaining values");
  }
}


__global__ void draw_poisson(float** prob, float** alias, int* lambda, int n) {
}

Poisson::Poisson(int ml, int mv) {
  // assign class parameters
  max_lambda = ml;
  max_value = mv;
  // allocate array of pointers on host first, so cudaMalloc can populate it
  float** prob_host = new float*[max_lambda];
  float** alias_host = new float*[max_lambda];
  // allocate each Alias table
  for(size_t i = 0; i < max_lambda; ++i) {
    cudaMalloc(&prob_host[i], max_value * sizeof(float)) >> GPLDA_CHECK;
    cudaMalloc(&alias_host[i], max_value * sizeof(float)) >> GPLDA_CHECK;
  }
  // now, allocate array of pointers on device
  cudaMalloc(&prob, max_lambda * sizeof(float*)) >> GPLDA_CHECK;
  cudaMalloc(&alias, max_lambda * sizeof(float*)) >> GPLDA_CHECK;
  // copy array of pointers to device
  cudaMemcpy(prob, prob_host, max_lambda * sizeof(float*), cudaMemcpyHostToDevice) >> GPLDA_CHECK;
  cudaMemcpy(alias, alias_host, max_lambda * sizeof(float*), cudaMemcpyHostToDevice) >> GPLDA_CHECK;
  // deallocate array of pointers on host
  delete[] prob_host;
  delete[] alias_host;
  // launch kernel to build the alias tables
  build_poisson<<</*max_lambda*/1,96/*32*/,max_value*sizeof(int)>>>(prob, alias, ARGS->beta, max_value);
  cudaDeviceSynchronize();
}

Poisson::~Poisson() {
  // allocate array of pointers on host, so we can dereference it
  float** prob_host = new float*[max_lambda];
  float** alias_host = new float*[max_lambda];
  // copy array of pointers to host
  cudaMemcpy(prob_host, prob, max_lambda * sizeof(float*), cudaMemcpyDeviceToHost) >> GPLDA_CHECK;
  cudaMemcpy(alias_host, alias, max_lambda * sizeof(float*), cudaMemcpyDeviceToHost) >> GPLDA_CHECK;
  // free the memory at the arrays being pointed to
  for(size_t i = 0; i < max_lambda; ++i) {
    cudaFree(prob_host[i]) >> GPLDA_CHECK;
    cudaFree(alias_host[i]) >> GPLDA_CHECK;
  }
  // free the memory of the pointer array on device
  cudaFree(prob) >> GPLDA_CHECK;
  cudaFree(alias) >> GPLDA_CHECK;
  // deallocate array of pointers on host
  delete[] prob_host;
  delete[] alias_host;
}

}

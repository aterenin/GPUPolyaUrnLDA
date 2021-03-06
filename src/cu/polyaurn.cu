#include "polyaurn.cuh"
#include "assert.h"
#include "error.cuh"

namespace gpulda {

__device__ __forceinline__ f32 draw_poisson(f32 u, f32 beta, u32 n,
    f32** prob, u32** alias, u32 max_lambda, u32 max_value) {
  // MUST be defined in this file to compile on all platforms

  // if below cutoff, draw using Alias table
  if(n < max_lambda) {
    // determine the slot and update random number
    f32 mv = (f32) max_value;
    u32 slot = (u32) (u * mv);
    u = fmodf(u, __frcp_rz(mv)) * mv;

    // load table elements from global memory
    f32 thread_prob = prob[n][slot];
    u32 thread_alias = alias[n][slot];

    // return the resulting draw
    if(u < thread_prob) {
      return (f32) slot;
    } else {
      return (f32) thread_alias;
    }
  }

  // if didn't return, draw using Gaussian approximation
  if(u == 1.0f || u == 0.0f) {
    u = 0.5f; // prevent overflow edge cases
  }
  f32 mu = beta + ((f32) n);
  return normcdfinvf(u) * sqrtf(mu) + mu;
}




__device__ __forceinline__ f32 block_reduce_sum(f32* block_sum, f32 thread_sum) {
  // first, perform a warp reduce
  for(i32 offset = warpSize/2; offset > 0; offset /= 2) {
    thread_sum += __shfl_down(thread_sum, offset);
  }

  // then, add result to shared memory
  if(threadIdx.x % warpSize == 0) {
    atomicAdd(block_sum, thread_sum);
  }

  // ensure all threads finish writing
  __syncthreads();

  // return new value to all threads
  return block_sum[0];
}



__global__ void polya_urn_init(u32* n, u32* C, u32 K, f32 beta, u32 V,
    f32** prob, u32** alias, u32 max_lambda, u32 max_value,
    curandStatePhilox4_32_10_t* rng) {
  // initialize variables
  curandStatePhilox4_32_10_t thread_rng = rng[0];
  skipahead((unsigned long long int) blockIdx.x*blockDim.x + threadIdx.x, &thread_rng);

  // loop over array and draw samples
  for(i32 offset = 0; offset < V / blockDim.x + 1; ++offset) {
    i32 col = threadIdx.x + offset * blockDim.x;
    i32 array_idx = col + V * blockIdx.x;
    if(col < V) {
      // draw n_k ~ Pois(C/K + beta)
      f32 u = curand_uniform(&thread_rng);
      f32 pois = draw_poisson(u, beta, C[col] / gridDim.x/*=K*/, prob, alias, max_lambda, max_value);
      n[array_idx] = (u32) pois;
    }
  }
}







__global__ void polya_urn_sample(f32* Phi, u32* n, f32 beta, u32 V,
    f32** prob, u32** alias, u32 max_lambda, u32 max_value,
    curandStatePhilox4_32_10_t* rng) {
  // initialize variables
  curandStatePhilox4_32_10_t thread_rng = rng[0];
  skipahead((unsigned long long int) blockIdx.x*blockDim.x + threadIdx.x, &thread_rng);
  f32 thread_sum = 0.0f;
  __shared__ f32 block_sum[1];
  if(threadIdx.x == 0) {
    block_sum[0] = 0.0f;
  }
  __syncthreads();

  // loop over array and draw samples
  for(i32 offset = 0; offset < V / blockDim.x + 1; ++offset) {
    i32 col = threadIdx.x + offset * blockDim.x;
    i32 array_idx = col + V * blockIdx.x;
    if(col < V) {
      f32 u = curand_uniform(&thread_rng);
      f32 pois = draw_poisson(u, beta, n[array_idx], prob, alias, max_lambda, max_value);
      Phi[array_idx] = pois;
      thread_sum += pois;
    }
  }

  // add up thread sums, synchronize, and broadcast
  thread_sum = block_reduce_sum(block_sum, thread_sum);

  // normalize draws
  for(i32 offset = 0; offset < V / blockDim.x + 1; ++offset) {
    i32 col = threadIdx.x + offset * blockDim.x;
    i32 array_idx = col + V * blockIdx.x;
    if(col < V) {
      Phi[array_idx] /= thread_sum;
    }
  }
}



void polya_urn_transpose(cudaStream_t* stream, f32* Phi, f32* Phi_temp, u32 K, u32 V, cublasHandle_t* handle, f32* d_zero, f32* d_one) {
  cudaMemcpyAsync(Phi_temp, Phi, V * K * sizeof(f32), cudaMemcpyDeviceToDevice, *stream) >> GPULDA_CHECK;
  cublasSetStream(*handle, *stream) >> GPULDA_CHECK; //
  cublasSgeam(*handle, CUBLAS_OP_T, CUBLAS_OP_N, K, V, d_one, Phi_temp, V, d_zero, Phi, K, Phi, K) >> GPULDA_CHECK;
}

__global__ void polya_urn_reset(u32* n, u32 V) {
  for(i32 offset = 0; offset < V / blockDim.x + 1; ++offset) {
    i32 col = threadIdx.x + offset * blockDim.x;
    i32 array_idx = col + V * blockIdx.x;
    if(col < V) {
      n[array_idx] = 0;
    }
  }
}


__global__ void polya_urn_colsums(f32* Phi, f32* sigma_a, f32 alpha, f32** prob, u32 K) {  // initilize variables
  // initialize variables
  f32 thread_sum = 0.0f;
  __shared__ f32 block_sum[1];
  if(threadIdx.x == 0) {
    block_sum[0] = 0.0f;
  }
  __syncthreads();

  // loop over array and compute column sums
  for(i32 offset = 0; offset < K / blockDim.x + 1; ++offset) {
    i32 row = threadIdx.x + offset * blockDim.x;
    i32 array_idx = row + K * blockIdx.x;
    if(row < K) {
      thread_sum += Phi[array_idx];
    }
  }

  // add up thread sums, synchronize, and broadcast
  thread_sum = block_reduce_sum(block_sum, thread_sum);

  // set sigma_a
  if(threadIdx.x == 0) {
    sigma_a[blockIdx.x] = alpha * thread_sum;
  }

  // compute and set alias table probabilities
  for(i32 offset = 0; offset < K / blockDim.x + 1; ++offset) {
    i32 row = threadIdx.x + offset * blockDim.x;
    i32 array_idx = row + K * blockIdx.x;
    if(row < K) {
      prob[blockIdx.x][row] = Phi[array_idx] / thread_sum;
    }
  }
}

}

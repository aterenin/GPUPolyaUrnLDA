#include <cuda_runtime.h>
#include <curand_kernel.h> // need to add -lcurand to nvcc flags
#include <cublas_v2.h> // need to add -lcublas to nvcc flags
#include "assert.h"

#include "train.cuh"
#include "dsmatrix.cuh"
#include "error.cuh"
#include "poisson.cuh"
#include "polyaurn.cuh"
#include "random.cuh"
#include "spalias.cuh"
#include "topics.cuh"
#include "tuning.cuh"

namespace gpulda {

// global variables
Args* args; // externally visible
DSMatrix<f32>* Phi;
DSMatrix<u32>* n;
Poisson* pois;
SpAlias* alias;
f32* sigma_a;
u32* C;
curandStatePhilox4_32_10_t* Phi_rng;
cudaStream_t* Phi_stream;
cublasHandle_t* cublas_handle;
DSMatrix<f32>* Phi_temp;
f32* d_one;
f32* d_zero;

extern "C" void initialize(Args* init_args, Buffer* buffers, u32 n_buffers) {
  // set the pointer to args struct
  args = init_args;

  // allocate and initialize cuBLAS
  cublas_handle = new cublasHandle_t;
  cublasCreate(cublas_handle) >> GPULDA_CHECK;
  cublasSetPointerMode(*cublas_handle, CUBLAS_POINTER_MODE_DEVICE) >> GPULDA_CHECK;
  f32 h_zero = 0.0f;
  cudaMalloc(&d_zero, sizeof(f32)) >> GPULDA_CHECK;
  cudaMemcpy(d_zero, &h_zero, sizeof(f32), cudaMemcpyHostToDevice) >> GPULDA_CHECK;
  f32 h_one = 1.0f;
  cudaMalloc(&d_one, sizeof(f32)) >> GPULDA_CHECK;
  cudaMemcpy(d_one, &h_one, sizeof(f32), cudaMemcpyHostToDevice) >> GPULDA_CHECK;
  Phi_temp = new DSMatrix<f32>();

  // allocate and initialize cuRAND
  cudaMalloc(&Phi_rng, sizeof(curandStatePhilox4_32_10_t)) >> GPULDA_CHECK;
  rng_init<<<1,1>>>(0, 0, Phi_rng);
  cudaDeviceSynchronize() >> GPULDA_CHECK;

  // allocate and initialize streams
  Phi_stream = new cudaStream_t;
  cudaStreamCreate(Phi_stream) >> GPULDA_CHECK;

  // allocate memory for buffers
  for(i32 i = 0; i < n_buffers; ++i) {
    buffers[i].stream = new cudaStream_t;
    cudaStreamCreate(buffers[i].stream) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_z, args->buffer_size * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_w, args->buffer_size * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_d_len, args->max_D * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_d_idx, args->max_D * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_K_d, args->max_D * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_hash, GPULDA_SAMPLE_TOPICS_GRIDDIM*2*args->max_N_d * sizeof(u64)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_temp, GPULDA_SAMPLE_TOPICS_GRIDDIM*args->max_N_d * sizeof(u32)) >> GPULDA_CHECK;
    cudaMalloc(&buffers[i].gpu_rng, sizeof(curandStatePhilox4_32_10_t)) >> GPULDA_CHECK;
    rng_init<<<1,1>>>(0, i + 1, buffers[i].gpu_rng);
    cudaDeviceSynchronize() >> GPULDA_CHECK;
  }

  // allocate globals
  Phi = new DSMatrix<f32>();
  n = new DSMatrix<u32>();
  pois = new Poisson(GPULDA_POIS_MAX_LAMBDA, GPULDA_POIS_MAX_VALUE, args->beta);
  alias = new SpAlias(args->V, args->K);
  cudaMalloc(&sigma_a,args->V * sizeof(f32)) >> GPULDA_CHECK;
  cudaMalloc(&C,args->V * sizeof(u32)) >> GPULDA_CHECK;
  cudaMemcpy(C, args->C, args->V * sizeof(u32), cudaMemcpyHostToDevice) >> GPULDA_CHECK;

  // run device init code
  polya_urn_init<<<args->K,GPULDA_POLYA_URN_SAMPLE_BLOCKDIM>>>(n->dense, C, args->beta, args->V, pois->pois_alias->prob, pois->pois_alias->alias, pois->max_lambda, pois->max_value, Phi_rng);
  cudaDeviceSynchronize() >> GPULDA_CHECK;
  rng_advance<<<1,1>>>(args->K*args->V,Phi_rng);
  cudaDeviceSynchronize() >> GPULDA_CHECK;
}

extern "C" void cleanup(Buffer* buffers, u32 n_buffers) {
  // deallocate globals
  cudaFree(C) >> GPULDA_CHECK;
  cudaFree(sigma_a) >> GPULDA_CHECK;
  delete alias;
  delete pois;
  delete n;
  delete Phi;

  // deallocate memory for buffers
  for(i32 i = 0; i < n_buffers; ++i) {
    cudaFree(buffers[i].gpu_z) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_w) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_d_len) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_d_idx) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_K_d) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_hash) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_temp) >> GPULDA_CHECK;
    cudaFree(buffers[i].gpu_rng) >> GPULDA_CHECK;
    cudaStreamDestroy(*buffers[i].stream) >> GPULDA_CHECK;
    delete buffers[i].stream;
  }

  // deallocate streams
  cudaStreamDestroy(*Phi_stream) >> GPULDA_CHECK;
  delete Phi_stream;

  // deallocate cuRAND
  cudaFree(Phi_rng) >> GPULDA_CHECK;

  // deallocate cuBLAS
  delete Phi_temp;
  cudaFree(d_zero) >> GPULDA_CHECK;
  cudaFree(d_one) >> GPULDA_CHECK;
  cublasDestroy(*cublas_handle) >> GPULDA_CHECK;
  delete cublas_handle;

  // remove the args pointer
  args = NULL;
}

extern "C" void sample_phi() {
  // draw Phi ~ PPU(n + beta)
  polya_urn_sample<<<args->K,GPULDA_POLYA_URN_SAMPLE_BLOCKDIM,0,*Phi_stream>>>(Phi->dense, n->dense, args->beta, args->V, pois->pois_alias->prob, pois->pois_alias->alias, pois->max_lambda, pois->max_value, Phi_rng);
  rng_advance<<<1,1,0,*Phi_stream>>>(args->K*args->V,Phi_rng);

  // copy Phi for transpose, set the stream, then transpose Phi
  polya_urn_transpose(Phi_stream, Phi->dense, Phi_temp->dense, args->K, args->V, cublas_handle, d_zero, d_one);

  // compute sigma_a and alias probabilities
  polya_urn_colsums<<<args->V,GPULDA_POLYA_URN_COLSUMS_BLOCKDIM,0,*Phi_stream>>>(Phi->dense, sigma_a, args->alpha, alias->prob, args->K);

  // build Alias tables
  build_alias<<<args->V,32,2*next_pow2(args->K)*sizeof(i32), *Phi_stream>>>(alias->prob, alias->alias, args->K);

  // reset sufficient statistics for n
  polya_urn_reset<<<args->K,128,0,*Phi_stream>>>(n->dense, args->V);

  // don't return until operations completed
  cudaStreamSynchronize(*Phi_stream) >> GPULDA_CHECK;
}

extern "C" void sample_z_async(Buffer* buffer) {
  // copy z,w,d to GPU and compute d_idx based on document length
  cudaMemcpyAsync(buffer->gpu_z, buffer->z, buffer->n_tokens*sizeof(u32), cudaMemcpyHostToDevice,*buffer->stream) >> GPULDA_CHECK; // copy z to GPU
  cudaMemcpyAsync(buffer->gpu_w, buffer->w, buffer->n_tokens*sizeof(u32), cudaMemcpyHostToDevice,*buffer->stream) >> GPULDA_CHECK; // copy w to GPU
  cudaMemcpyAsync(buffer->gpu_d_len, buffer->d, buffer->n_docs*sizeof(u32), cudaMemcpyHostToDevice,*buffer->stream) >> GPULDA_CHECK;
  cudaMemcpyAsync(buffer->gpu_K_d, buffer->K_d, buffer->n_docs*sizeof(u32), cudaMemcpyHostToDevice,*buffer->stream) >> GPULDA_CHECK;
  compute_d_idx<<<1,GPULDA_COMPUTE_D_IDX_BLOCKDIM,0,*buffer->stream>>>(buffer->gpu_d_len, buffer->gpu_d_idx, buffer->n_docs);

  // sample the topic indicators
  sample_topics<<<GPULDA_SAMPLE_TOPICS_GRIDDIM,GPULDA_SAMPLE_TOPICS_BLOCKDIM,0,*buffer->stream>>>(args->buffer_size, buffer->n_docs, buffer->gpu_z, buffer->gpu_w, buffer->gpu_d_len, buffer->gpu_d_idx, buffer->gpu_K_d, buffer->gpu_hash, buffer->gpu_temp, args->K, args->V, args->max_N_d, Phi->dense, sigma_a, alias->prob, alias->alias, alias->table_size, buffer->gpu_rng);
  rng_advance<<<1,1,0,*buffer->stream>>>(2*buffer->n_tokens,Phi_rng);

  // copy z back to host
  cudaMemcpyAsync(buffer->z, buffer->gpu_z, buffer->n_tokens*sizeof(u32), cudaMemcpyDeviceToHost,*buffer->stream) >> GPULDA_CHECK;
}

extern "C" void sync_buffer(Buffer *buffer) {
  // return when stream has finished
  cudaStreamSynchronize(*buffer->stream) >> GPULDA_CHECK;
}

}

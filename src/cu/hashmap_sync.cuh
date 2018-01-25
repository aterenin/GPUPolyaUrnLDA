#pragma once

#include "types.cuh"
#include "tuning.cuh"
#include <curand_kernel.h> // need to add -lcurand to nvcc flags

#define GPULDA_HASH_LINE_SIZE 16
#define GPULDA_HASH_MAX_NUM_LINES 4
#define GPULDA_HASH_GROWTH_RATE 1.2f
#define GPULDA_HASH_DEBUG 1

#ifdef GPULDA_HASH_DEBUG
#include <cstdio>
#endif

namespace gpulda {

struct HashMap {
  i32 size;
  i32 capacity;
  u64* data;
  int4* data_non_aligned; static_assert(sizeof(int4) == 16, "int4 is not 16 bytes");
  i32 a;
  i32 b;
  i32 c;
  i32 d;
  i32 rebuild;
  curandStatePhilox4_32_10_t* rng;




  __device__ __forceinline__ u64 bfe_b64(u64 source, u32 bit_start, u32 num_bits) {
    u64 bits;
    asm("bfe.u64 %0, %1, %2, %3;" : "=l"(bits) : "l"(source), "r"(bit_start), "r"(num_bits));
    return bits;
  }

  __device__ __forceinline__ void bfi_b64(u64 &ret, u64 x, u64 y, u32 bit_start, u32 num_bits) {
    asm("bfi.b64 %0, %1, %2, %3, %4;" : "=l"(ret) : "l"(y), "l"(x), "r"(bit_start), "r"(num_bits));
  }

  __device__ __forceinline__ u64 entry(u32 key, u32 value) {
    u64 ret = value;
    bfi_b64(ret, ret, key, 32, 32);
    return ret;
  }

  __device__ __forceinline__ u64 with_key(u32 key, u64 entry) {
    bfi_b64(entry, entry, key, 32, 32);
    return entry;
  }

  __device__ __forceinline__ u64 with_value(u64 value, u64 entry) {
    bfi_b64(entry, entry, value, 0, 32);
    return entry;
  }

  __device__ __forceinline__ u32 key(u64 entry) {
    return bfe_b64(entry, 32, 32);
  }

  __device__ __forceinline__ u32 value(u64 entry) {
    return bfe_b64(entry, 0, 32);
  }

  __device__ __forceinline__ static constexpr u64 empty() {
    return 0xffffffff00000000;
  }






  #ifdef GPULDA_HASH_DEBUG
  __device__ inline void debug_print_slot(u32 slot, i32 table = 1) {
    printf("\nhl:s\tk\tv\tis:st:d\n");
    for(u32 s = slot; s < slot + warpSize/2; ++s) {
      u64 entry = data[s % size];
      printf("%d:%d\t%d\t%d\t", s % 16, s % size, key(entry), value(entry));
      if(entry != empty()) printf("%d:%d:%d", hash_slot(key(entry)), hash_stride(key(entry)), key_distance(key(entry), slot));
      printf("\n");
    }
    printf("\n");
  }
  #endif








  __device__ __forceinline__ i32 hash_slot(u32 key) {
    return (((a * key + b) % 334214459) % (capacity / GPULDA_HASH_LINE_SIZE)) * GPULDA_HASH_LINE_SIZE;
  }

  __device__ __forceinline__ i32 hash_stride(u32 key) {
    return (((c * key + d) % 334214459) % (capacity / GPULDA_HASH_LINE_SIZE)) * GPULDA_HASH_LINE_SIZE;
  }

  __device__ __forceinline__ i32 key_distance(u32 key, u32 slot) {
    u32 initial_slot = hash_slot(key);
    u32 stride = hash_stride(key);
    #pragma unroll
    for(i32 i = 0; i < GPULDA_HASH_MAX_NUM_LINES - 1; ++i) {
      if((initial_slot + i*stride) % capacity == slot) {
        return i;
      }
    }
    return GPULDA_HASH_MAX_NUM_LINES;
  }




  __device__ inline void allocate(i32 allocate_capacity) {
    if(threadIdx.x == 0) {
      // round up to ensure cache alignment
      size = 0;
      capacity = (allocate_capacity / GPULDA_HASH_LINE_SIZE) * GPULDA_HASH_LINE_SIZE;
      data_non_aligned = (int4*) malloc((capacity + GPULDA_HASH_LINE_SIZE) * sizeof(u64));
      u64 offset = (GPULDA_HASH_LINE_SIZE * sizeof(u64)) - (((u64) data_non_aligned) % (GPULDA_HASH_LINE_SIZE * sizeof(u64)));
      data = (u64*) (data_non_aligned + (offset / sizeof(int4)));
      float4 r = curand_uniform4(rng);
      a = __float2uint_rz(capacity * r.w);
      b = __float2uint_rz(capacity * r.x);
      c = __float2uint_rz(capacity * r.y);
      d = __float2uint_rz(capacity * r.z);
      rebuild = false;
    }
  }





  __device__ inline i32 init(i32 initial_capacity, curandStatePhilox4_32_10_t* in_rng) {
    // allocate table
    if(threadIdx.x == 0) {
      rng = in_rng;
    }
    allocate(initial_capacity);
    __syncthreads();

    // check for allocation failure
    if(data_non_aligned == NULL) {
      return 1;
    }

    // set map to empty
    for(i32 offset = 0; offset < capacity / blockDim.x + 1; ++offset) {
      i32 i = offset * blockDim.x + threadIdx.x;
      if(i < capacity) {
        data[i] = empty();
      }
    }

    // return success
    return 0;
  }





  __device__ inline void deallocate() {
    if(threadIdx.x == 0 && data_non_aligned != NULL) {
      free(data_non_aligned);
    }
  }





  __device__ inline i32 resize(u32 half_warp_key, i32 half_warp_diff) {
    // save pointers from old table
    u64* old_data = data;
    void* old_data_non_aligned = data_non_aligned;
    i32 old_capacity = capacity;
    __syncthreads();

    // repeat until resize succeeds or memory allocation fails
    do {
      // allocate new table
      allocate(__float2uint_rz(capacity * GPULDA_HASH_GROWTH_RATE) + blockDim.x);
      __syncthreads();

      // check for allocation failure
      if(data_non_aligned == NULL) {
        return 1;
      }

      // move elements from threads
      try_insert2(half_warp_key, half_warp_diff);

      // move elements from old table
      for(i32 offset = 0; offset < old_capacity / blockDim.x + 1; ++offset) {
        i32 i = offset * blockDim.x + threadIdx.x;
        u64 lane_entry = empty();
        if(i < old_capacity) {
          lane_entry = old_data[i];
        }

        // insert two half lanes at a time
        for(i32 j = 0; j < warpSize/2; ++j) {
          i32 half_warp_entry = __shfl(lane_entry, j, warpSize/2);
          try_insert2(key(half_warp_entry), value(half_warp_entry));
        }
      }
      __syncthreads();

      // if any insertions failed, try again with even larger capacity
      if(threadIdx.x == 0 && rebuild != false) {
        free(data_non_aligned);
      }
    } while(rebuild != false);

    // once everything succeeded, deallocate old table
    if(threadIdx.x == 0) {
      free(old_data_non_aligned);
    }
    return 0;
  }





  __device__ inline u32 get2(u32 half_warp_key) {
    // determine constants
    i32 half_lane_idx = threadIdx.x % (warpSize/2);
    u32 half_lane_mask = half_lane_idx < (warpSize/2) ? 0x0000ffff : 0xffff0000;

    // check table
    i32 initial_slot = hash_slot(half_warp_key);
    i32 stride = hash_stride(half_warp_key);
    for(i32 i = 0; i < GPULDA_HASH_MAX_NUM_LINES; ++i) {
      // compute slot and retrieve entry
      i32 slot = (initial_slot + i * stride) % capacity;
      u64 entry = data[slot + half_lane_idx];

      // check if we found the key
      u32 key_found = __ballot(key(entry) == half_warp_key) & half_lane_mask;
      if(key_found != 0) {
        return __shfl(value(entry), __ffs(key_found) - 1, warpSize/2);
      }

      // check if Robin Hood guarantee indicates no key is present
      u32 no_key = __ballot(entry == empty() || key_distance(key(entry), slot) < i) & half_lane_mask;
      if(no_key != 0) {
        return 0;
      }
    }

    // ran out of possible slots: key not present
    return 0;
  }




  __device__ inline void try_insert2(u32 half_warp_key, i32 diff) {
    // determine constants
    i32 half_lane_idx = threadIdx.x % (warpSize/2);
    u32 half_lane_mask = half_lane_idx < (warpSize/2) ? 0x0000ffff : 0xffff0000;

    i32 slot = hash_slot(half_warp_key);
    i32 stride = hash_stride(half_warp_key);
    i32 distance = 0;
    while(true) {
      // retrieve entry for current half lane
      u64 thread_entry = data[slot + half_lane_idx];

      // check if we found the key, empty slot, or no key is present
      u32 key_found = __ballot(key(thread_entry) == half_warp_key) & half_lane_mask;
      u32 key_empty = __ballot(thread_entry == empty()) & half_lane_mask;
      u32 no_key = __ballot(key_distance(key(thread_entry), slot) < distance) & half_lane_mask;

      // determine which thread, if any, performs a swap
      u64 thread_new_entry;
      i32 swap_idx = -1;
      if(key_found != 0) {
        swap_idx = (__ffs(key_found) - 1) % (warpSize/2);
        thread_new_entry = with_value(thread_entry, value(thread_entry) + diff);
      } else if(key_empty != 0) {
        swap_idx = (__ffs(key_empty) - 1) % (warpSize/2);
        thread_new_entry = entry(half_warp_key, max(diff, 0));
      } else if(no_key != 0) {
        swap_idx = (__ffs(no_key) - 1) % (warpSize/2);
        thread_new_entry = entry(half_warp_key, max(diff, 0));
      }

      // perform swap
      i32 swap_success = false;
      if(half_lane_idx == swap_idx) {
        u64 old = atomicCAS(&data[slot + half_lane_idx], thread_entry, thread_new_entry);
        swap_success = (thread_entry == old);
      }
      __shfl(swap_success, swap_idx, warpSize/2);

      // if swap succeeded, either exit or prepare new key
      if(swap_success) {
        if(key_found != 0) {
          break;
        } else if(key_empty != 0) {
          if(half_lane_idx == 0) {
            atomicAdd(&size, 1);
          }
          break;
        } else {
          half_warp_key = __shfl(key(thread_new_entry), swap_idx, warpSize/2);
          diff = __shfl(value(thread_new_entry), swap_idx, warpSize/2);
          stride = hash_stride(half_warp_key);
          distance = key_distance(half_warp_key, slot);
        }
      }

      // advance slot, declare failure if reached limit
      if(swap_idx == -1 || (swap_success && (no_key != 0))) {
        slot = (slot + stride) % capacity;
        distance += 1;
        if(distance == GPULDA_HASH_MAX_NUM_LINES) {
          if(half_lane_idx == 0) {
            atomicOr(&rebuild, true);
          }
          break;
        }
      }
    }
  }





  __device__ inline i32 insert2(u32 half_warp_key, i32 diff) {
    // try to insert key
    if(diff != 0) {
      try_insert2(half_warp_key, diff);
    }
    __syncthreads();

    // rebuild if necessary, return error if memory allocation failed
    if(rebuild != false) {
      return resize(half_warp_key, diff);
    }

    // return success
    return 0;
  }
};

}

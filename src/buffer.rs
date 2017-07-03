use libc::{uint32_t, size_t};
use std::mem;
use std::slice;

#[repr(C)]
pub struct Buffer {
  size: size_t,
  z: *const uint32_t,
  w: *const uint32_t,
  d_len: *const uint32_t,
  d_idx: *const uint32_t,
  n_docs: uint32_t,
}

impl Buffer {
  pub fn new(size: usize) -> Buffer {
    // allocate arrays
    let z = Vec::with_capacity(size).into_boxed_slice();
    let w = Vec::with_capacity(size).into_boxed_slice();
    let d_len = Vec::with_capacity(size).into_boxed_slice();
    let d_idx = Vec::with_capacity(size).into_boxed_slice();
    // create buffer
    let b = Buffer {
      size: size,
      z: z.as_ptr(),
      w: w.as_ptr(),
      d_len: d_len.as_ptr(),
      d_idx: d_idx.as_ptr(),
      n_docs: 0,
    };
    // as_ptr doesn't take ownership, we need to be sure not to deallocate any arrays
    mem::forget(z);
    mem::forget(w);
    mem::forget(d_len);
    mem::forget(d_idx);
    // return the buffer
    b
  }
}

#[allow(unused_variables)]
impl Drop for Buffer {
  fn drop(&mut self) {
    unsafe {
      let z = slice::from_raw_parts(self.z, self.size);
      let w = slice::from_raw_parts(self.w, self.size);
      let d_len = slice::from_raw_parts(self.d_len, self.size);
      let d_idx = slice::from_raw_parts(self.d_idx, self.size);
      // at this point, z,w,dLen,dIdx are dropped and deallocated
    }
  }
}
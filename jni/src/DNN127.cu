#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <stdio.h>
#include <MatKernel.hpp>

#define BYDIMF 2
#define BYDIMB 5
#define CDIM 5

#if __CUDA_ARCH__ >= 300


/*
 * Convolutional kernel for word2vec. This handles the positively-label word pairs with
 * one context word and the current word. 
 */

template<int SKIP, int YDIM, int NREPS>
  __global__ void __word2vecPos(int nrows, int ncols, int *W, int *LB, int *UB, float *A, float *B, float lrate) {
  const int nwindow = 2*SKIP+1; 
  int words[nwindow];
  float aa[NREPS];
  float daa[NREPS];
  float bb[NREPS][nwindow];
  float dbb[NREPS][nwindow];
  __shared__ float CC[YDIM * nwindow];

  int i, j, k, tid, indx, icol, dxy, lb, ub;
  float prod, v;
  tid = threadIdx.x + blockDim.x * threadIdx.y;
  dxy = blockDim.x * blockDim.y;
  bool good;

  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);

#pragma unroll
  for (i = 0; i < nwindow; i++) {                           // Prefill the word and aa window buffers
    if (istart + i - SKIP - 1 >= 0) {
      words[i] = nrows * W[istart + i - SKIP - 1];          // Get a new word
    } else {
      words[i] = -1;
    }
    good = (words[i] >= 0);
#pragma unroll
    for (j = 0; j < NREPS; j++) {                           // Get the B vector for this word
      indx = tid + j * dxy;
      if (good && indx < nrows) {
        bb[j][i] = B[indx + words[i]];
      } else {
        bb[j][i] = 0;
      }
      dbb[j][i] = 0;
    }
  }

  for (icol = istart; icol < iend; icol++) {                // Iterate over columns
#pragma unroll
    for (i = 0; i < nwindow-1; i++) {                       // slide words down
      words[i] = words[i+1];
#pragma unroll
      for (j = 0; j < NREPS; j++) {
        bb[j][i] = bb[j][i+1];                              // slide data down
        dbb[j][i] = dbb[j][i+1];                            // slide deriv down
      }
    }

    good = (icol + SKIP < ncols);
    if (good) {
      words[nwindow - 1] = nrows * W[icol + SKIP];          // Get a new word
    } else {
      words[nwindow - 1] = -1;
    }
    good = good && words[nwindow-1] >= 0;

#pragma unroll
    for (j = 0; j < NREPS; j++) {                           // Get a new B column
      indx = tid + j * dxy;
      if (good && indx < nrows) {
        bb[j][nwindow - 1] = B[indx + words[nwindow - 1]];
      } else {
        bb[j][nwindow - 1] = 0;
      }
      if (words[SKIP] >= 0 && indx < nrows) {               // Get a new A column
        aa[j] = A[indx + words[SKIP]];
      } else {
        aa[j] = 0;
      }
    }
    lb = LB[icol];
    ub = UB[icol];

    __syncthreads();
#pragma unroll                 
    for (i = 0; i < nwindow; i++) {                         // Iterate across the window for B cols
      prod = 0;
      if (i >= SKIP + lb && i <= SKIP + ub) {
#pragma unroll                 
        for (j = 0; j < NREPS; j++) {                       // Iterate over blocks of elements
          prod += bb[j][i] * aa[j];                         // Compute the product between current A, B cols
        }
#pragma unroll                 
        for (k = 1; k < 32; k = k + k) {
          v = __shfl_down(prod, k);                         // Reduce within warp
          prod += v;
        }  
        if (threadIdx.x == 0) {
          CC[i - SKIP - lb + threadIdx.y * nwindow] = prod;  // Save to SHMEM
        }
      }
    }

    __syncthreads();
    for (i = 1; i < blockDim.y; i++) {                      // Reduce across warps
      for (k = tid; k <= ub - lb; k += dxy) { 
        CC[k] += CC[k + i * nwindow];
      }
      __syncthreads();
    }

    __syncthreads();                                        //  Apply the sigmoid map
    for (i = tid; i <= ub - lb; i += dxy) { 
      v = CC[i];
      if (v > 16.0f) {
        v = 1.0f;
      } else if (v < -16.0f) {
        v = 0.0f;
      } else {
        v = exp(v);
        v = v / (1.0f + v);
      }
      CC[i] = 1.0f - v;                                     // All pairs have label 1
    }
      
    __syncthreads();  
#pragma unroll                 
    for (j = 0; j < NREPS; j++) {
      daa[j] = 0;
    }
#pragma unroll                 
    for (i = 0; i < nwindow; i++) {                         // Iterate across the window for A cols
      if (i >= SKIP + lb && i <= SKIP + ub && i != SKIP) {
        v = lrate * CC[i - SKIP - lb];
        //        v = 1;
#pragma unroll                 
        for (j = 0; j < NREPS; j++) {
          daa[j] += v * bb[j][i];                           // Update the local B cache after each current word
          dbb[j][i] += v * aa[j];                           // Compute the product with the current A, B cols
        }
      }
    }
    __syncthreads();  
    if (words[SKIP] >= 0) {
#pragma unroll                 
      for (j = 0; j < NREPS; j++) { 
        if (tid + j * dxy < nrows) {                        // Save the A column
          atomicAdd(&A[tid + j * dxy + words[SKIP]], daa[j]);
        }
      }
    }
    if (words[0] >= 0) {
#pragma unroll                 
      for (j = 0; j < NREPS; j++) {                         // Save the B column
        if (tid + j * dxy < nrows) {
          atomicAdd(&B[tid + j * dxy + words[0]], dbb[j][0]);
        }
      } 
    }
  }

#pragma unroll      
  for (i = 1; i < nwindow; i++) {                           // Clear out the derivative queue
    if (words[i] >= 0) {
#pragma unroll                 
      for (j = 0; j < NREPS; j++) {                         // Save the B column
        if (tid + j * dxy < nrows) {
          atomicAdd(&B[tid + j * dxy + words[i]], dbb[j][i]);
        }
      } 
    }
  }
}

/*
 * Convolutional kernel for word2vec. This handles the positively-label word pairs with
 * one context word and the current word. 
 */

template<int SKIP, int YDIM, int NREPS>
  __global__ void __word2vecPos_exp(int nrows, int ncols, int *W, int *LB, int *UB, float *A, float *B, float lrate) {
  const int nwindow = 2*SKIP+1; 
  float aa[NREPS];
  float da[NREPS];
  __shared__ float CC[YDIM * nwindow];

  int i, j, k, tid, icol, dxy, lb, ub, iword, cword;
  float bb, db, prod, v;
  tid = threadIdx.x + blockDim.x * threadIdx.y;
  dxy = blockDim.x * blockDim.y;

  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);

  for (icol = istart; icol < iend; icol++) {                // Iterate over columns

    iword = nrows * W[icol];                                // Get the current word

    __syncthreads();
    
    lb = LB[icol];
    ub = UB[icol];

    if (iword >= 0) {
#pragma unroll                 
      for (j = 0; j < NREPS; j++) {                         // Iterate over blocks of elements
        if (tid + j * dxy < nrows) {                        // Get A
          aa[j] = A[tid + j * dxy + iword];
        } else {
          aa[j] = 0;
        }
      }

      for (i = lb; i <= ub; i++) {                          // Iterate across the window for A cols
        __syncthreads();
        cword = nrows * W[icol + i];                        // Get the current word
        prod = 0;
        if (cword >= 0) {
#pragma unroll                 
          for (j = 0; j < NREPS; j++) {                     // Iterate over blocks of elements
            if (tid + j * dxy < nrows) {                    // Get B col
              bb = B[tid + j * dxy + cword];
              prod += aa[j] * bb;                           // Compute the product between current A, B cols
            }
          }
#pragma unroll                 
          for (k = 1; k < 32; k = k + k) {
            prod += __shfl_down(prod, k);                   // Reduce within warp
          }  
        }
        if (threadIdx.x == 0) {
          CC[i - lb + threadIdx.y * nwindow] = prod;        // Save to SHMEM
        }
      }

      __syncthreads();
      for (j = 1; j < blockDim.y; j++) {                    // Reduce across warps
        for (i = tid; i < ub - lb; i += dxy) { 
          CC[i] += CC[i + j * nwindow];
        }
        __syncthreads();
      }

      __syncthreads();                                      //  Apply the sigmoid map
      for (i = tid; i < ub - lb; i += dxy) { 
        v = CC[i];
        if (v > 16.0f) {
          v = 1.0f;
        } else {
          v = exp(v);
          v = v / (1.0f + v);
        }
        CC[i] = lrate * (1.0f - v);                         // All pairs have label 1
      }
      
      __syncthreads();  
#pragma unroll                 
      for (j = 0; j < NREPS; j++) {
        da[j] = 0;
      }
      for (i = lb; i <= ub; i++) {                          // Iterate across the window for A cols   
        cword = nrows * W[icol + i];                        // Get the context word
        v = CC[i - lb];
        if (cword >= 0) {
#pragma unroll                 
          for (j = 0; j < NREPS; j++) {                     // Iterate over blocks of elements
            if (tid + j * dxy < nrows) {                    // Get B col
              bb = B[tid + j * dxy + cword];
              da[j] += v * bb;
              db = v * aa[j];
              atomicAdd(&B[tid + j * dxy + cword], db);
            }
          }
        }
      }

#pragma unroll                 
      for (j = 0; j < NREPS; j++) {
        if (tid + j * dxy < nrows) {                    
          atomicAdd(&A[tid + j * dxy + iword], da[j]);
        }
      }
    }
  }
}

/*
 * Combined forward-backward word2vec kernel
 */


template<int NWA, int NWB, int MAXD, int BYDIM>
  __global__ void __word2vecNeg(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float lrate) {
  const int NWAB = NWA*NWB;
  __shared__ float CC[NWA*NWB*BYDIM];
  float aa[NWA];
  float bb[NWB];
  float prods[NWA][NWB];
  int ia[NWA];
  int ib[NWB];
  int tid = threadIdx.x + blockDim.x * threadIdx.y;
  int dxy = blockDim.x * blockDim.y;
  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);
  int i, j, k, icol;
  float dv, v;

  for (icol = istart; icol < iend; icol++) {                // Iterate over columns
#pragma unroll
    for (i = 0; i < NWA; i++) {
      ia[i] = nrows * WA[i + icol * NWA];                   // Fill the A word matrix
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // clear the products matrix
        prods[i][j] = 0;
      }
    }
#pragma unroll
    for (i = 0; i < NWB; i++) {
      ib[i] = nrows * WB[i + icol * NWB];                   // Fill the B word matrix
    }

    for (i = tid; i < nrows; i += dxy) {                    // Now iterate over the rows of this block
#pragma unroll
      for (j = 0; j < NWB ; j++) {                          // Read B
        bb[j] = B[i + ib[j]];
      }
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Compute the products of these elements
        v = A[i + ia[j]];
#pragma unroll
        for (k = 0; k < NWB; k++) {
          prods[j][k] += v * bb[k];
        }
      }
    }                                                       // Finished the entire block

#pragma unroll
    for (i = 0; i < NWA; i++) {                             // Reduce the products within each warp
#pragma unroll
      for (j = 0; j < NWB; j++) {
#pragma unroll
        for (k = 1; k < 32; k = k+k) {
          float tmp = __shfl_down(prods[i][j], k);
          prods[i][j] += tmp;
        }
      }
    }
    __syncthreads();
    if (threadIdx.x == 0) {                                 // Save the products to SHMEM (one copy per warp)
#pragma unroll
      for (i = 0; i < NWA; i++) {
#pragma unroll
        for (j = 0; j < NWB; j++) {
          CC[i + NWA * (j + NWB * threadIdx.y)] = prods[i][j];
        }
      }
    }
    __syncthreads();
    for (i = 1; i < blockDim.y; i++) {
      __syncthreads();
      for (j = tid; j < NWAB; j += dxy) {                   // Reduce the products across warps
        CC[j] += CC[j + i * NWAB];
      } 
    } 
    __syncthreads();

    for (i = tid; i < NWA*NWB; i+= dxy) {                   // Compute logistic function on all products
      v = CC[i];
      if (v > 16.0f) {
        v = 1.0f;
      } else if (v < -16.0f) {
        v = 0.0f;
      } else {
        v = exp(v);
        v = v / (1.0f + v);
      }
      CC[i] = - lrate * v;                                  // All these pairs have label 0
    }

    __syncthreads();
    for (i = tid; i < nrows; i += dxy) {
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Load A data
        aa[j] = A[i + ia[j]];
      }
#pragma unroll
      for (k = 0; k < NWB; k++) {                           // Load B data
        bb[k] = B[i + ib[k]];
        prods[0][k] = 0;
      }
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Now do the products
        dv = 0;
#pragma unroll
        for (k = 0; k < NWB; k++) {                       
          v = CC[j + k * NWA];
          dv += v * bb[k];
          prods[0][k] += v * aa[j];
        }
        atomicAdd(&A[i + ia[j]], dv);                      // Update A
      }
#pragma unroll
      for (k = 0; k < NWB; k++) {                       
        atomicAdd(&B[i + ib[k]], prods[0][k]);             // Update B
      }
    } 
    __syncthreads();
  }
}

/*
 * Combined forward-backward word2vec kernel
 */


template<int NWA, int NWB, int MAXD, int BYDIM>
  __global__ void __word2vecNeg_old(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float lrate) {
  const int NWAB = NWA*NWB;
  __shared__ float CC[NWA*NWB*BYDIM];
  float dd[MAXD];
  float prods[NWA][NWB];
  float aa, v, sum;
  int ia[NWA];
  int ib[NWB];
  int tid = threadIdx.x + blockDim.x * threadIdx.y;
  int dxy = blockDim.x * blockDim.y;
  int i, j, k, icol;
  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);

  for (icol = istart; icol < iend; icol++) {                // Iterate over columns
#pragma unroll
    for (i = 0; i < NWA; i++) {
      ia[i] = nrows * WA[i + icol * NWA];                   // Fill the A word matrix
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // clear the products matrix
        prods[i][j] = 0;
      }
    }
#pragma unroll
    for (i = 0; i < NWB; i++) {
      ib[i] = nrows * WB[i + icol * NWB];                   // Fill the B word matrix
    }

    for (i = tid; i < nrows; i += dxy) {                    // Now iterate over the rows of this block
#pragma unroll
      for (j = 0; j < NWB ; j++) {                          // Read B
        if (ib[j] >= 0) {
          dd[j] = B[i + ib[j]];
        } else {
          dd[j] = 0;
        }
      }
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Compute the inner products of these elements
        if (ia[j] >= 0) {
          aa = A[i + ia[j]];
#pragma unroll
          for (k = 0; k < NWB; k++) {
            prods[j][k] += aa * dd[k];
          }
        }
      }
    }                                                       // Finished the entire block

#pragma unroll
    for (i = 0; i < NWA; i++) {                             // Reduce the products within each warp
#pragma unroll
      for (j = 0; j < NWB; j++) {
#pragma unroll
        for (k = 1; k < 32; k = k+k) {
          float tmp = __shfl_down(prods[i][j], k);
          prods[i][j] += tmp;
        }
      }
    }
    __syncthreads();
    if (threadIdx.x == 0) {                                 // Save the products to SHMEM (one copy per warp)
#pragma unroll
      for (i = 0; i < NWA; i++) {
#pragma unroll
        for (j = 0; j < NWB; j++) {
          CC[j + NWB * (i + NWA * threadIdx.y)] = prods[i][j];
        }
      }
    }
    __syncthreads();
    for (i = 1; i < blockDim.y; i++) {
      __syncthreads();
      for (j = tid; j < NWAB; j += dxy) {                   // Reduce the products across warps
        CC[j] += CC[j + i * NWAB];
      } 
    } 
    __syncthreads();

    for (i = tid; i < NWA*NWB; i+= dxy) {                   // Compute logistic function on all products
      v = CC[i];
      if (v > 16.0f) {
        v = 1.0f;
      } else {
        v = exp(v);
        v = v / (1.0f + v);
      }
      CC[i] = - lrate * v;                                  // All these pairs have label 0
    }

    __syncthreads();
    for (i = tid; i < nrows; i += dxy) {
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // Load B data
        if (ib[j] >= 0) {
          dd[j] = B[i + ib[j]];
        } else {
          dd[j] = 0;
        }
      }
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Now do the product
        if (ia[j] >= 0) {
          sum = 0;
#pragma unroll
          for (k = 0; k < NWB; k++) {                       
            float xx = CC[j + k * NWA];
            sum += xx * dd[k];
          }
          atomicAdd(&A[i + ia[j]], sum);
        }
      }

#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Load A data
        if (ia[j] >= 0) {
          dd[j] = A[i + ia[j]];
        } else {
          dd[j] = 0;
        }
      }
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // Now do the product
        if (ib[j] >= 0) {
          sum = 0;
#pragma unroll
          for (k = 0; k < NWA; k++) {                       
            float xx = CC[k + j * NWA];
            sum += xx * dd[k];
          }
          atomicAdd(&B[i + ib[j]], sum);
        }
      }
    } 
    __syncthreads();

  }
}

/*
 *
 * Simple forward kernel for word2vec. Computes inner products of columns from A with columns from B. 
 * The column indices are specified by two "word" matrices. The inner products are computed as an outer product
 * of the word matrices.
 * 
 *  NWA is the number of words per column in WA
 *  NWB is the number of words per column in WB
 *
 *  Columns of the output matrix C are <window> = NWA*NWB long, and contain inner products with corresponding columns of B. 
 *
 */

template<int NWA, int NWB, int BDIM>
__global__ void __word2vecFwd(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float *C) {
  const int NWAB = NWA*NWB;
  __shared__ float CC[NWA*NWB*BDIM];
  float aa;
  float bb[NWB];
  float prods[NWA][NWB];
  int wa[NWA];
  int wb[NWB];
  int tid = threadIdx.x + blockDim.x * threadIdx.y;
  int dxy = blockDim.x * blockDim.y;
  int i, j, k, icol;
  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);

  for (icol = istart; icol < iend; icol++) {                // Iterate over columns
#pragma unroll
    for (i = 0; i < NWA; i++) {
      wa[i] = nrows * WA[i + icol * NWA];                   // Fill the A word matrix
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // clear the products matrix
        prods[i][j] = 0;
      }
    }
#pragma unroll
    for (i = 0; i < NWB; i++) {
      wb[i] = WB[i + icol * NWB];                           // Fill the B word matrix
    }

    for (i = tid; i < nrows; i += dxy) {                    // Now iterate over the rows of this block
#pragma unroll
      for (j = 0; j < NWB ; j++) {                          // Read B
        bb[j] = B[i + wb[j] * nrows];
      }
#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Computes the products of these elements
        aa = A[i + wa[j] * nrows];
#pragma unroll
        for (k = 0; k < NWB; k++) {
          prods[j][k] += aa * bb[k];
        }
      }
    }                                                       // Finished the entire block

#pragma unroll
    for (i = 0; i < NWA; i++) {                             // Reduce the products within each warp
#pragma unroll
      for (j = 0; j < NWB; j++) {
#pragma unroll
        for (k = 1; k < 32; k = k+k) {
          float tmp = __shfl_down(prods[i][j], k);
          prods[i][j] += tmp;
        }
      }
    }

    __syncthreads();
    if (threadIdx.x == 0) {                                 // Save the products to SHMEM (one copy per warp)
#pragma unroll
      for (i = 0; i < NWA; i++) {
#pragma unroll
        for (j = 0; j < NWB; j++) {
          CC[j + NWB * (i + NWA * threadIdx.y)] = prods[i][j];
        }
      }
    }

    __syncthreads();
    for (i = 1; i < blockDim.y; i++) {
      __syncthreads();
#pragma unroll
      for (j = tid; j < NWAB; j += dxy) {                   // Reduce the products across warps
        CC[j] += CC[j + i * NWAB];
      } 
    } 
    __syncthreads();
    for (i = tid; i < NWAB; i += dxy) {                     // Save to main memory
      C[i + icol * NWAB] = CC[i];  
        //atomicAdd(&C[i + icol * NWAB], CC[i]); 
    }
    __syncthreads();
  }
}

/*
 *
 * Simple backward kernel for word2vec. 
 * Computes the gradient for A given B or vice-versa, and does an SGD update.
 * 
 *  NWA is the number of words per column in WA
 *  NWB is the number of words per column in WB
 *
 */


template<int NWA, int NWB, int MAXDIM>
  __global__ void __word2vecBwd(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float *C, float lrate) {
  const int NWAB = NWA * NWB;
  float dd[MAXDIM];
  int wa[NWA];
  int wb[NWB];
  __shared__ float cc[NWA*NWB];
  int tid = threadIdx.x;
  int fid = threadIdx.x + blockDim.x * threadIdx.y; 
  int dxy = blockDim.x * blockDim.y;
  int icol, i, j, k;
  float sum;
  int istart = (int)((1L * blockIdx.x * ncols) / gridDim.x);
  int iend = (int)((1L * (blockIdx.x+1) * ncols) / gridDim.x);

  for (icol = istart; icol < iend; icol++) {                // iterate in columns
#pragma unroll
    for (j = 0; j < NWA; j++) {
      wa[j] = WA[j + icol * NWA];                           // Load the A word matrix
    }
    __syncthreads();
#pragma unroll 
    for (j = 0; j < NWB; j++) {
      wb[j] = WB[j + icol * NWB];                           // Load the B word matrix
    }
    for (i = fid; i < NWAB; i += dxy) {
      cc[i] = C[i + icol * NWAB];
    }
    __syncthreads();
    for (i = tid; i < nrows; i += dxy) {
#pragma unroll
      for (j = 0; j < NWB; j++) {                           // Load the data
        dd[j] = B[i + wb[j] * nrows];
      }

#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Now do the product
        sum = 0;
#pragma unroll
        for (k = 0; k < NWB; k++) {                       
          float xx =  cc[j + k * NWA];
          sum += xx * dd[k];
        }
        atomicAdd(&A[i + wa[j] * nrows], sum * lrate);
      }

#pragma unroll
      for (j = 0; j < NWA; j++) {                           // Load the data
        dd[j] = A[i + wa[j] * nrows];
      }

#pragma unroll
      for (j = 0; j < NWB; j++) {                           // Now do the product
        sum = 0;
#pragma unroll
        for (k = 0; k < NWA; k++) {                       
          float xx =  cc[k + j * NWA];
          sum += xx * dd[k];
        }
        atomicAdd(&B[i + wb[j] * nrows], sum * lrate);
      }
    }
  }
}



#else

template<int SKIP, int YDIM, int NREPS>
  __global__ void __word2vecPos(int nrows, int ncols, int *W, int *LB, int *UB, float *A, float *B, float lrate) {}

template<int NWA, int NWB, int MAXD, int BYDIM>
  __global__ void __word2vecNeg(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float lrate) {}

template<int NWA, int NWB, int BDIM>
__global__ void __word2vecFwd(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float *C) {}

template<int NWA, int NWB, int MAXDIM>
  __global__ void __word2vecBwd(int nrows, int ncols, int *WA, int *WB, float *A, float *B, float *C, float lrate) {}

#endif

int word2vecPos(int nrows, int ncols, int skip, int *W, int *LB, int *UB, float *A, float *B, float lrate) {
  dim3 threads(32, CDIM, 1);
  int nblocks = 1 + (nrows - 1)/threads.y;
  switch(skip) {
  case 5 : __word2vecPos<5, CDIM, 10/CDIM><<<nblocks,threads>>>(nrows, ncols, W, LB, UB, A, B, lrate); break;
  case 3 : __word2vecPos<3, CDIM, 10/CDIM><<<nblocks,threads>>>(nrows, ncols, W, LB, UB, A, B, lrate); break;
  case 2 : __word2vecPos<2, CDIM, 10/CDIM><<<nblocks,threads>>>(nrows, ncols, W, LB, UB, A, B, lrate); break;
  default : printf("word2vecPos unsupport size %d\n", skip); return 1;
  }
  cudaDeviceSynchronize();
  int err = cudaGetLastError();
  return err;
}


int word2vecNeg(int nrows, int ncols, int nwa, int nwb, int *WA, int *WB, float *A, float *B, float lrate) {
  dim3 threads(32, BYDIMF, 1);
  int nblocks = min(2048, 2 + (ncols - 1));
  int which = nwa*10000 + nwb;
  switch (which) {
  case 50001: __word2vecNeg<5,1,5,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, lrate); break;
  case 50005: __word2vecNeg<5,5,5,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, lrate); break;
  case 100005: __word2vecNeg<10,5,10,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, lrate); break;
    //  case 100010: __word2vecNeg<10,10,10><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, lrate); break;
    //  case 150010: __word2vecNeg<15,10,15><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, lrate); break;
  default : printf("word2vec unsupport size combination %d %d\n", nwa, nwb); return 1;
  }
  cudaDeviceSynchronize();
  int err = cudaGetLastError();
  return err;
}

int word2vecFwd(int nrows, int ncols, int nwa, int nwb, int *WA, int *WB, float *A, float *B, float *C) {
  dim3 threads(32, BYDIMF, 1);
  int nblocks = min(4096, 2 + (ncols - 1));
  int which = nwa*10000 + nwb;
  switch (which) {
  case 50001: __word2vecFwd<5,1,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C); break;
  case 50005: __word2vecFwd<5,5,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C); break;
  case 100005: __word2vecFwd<10,5,BYDIMF><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C); break;
  default : printf("word2vecFwd unsupport size combination %d %d\n", nwa, nwb); return 1;
  }
  cudaDeviceSynchronize();
  int err = cudaGetLastError();
  return err;
  }

int word2vecBwd(int nrows, int ncols, int nwa, int nwb, int *WA, int *WB, float *A, float *B, float *C, float lrate) {
  dim3 threads(32*BYDIMB, 1, 1);
  int nblocks = min(2048, 2 + (ncols - 1));
  int which = nwa*10000 + nwb;
  switch (which) {
  case 50001: __word2vecBwd<5,1,5><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C, lrate); break;
  case 50005: __word2vecBwd<5,5,5><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C, lrate); break;
  case 100005: __word2vecBwd<10,5,10><<<nblocks,threads>>>(nrows, ncols, WA, WB, A, B, C, lrate); break;
  default : printf("word2vecBwd unsupport size combination %d %d\n", nwa, nwb); return 1;
  }
  cudaDeviceSynchronize();
  int err = cudaGetLastError();
  return err;
}
 

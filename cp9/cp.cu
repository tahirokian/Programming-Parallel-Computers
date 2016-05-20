#include <numeric>     // std::accumulate
#include <algorithm>   // std::transform, std::copy
#include <vector>      // std::vector
#include <cmath>       // std::sqrt, std::ceil
#include "cp.h"
#include <cuda_runtime.h>
//kk
#define TILE 16
//Kernel code
__global__ void correlationKernel(float* input, float* inputTr, float* output, int nx, int ny){
  int bx = blockDim.x, by = blockDim.y;
  int tx = threadIdx.x, ty = threadIdx.y;
  int row = ty + blockIdx.y * TILE;
  int col = tx + blockIdx.x * TILE;
  __shared__ float subInX[TILE][TILE];
  __shared__ float subInY[TILE][TILE];
  //if (row >= ny || col >= ny) // Exit if outside, do not calculate lower triangle
  //  return;
  float sum = 0.0;
  for (int k = 0; k < (TILE + nx -1)/TILE; ++k){
    if ((k * TILE + tx) < nx && row < ny)
      subInX[ty][tx] = input[row*nx + k*TILE + tx];
    else
      subInX[ty][tx] = 0;
    if ((k * TILE + ty) < nx && col < ny)
      subInY[ty][tx] = inputTr[(k*TILE + ty)*ny + col];
    else
      subInY[ty][tx] = 0;
    __syncthreads();
    for (int n = 0; n < TILE; ++n)
      sum += subInX[ty][n]*subInY[n][tx];
    __syncthreads();
  }
  if (row < ny && col < ny)
    output[((blockIdx.y*by+ty)*ny)+(blockIdx.x*bx)+tx] = sum;
}

void correlate(int ny, int nx, const float* data, float* result) {
  float rowMean, normFactor;
  int rowStart, rowEnd;
  size_t inputSize = ny * nx;
  size_t outputSize = ny * ny;
  float* hostIn = 0;
  float* hostInTr = 0;
  float* deviceIn = 0;
  float* deviceInTr = 0;
  float* deviceOut = 0;
  std::vector<float> zeroMeanVec(nx), elemSqrdVec(nx);
  cudaMallocHost((void**) &hostIn, inputSize * sizeof(float));
  cudaMallocHost((void**) &hostInTr, inputSize * sizeof(float));
  cudaMalloc((void**) &deviceIn, inputSize * sizeof(float));
  cudaMalloc((void**) &deviceInTr, inputSize * sizeof(float));
  cudaMalloc((void**) &deviceOut, outputSize * sizeof(float));
  dim3 blockSize(TILE,TILE);                                                          //block of 8x8
  dim3 gridSize(std::ceil(float(ny)/blockSize.x), std::ceil(float(ny)/blockSize.y));  //grid of (ny/8)x(ny/8)
  for(int y = 0; y < ny; ++y){
    rowStart = y*nx;
    rowEnd = nx+rowStart;
    //Find mean of the current row
    rowMean = std::accumulate(data+rowStart, data+rowEnd, 0.0) / float(nx);
    //Subtract each element of the current row from mean to make row zero mean
    std::transform(data+rowStart, data+rowEnd, zeroMeanVec.begin(), [&rowMean](float val){ return (val - rowMean);});
    //Find square of each element of the current row
    std::transform(zeroMeanVec.begin(), zeroMeanVec.end(), elemSqrdVec.begin(), [](float val){ return (val * val);});
    //Find normalization factor  of the current row
    normFactor = std::sqrt(std::accumulate(elemSqrdVec.begin(), elemSqrdVec.end(), 0.0));
    //Normalize the current row so that the sum of the squares of the elements of the row is 1 with zero mean
    std::transform(zeroMeanVec.begin(), zeroMeanVec.end(), zeroMeanVec.begin(), [&normFactor](float val){ return (val / normFactor);});
    //Save the normalized result in a matrix of dimension ny*nx
    std::copy(zeroMeanVec.begin(), zeroMeanVec.end(), hostIn+rowStart);
  }
  //Matrix transpose
  for (int j=0; j<ny; ++j){
    for (int i=0; i<nx; ++i){
      hostInTr[i*ny+j] = hostIn[j*nx+i];
    }
  }

  //Copy host data to GPU
  cudaMemcpy(deviceIn, hostIn, inputSize * sizeof(float), cudaMemcpyHostToDevice);
  //Copy hostTranspose data to GPU
  cudaMemcpy(deviceInTr, hostInTr, inputSize * sizeof(float), cudaMemcpyHostToDevice);
  //Kernel call
  correlationKernel<<<gridSize, blockSize>>>(deviceIn, deviceInTr, deviceOut, nx, ny);
  //Copy GPU data to host
  cudaMemcpy(result, deviceOut, outputSize * sizeof(float), cudaMemcpyDeviceToHost);
  //Free memory
  cudaFreeHost(hostIn);
  cudaFreeHost(hostInTr);
  cudaFree(deviceIn);
  cudaFree(deviceInTr);
  cudaFree(deviceOut);
}

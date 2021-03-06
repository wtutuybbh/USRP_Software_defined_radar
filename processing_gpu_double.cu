/*
    USRP_Software_defined_radar is a software for real time sampling, processing, display and storing
    Copyright (C) 2018  Jonas Myhre Christiansen <jonas-myhre.christiansen@ffi.no>
	
    This file is part of USRP_Software_defined_radar.

    USRP_Software_defined_radar is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    USRP_Software_defined_radar is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with USRP_Software_defined_radar.  If not, see <https://www.gnu.org/licenses/>.
*/

#include "processing_gpu_double.h"

__global__ void
rdComplexMultiply(cuDoubleComplex *s, cuDoubleComplex *w, long int M, long int N)
{
    long int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < N*M)
    {
        long int n = i % N;

        s[i] = cuCmul(s[i], cuConj(w[n]));
    }
}

__global__ void
rdComplexTranspose(cuDoubleComplex *sout, cuDoubleComplex *sin, long int M, long int N)
{
    long int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < N*M)
    {
        long int n = i % N;
        long int m = (long int) (i-n)/N;

        sout[m+n*M] = sin[n+m*N];
    }
}

__global__ void
cfarSetWindow(cuDoubleComplex *s, int windowLength, int guardInterval) {
    long int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i >= guardInterval && i < windowLength+guardInterval)
    {
        double winLen = (double)windowLength;
        s[i] = make_cuDoubleComplex(1 / winLen, 0);
    }
}

__global__ void
rdSquareCopy(cuDoubleComplex *sout, cuDoubleComplex *sin, long int M, long int N) {
    long int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < N*M)
    {
        double x = cuCabs(sin[i]);
        sout[i] = make_cuDoubleComplex(x*x,0);
    }
}

__global__ void
CFARComplexDivision(cuDoubleComplex *rd, cuDoubleComplex *cfar, long int M, long int N) {
    long int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < N*M)
    {
        double cfsq = sqrt(2* cuCabs(cfar[i]) / ((double)N));
        rd[i] = cuCdiv(rd[i], make_cuDoubleComplex(cfsq,0));
    }
}

void matchedFilterProcessingCUDA_gpu(cuDoubleComplex *signal, cuDoubleComplex *waveform, cuDoubleComplex *window, long int M, long int N) {
    size_t mem_size = sizeof(cuDoubleComplex)*M*N;
    long int threadsPerBlock = 256;
    long int blocksPerGrid;

    // Allocate device memory for signal
    cuDoubleComplex *d_signal, *d_waveform, *d_window;
    cudaMalloc((void **)&d_signal, mem_size);
    cudaMalloc((void **)&d_waveform, (mem_size/M));
    cudaMalloc((void **)&d_window, (mem_size/M));

    // Copy host memory to device
    cudaMemcpy(d_signal, signal, mem_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_waveform, waveform, (mem_size/M), cudaMemcpyHostToDevice);
    cudaMemcpy(d_window, window, (mem_size/M), cudaMemcpyHostToDevice);

    // Multiplying waveform with window
    blocksPerGrid =(N + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_waveform, d_window, 1, N);

    // CUFFT plan simple API
    cufftHandle plan;
    cufftPlan1d(&plan, N, CUFFT_Z2Z, M);

    // Performing device FFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_FORWARD);

    // Multiplying signal with waveform in fourier domain
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_waveform, M, N);

    // Performing device IFFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_INVERSE);

    // Copying data from device to host
    cudaMemcpy(signal, d_signal, mem_size, cudaMemcpyDeviceToHost);

    // Cleaning up
    cufftDestroy(plan);
    cudaFree(d_signal);
    cudaFree(d_waveform);
    cudaFree(d_window);
}

void dopplerProcessingCUDA_gpu(cuDoubleComplex *signal, long int M, long N) {
    size_t mem_size = sizeof(cuDoubleComplex)*M*N;

    // Allocate device memory for signal
    cuDoubleComplex *d_signal;
    cudaMalloc((void **)&d_signal, mem_size);
    // Copy host memory to device
    cudaMemcpy(d_signal, signal, mem_size, cudaMemcpyHostToDevice);

    // CUFFT plan simple API
    cufftHandle plan;
    cufftPlan1d(&plan, M, CUFFT_Z2Z, N);

    // Performing device FFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_FORWARD);

    // Copying data from device to host
    cudaMemcpy(signal, d_signal, mem_size, cudaMemcpyDeviceToHost);

    cufftDestroy(plan);
    cudaFree(d_signal);
}

void rangeDopplerProcessingCUDA_gpu(cuDoubleComplex *signal, cuDoubleComplex *waveform, cuDoubleComplex *rangeWindow, cuDoubleComplex *dopplerWindow, long int M, long int N) {
    size_t mem_size = sizeof(cuDoubleComplex)*M*N;
    long int threadsPerBlock = 1024;//3584;
    long int blocksPerGrid;

    // Allocate device memory for signal
    cuDoubleComplex *d_signal, *d_signal2, *d_waveform, *d_rangeWindow, *d_dopplerWindow;
    cudaMalloc((void **)&d_signal, mem_size);
    cudaMalloc((void **)&d_signal2, mem_size);
    cudaMalloc((void **)&d_waveform, (mem_size/M));
    cudaMalloc((void **)&d_rangeWindow, (mem_size/M));
    cudaMalloc((void **)&d_dopplerWindow, (mem_size/N));

    // Copy host memory to device
    cudaMemcpy(d_signal, signal, mem_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_waveform, waveform, (mem_size/M), cudaMemcpyHostToDevice);
    cudaMemcpy(d_rangeWindow, rangeWindow, (mem_size/M), cudaMemcpyHostToDevice);
    cudaMemcpy(d_dopplerWindow, dopplerWindow, (mem_size/N), cudaMemcpyHostToDevice);

    // Multiplying waveform with window
    blocksPerGrid =(N + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_waveform, d_rangeWindow, 1, N);

    // CUFFT plan simple API
    cufftHandle plan;
    cufftPlan1d(&plan, N, CUFFT_Z2Z, M);

    // Performing device FFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_FORWARD);

    // Multiplying signal with waveform in fourier domain
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_waveform, M, N);

    // Performing device IFFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_INVERSE);

    // Cleaning up plan
    cufftDestroy(plan);

    // Transposing data
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexTranspose<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_signal, M, N);

    // Multiplying signal with doppler window
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_dopplerWindow, N, M);

    // Doppler processing
    cufftHandle plan2;
    cufftPlan1d(&plan2, M, CUFFT_Z2Z, N);

    // Performing device FFT
    cufftExecZ2Z(plan2, (cufftDoubleComplex *)d_signal2, (cufftDoubleComplex *)d_signal2, CUFFT_FORWARD);

    // Cleaning up plan
    cufftDestroy(plan2);

    // Transposing data back
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexTranspose<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_signal2, N, M);

    // Copying data from device to host
    cudaMemcpy(signal, d_signal, mem_size, cudaMemcpyDeviceToHost);

    // Cleaning up
    cudaFree(d_signal);
    cudaFree(d_signal2);
    cudaFree(d_waveform);
    cudaFree(d_rangeWindow);
    cudaFree(d_dopplerWindow);
}

void rangeDopplerCFARProcessingCUDA_gpu(cuDoubleComplex *signal, cuDoubleComplex *waveform, cuDoubleComplex *rangeWindow, cuDoubleComplex *dopplerWindow, long int M, long int N, int windowLength, int guardInterval) {
    size_t mem_size = sizeof(cuDoubleComplex)*M*N;
    long int threadsPerBlock = 1024;//3584;
    long int blocksPerGrid;

    // Allocate device memory for signal
    cuDoubleComplex *d_signal, *d_signal2, *d_waveform, *d_rangeWindow, *d_dopplerWindow;
    cudaMalloc((void **)&d_signal, mem_size);
    cudaMalloc((void **)&d_signal2, mem_size);
    cudaMalloc((void **)&d_waveform, (mem_size/M));
    cudaMalloc((void **)&d_rangeWindow, (mem_size/M));
    cudaMalloc((void **)&d_dopplerWindow, (mem_size/N));

    // Copy host memory to device
    cudaMemcpy(d_signal, signal, mem_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_waveform, waveform, (mem_size/M), cudaMemcpyHostToDevice);
    cudaMemcpy(d_rangeWindow, rangeWindow, (mem_size/M), cudaMemcpyHostToDevice);
    cudaMemcpy(d_dopplerWindow, dopplerWindow, (mem_size/N), cudaMemcpyHostToDevice);

    // Multiplying waveform with window
    blocksPerGrid =(N + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_waveform, d_rangeWindow, 1, N);

    // CUFFT plan simple API
    cufftHandle plan;
    cufftPlan1d(&plan, N, CUFFT_Z2Z, M);

    // Performing device FFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_FORWARD);

    // Multiplying signal with waveform in fourier domain
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_waveform, M, N);

    // Performing device IFFT
    cufftExecZ2Z(plan, (cufftDoubleComplex *)d_signal, (cufftDoubleComplex *)d_signal, CUFFT_INVERSE);

    // Cleaning up plan
    cufftDestroy(plan);

    // Transposing data
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexTranspose<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_signal, M, N);

    // Multiplying signal with doppler window
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_dopplerWindow, N, M);

    // Doppler processing
    cufftHandle plan2;
    cufftPlan1d(&plan2, M, CUFFT_Z2Z, N);

    // Performing device FFT
    cufftExecZ2Z(plan2, (cufftDoubleComplex *)d_signal2, (cufftDoubleComplex *)d_signal2, CUFFT_FORWARD);

    // Cleaning up plan
    cufftDestroy(plan2);

    // Transposing data back
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexTranspose<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_signal2, N, M);

    // CFAR Processing
    // Making window
    cudaMemset(d_waveform, 0, sizeof(cuDoubleComplex)*N);
    blocksPerGrid =(windowLength+guardInterval + threadsPerBlock - 1) / threadsPerBlock;
    cfarSetWindow<<<blocksPerGrid,threadsPerBlock>>>(d_waveform, windowLength, guardInterval);

    // FFT of window
    cufftHandle plan3;
    cufftPlan1d(&plan3, N, CUFFT_Z2Z, 1);

    cufftExecZ2Z(plan3, (cufftDoubleComplex *)d_waveform, (cufftDoubleComplex *)d_waveform, CUFFT_FORWARD);
    cufftDestroy(plan2);

    // Copying and squaring RD matrix
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdSquareCopy<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_signal, M, N);

    // FFT of RD matrix
    cufftHandle plan4;
    cufftPlan1d(&plan4, N, CUFFT_Z2Z, M);

    // Performing device FFT
    cufftExecZ2Z(plan4, (cufftDoubleComplex *)d_signal2, (cufftDoubleComplex *)d_signal2, CUFFT_FORWARD);

    // Multiplying RD Matrix in fourier domain with CFAR window
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    rdComplexMultiply<<<blocksPerGrid,threadsPerBlock>>>(d_signal2, d_waveform, M, N);

    // Performing device IFFT
    cufftExecZ2Z(plan4, (cufftDoubleComplex *)d_signal2, (cufftDoubleComplex *)d_signal2, CUFFT_INVERSE);
    cufftDestroy(plan4);

    // Performing RD matrix elementwise division with CFAR matrix
    blocksPerGrid =(N*M + threadsPerBlock - 1) / threadsPerBlock;
    CFARComplexDivision<<<blocksPerGrid,threadsPerBlock>>>(d_signal, d_signal2, M, N);

    // Copying data from device to host
    cudaMemcpy(signal, d_signal, mem_size, cudaMemcpyDeviceToHost);

    // Cleaning up
    cudaFree(d_signal);
    cudaFree(d_signal2);
    cudaFree(d_waveform);
    cudaFree(d_rangeWindow);
    cudaFree(d_dopplerWindow);
}

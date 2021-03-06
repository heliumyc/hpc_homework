#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <omp.h>
#include <algorithm>

int N = 100;
int SIZE = N+2; // always N+2
int MAT_SIZE = SIZE*SIZE;
long maxIter = INT32_MAX;
double h = 1./(double) (N+1);
double hSqr = h*h;
double hSqrInverse = 1/hSqr;
int threadNum = 8;

inline double sqr(double x) {
    return x*x;
}

void Check_CUDA_Error(const char *message) {
    cudaError_t error = cudaGetLastError();
    if (error != cudaSuccess) {
        fprintf(stderr, "ERROR: %s: %s\n", message, cudaGetErrorString(error));
        exit(-1);
    }
}

double calcResidual(const double* u) {
    // since f is always 1, just hardcoded 1 into formula
    // N is actually N+2 (0-N+1)
    double res = 0;
    for (int i = 1; i <= N; ++i) {
        for (int j = 1; j <= N; ++j) {
            res += sqr((-u[(i-1)*SIZE+j]-u[i*SIZE+j-1]+4*u[i*SIZE+j]-u[(i+1)*SIZE+j]-u[i*SIZE+j+1]) * hSqrInverse - 1);
        }
    }
    return std::sqrt(res);
}

/**
 * return the iteration of jacobi
 * @return
 */
long jacobi_cpu(double* u, double* v) {
    double initResidual = calcResidual(u);
    double curResidual = 0;
    long k;
    for (k = 1; k <= maxIter; ++k) {
#   pragma omp parallel for num_threads(6)
        for (int i = 1; i <= N; ++i) {
            for (int j = 1; j <= N; ++j) {
                // update u
                v[i*SIZE+j] = (hSqr+u[(i-1)*SIZE+j]+u[i*SIZE+j-1]+u[(i+1)*SIZE+j]+u[i*SIZE+j+1])/4;
            }
        }

        std::swap(u, v);

        curResidual = calcResidual(u);
        if (initResidual/curResidual > 1e+6) {
            break;
        }
    }
    return k;
}

#define TILE_LEN 16 // block size be 16*16

__device__ double gpu_residual;

__device__ double atomicAdd2(double* address, double val)
{
    auto* address_as_ull =
            (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;

    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                        __double_as_longlong(val +
                                             __longlong_as_double(assumed)));

        // Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
    } while (assumed != old);

    return __longlong_as_double(old);
}


__global__ void gpu_residual_calc(const double* u, int n, double _hsqrinverse) {
    __shared__ double smem[TILE_LEN][TILE_LEN];
    int i = (threadIdx.x) + blockIdx.x*blockDim.x;
    int j = (threadIdx.y) + blockIdx.y*blockDim.y;

    smem[threadIdx.x][threadIdx.y] = 0;
    int size = n+2;
    if(i >= 1 && j >= 1 && i <= n && j <= n){
        double diff = (-u[(i-1)*size+j]-u[i*size+j-1]+4*u[i*size+j]-u[(i+1)*size+j]-u[i*size+j+1]) * _hsqrinverse - 1;
        diff = diff*diff;
        smem[threadIdx.x][threadIdx.y] = diff;
        __syncthreads();
    }

    if (threadIdx.y == 0) {
        double acc = 0;
        for (int k = 0; k < TILE_LEN; k++) {
            acc += smem[threadIdx.x][k];
        }
        smem[threadIdx.x][0] = acc;
        __syncthreads();
    }

    if (threadIdx.x == 0 && threadIdx.y == 0) {
        double acc = 0;
        for (int k = 0; k < TILE_LEN; k++) {
            acc += smem[k][0];
        }
        atomicAdd2(&gpu_residual, acc);
    }
}

__global__ void gpu_jacobi(double* u, double* v, int n, double hsqr) {
    int i = (threadIdx.x) + blockIdx.x*blockDim.x;
    int j = (threadIdx.y) + blockIdx.y*blockDim.y;
    int size = n+2;
    if(i >= 1 && j >= 1 && i <= n && j <= n){
        v[i*size+j] = (hsqr+u[(i-1)*size+j]+u[i*size+j-1]+u[(i+1)*size+j]+u[i*size+j+1])/4;
    }
}


int main(int argc, char** argv) {
    if (argc == 3) {
        N = (long) strtol(argv[1], nullptr, 10);
        SIZE = N+2;
        maxIter = (long) strtol(argv[2], nullptr, 10);
        if (maxIter == -1) {
            maxIter = INT32_MAX;
        }
    } else {
        printf("usage: ./program N iteration(-1 nonstop) thread_number\n");
        exit(0);
    }

    printf("Jacobi 2D\n");
    printf("=====================\n");

    double* u = (double*) malloc(SIZE*SIZE*sizeof(double));
    double* v = (double*) malloc(SIZE*SIZE*sizeof(double));
    // initialization
    for (int i = 0; i < SIZE*SIZE; ++i) {
        u[i] = 0;
        v[i] = 0;
    }

    double tick = omp_get_wtime();
    double tok;
    // jacobi start
    long cpu_iter = jacobi_cpu(u, v);
    tok = omp_get_wtime();
    printf("Openmp cpu\n");
    printf("Used time: %lf \n Iteration: %ld\n", (tok-tick), cpu_iter);

    printf("=====================\n");

    for (int k = 0; k < SIZE*SIZE; ++k) {
        u[k] = 0;
        v[k] = 0;
    }
    double* u_d;
    double* v_d;
    cudaMalloc(&u_d, SIZE*SIZE * sizeof(double));
    cudaMalloc(&v_d, SIZE*SIZE * sizeof(double));
    cudaMemcpyAsync(u_d, u, SIZE*SIZE * sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpyAsync(v_d, v, SIZE*SIZE * sizeof(double), cudaMemcpyHostToDevice);
    cudaDeviceSynchronize();
    Check_CUDA_Error("alloc cuda failed");

    dim3 grid((SIZE+TILE_LEN-1)/TILE_LEN, (SIZE+TILE_LEN-1)/TILE_LEN);
    dim3 block(TILE_LEN, TILE_LEN);

    long gpu_iter = 1;
    double init_res = 0;
    cudaMemcpyToSymbol(gpu_residual, &init_res, sizeof(double)); // load to gpu global var
    cudaMemcpyFromSymbol(&init_res, gpu_residual, sizeof(double)); // load back to init residual

    cudaDeviceSynchronize();

    tick = omp_get_wtime();
    gpu_residual_calc<<<grid, block>>>(u_d, N, hSqrInverse);
    cudaMemcpyFromSymbol(&init_res, gpu_residual, sizeof(double)); // load back to init residual
    cudaDeviceSynchronize();
    init_res = std::sqrt(init_res);

    double cur_res = 0;
    while (gpu_iter <= maxIter) {
        cur_res = 0;
        cudaMemcpyToSymbol(gpu_residual, &cur_res, sizeof(double)); // load to gpu global var that is set 0
        gpu_jacobi<<<grid, block>>>(u_d, v_d, N, hSqr);
        cudaDeviceSynchronize();
        std::swap(u_d, v_d);
        gpu_residual_calc<<<grid, block>>>(u_d, N, hSqrInverse);
        cudaMemcpyFromSymbol(&cur_res, gpu_residual, sizeof(double));
        cur_res = std::sqrt(cur_res);
        cudaDeviceSynchronize();
        if (init_res/cur_res > 1e+6) {
            break;
        }
        gpu_iter++;
    }
    tok = omp_get_wtime();
    printf("GPU\n");
    printf("Used time: %lf \n Iteration: %ld\n", (tok-tick), gpu_iter);
    printf("%Residual lf", cur_res);

    free(u);
    free(v);
    cudaFree(u_d);
    cudaFree(v_d);
}

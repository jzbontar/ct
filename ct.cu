extern "C" {
    #include "lua.h"
    #include "lualib.h"
    #include "lauxlib.h"
}

#include "luaT.h"
#include "THC.h"

#include <stdio.h>
#include <assert.h>
#include "cublas_v2.h"

#include <thrust/device_vector.h>
#include <thrust/transform.h>
#include <thrust/functional.h>

#define TB 128

cublasHandle_t handle;

/* operations */
struct opPlus {
public:
    static const float base_value = 0.0;
    __device__ float operator()(float x, float y)
    {
        return x + y;
    }
};

struct opMinus {
public:
    static const float base_value = 0.0;
    __device__ float operator()(float x, float y)
    {
        return x - y;
    }
};

struct opMult {
public:
    static const float base_value = 1.0;
    __device__ float operator()(float x, float y)
    {
        return x * y;
    }
};

struct opDiv {
public:
    static const float base_value = 1.0;
    __device__ float operator()(float x, float y)
    {
        return x / y;
    }
};

struct opMax {
public:
    static const float base_value = -2e38;
    __device__ float operator()(float x, float y)
    {
        return fmaxf(x, y);
    }
};

struct opExp {
public:
	__device__ float operator()(float x)
	{
		return exp(x);
	}
};

struct opSigmoid {
public:
	__device__ float operator()(float x)
	{
		return 1 / (1 + exp(-x));
	}
};

struct opSigmoidGrad {
public:
	__device__ float operator()(float x, float y)
	{
		return x * y * (1 - y);
	}
};

/* Is A in column major format? */
int is_cm(THCudaTensor *A)
{
	return A->stride[0] == 1;
}

int cublas_init(lua_State *L)
{
	assert(cublasCreate(&handle) == CUBLAS_STATUS_SUCCESS);
	return 0;
}

int sgemm(lua_State *L)
{
	THCudaTensor *A = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *B = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	THCudaTensor *C = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");
	int trans_A = luaL_optint(L, 4, 0);
	int trans_B = luaL_optint(L, 5, 0);
	float alpha = luaL_optnumber(L, 6, 1.0);
	float beta = luaL_optnumber(L, 7, 0.0);

	assert(trans_A == 0 || trans_A == 1);
	assert(trans_B == 0 || trans_B == 1);

	if (!(A->nDimension == 2 && B->nDimension == 2 && C->nDimension == 2)) {
		luaL_error(L, "Matrices expected");
	}

	if (!(is_cm(A) && is_cm(B) && is_cm(C))) {
		luaL_error(L, "Matrices not in column major order");
	}

	int a = A->size[trans_A];
	int b = A->size[1 - trans_A];
	int c = B->size[trans_B];
	int d = B->size[1 - trans_B];

	if (b != c || a != C->size[0] || d != C->size[1]) {
		luaL_error(L, "Size mismatch");
	}

	assert(cublasSgemm(handle,
		trans_A ? CUBLAS_OP_T : CUBLAS_OP_N,
		trans_B ? CUBLAS_OP_T : CUBLAS_OP_N,
		a, d, c, &alpha,
		THCudaTensor_data(A), A->size[0],
		THCudaTensor_data(B), B->size[0], &beta, 
		THCudaTensor_data(C), C->size[0]) == CUBLAS_STATUS_SUCCESS);
	//assert(cudaDeviceSynchronize() == CUBLAS_STATUS_SUCCESS);
	return 0;
}

int sigmoid(lua_State *L)
{
	THCudaTensor *A = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
    long len = THCudaTensor_nElement(A);
	thrust::device_ptr<float> p(THCudaTensor_data(A));
	thrust::transform(p, p + len, p, opSigmoid());
	return 0;
}

int mult_by_sigmoid_grad(lua_State *L)
{
	THCudaTensor *A = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *B = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	long len = THCudaTensor_nElement(A);

	if (!(is_cm(A) && is_cm(B))) {
		luaL_error(L, "Matrices not in column major order");
	}

	if (!(A->size[0] == B->size[0] && A->size[1] == B->size[1])) {
		luaL_error(L, "Size mismatch");
	}

	thrust::device_ptr<float> pA(THCudaTensor_data(A));
	thrust::device_ptr<float> pB(THCudaTensor_data(B));
	thrust::transform(pA, pA + len, pB, pA, opSigmoidGrad());
	return 0;
}

int _exp(lua_State *L)
{
	THCudaTensor *A = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
    long len = THCudaTensor_nElement(A);
	thrust::device_ptr<float> p(THCudaTensor_data(A));
	thrust::transform(p, p + len, p, opExp());
	return 0;
}

/* What a crazy bug!
 *
 *
 *
 *
 *
 */
template <class Op, int axis>
__global__ void kMatVect(Op op, float *A, float *x, long len, int size0)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < len) {
        if (axis == 0) A[i] = op(A[i], x[i % size0]);
        if (axis == 1) A[i] = op(A[i], x[i / size0]);
    }
}

template <class Op>
int mat_vect(Op op, lua_State *L)
{
	THCudaTensor *A = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *x = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	int axis = luaL_checkint(L, 3);

	if (!is_cm(A)) {
		luaL_error(L, "Matrix not in column major order");
	}
	
	long len = THCudaTensor_nElement(A);
    if (axis == 0) {
        if (A->size[1] != THCudaTensor_nElement(x)) {
			luaL_error(L, "Size mismatch");
        }
        kMatVect<Op, 0><<<(len - 1) / TB + 1, TB>>>(op, THCudaTensor_data(A), THCudaTensor_data(x), len, A->size[0]);
    } else if (axis == 1) {
        if (A->size[0] != THCudaTensor_nElement(x)) {
			luaL_error(L, "Size mismatch");
        }
        kMatVect<Op, 1><<<(len - 1) / TB + 1, TB>>>(op, THCudaTensor_data(A), THCudaTensor_data(x), len, A->size[0]);
    }

    cudaError_t status = cudaPeekAtLastError();
    if (status != cudaSuccess) {
		luaL_error(L, cudaGetErrorString(status));
    }
    return 0;
}

int add_mat_vect(lua_State *L)
{
    return mat_vect(opPlus(), L);
}

int sub_mat_vect(lua_State *L)
{
    return mat_vect(opMinus(), L);
}

int mult_mat_vect(lua_State *L)
{
    return mat_vect(opMult(), L);
}

int div_mat_vect(lua_State *L)
{
    return mat_vect(opDiv(), L);
}

static const struct luaL_Reg funcs[] = {
	{"cublas_init", cublas_init},
	{"sgemm", sgemm},
	{"sigmoid", sigmoid},
	{"mult_by_sigmoid_grad", sigmoid},
	{"exp", _exp},
	{"add_mat_vect", add_mat_vect},
	{"sub_mat_vect", sub_mat_vect},
	{"mult_mat_vect", mult_mat_vect},
	{"div_mat_vect", div_mat_vect},
	{NULL, NULL}
};

extern "C" int luaopen_ct(lua_State *L) {
	luaL_openlib(L, "ct", funcs, 0);
	return 1;
}
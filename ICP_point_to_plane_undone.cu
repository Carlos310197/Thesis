//For debugging:
//nvcc ICP_standard.cu -lcublas -lcurand -lcusolver -o ICP_cuda

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <time.h>
#define _USE_MATH_DEFINES
#include <math.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cublas_v2.h>
#include <curand.h>
#include <cusolverDn.h>
//#include <device_functions.h>

//constants
#define WIDTH 32
#define XY_min -2.0
#define XY_max 2.0
#define MAX_ITER 40

void SmatrixMul(float* A, float* B, float* C, int m, int n, int k);
void printScloud(float* cloud, int num_points, int points2show);
void printSarray(float* array, int points2show);
void printIarray(int* array, int points2show);

//idx has to allocate mxn values
//d has to allocate mxn values
__global__
void knn(float* Dt, int n, float* M, int m, int* idx, int k, float* d)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j, s;
	float key = 0.0f;

	for (j = 0; j < m; j++)
		d[j + i * m] = (float)sqrt(pow((Dt[0 + i * 3] - M[0 + j * 3]), 2) + pow((Dt[1 + i * 3] - M[1 + j * 3]), 2) + pow((Dt[2 + i * 3] - M[2 + j * 3]), 2));

	__syncthreads();

	//sort the distances saving the index values (insertion sort)
	//each thread is in charge of a distance sort
	float* arr = d + i * m;
	int* r = idx + i * m;
	r[0] = 0;
	for (s = 0; s < m; s++)
	{
		key = arr[s];
		j = s - 1;
		while (j >= 0 && arr[j] > key)
		{
			arr[j + 1] = arr[j];
			r[j + 1] = r[j];
			j--;
		}
		arr[j + 1] = key;
		r[j + 1] = s;
	}
}

__global__
void Normals(float* q , int* neighbors, int n, int m, int k, float* bar, float* A_total, float* normals)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = 0, stride = 0;

	//printf("%d\n", i);
	//step 1: find the centroid of the k nearest neighbors
	for (j = 1; j < k + 1; j++)
	{
		stride = neighbors[j + i * m];//neighbors are stored row-major
		bar[0 + 3 * i] += (q[0 + stride * 3] / (float)k);//q is stored colum-major (x1y1z1 ...)
		bar[1 + 3 * i] += (q[1 + stride * 3] / (float)k);
		bar[2 + 3 * i] += (q[2 + stride * 3] / (float)k);
	}
	//for (j = 0; j < 3; j++) printf("bar%d[%d]: %.3f\n", j, i, bar[j + i * 3]);
	__syncthreads();

	//step 2: find the covariance matrix A
	for (j = 1; j < k + 1; j++)
	{
		stride = neighbors[j + i * m];
		//place the values of the upper triangular matrix A only
		A_total[0 + 9 * i] += (q[0 + stride * 3] - bar[0]) * (q[0 + stride * 3] - bar[0]);
		A_total[1 + 9 * i] += (q[0 + stride * 3] - bar[0]) * (q[1 + stride * 3] - bar[1]);
		A_total[2 + 9 * i] += (q[0 + stride * 3] - bar[0]) * (q[2 + stride * 3] - bar[2]);
		A_total[4 + 9 * i] += (q[1 + stride * 3] - bar[1]) * (q[1 + stride * 3] - bar[1]);
		A_total[5 + 9 * i] += (q[1 + stride * 3] - bar[1]) * (q[2 + stride * 3] - bar[2]);
		A_total[8 + 9 * i] += (q[2 + stride * 3] - bar[2]) * (q[2 + stride * 3] - bar[2]);
	}
	__syncthreads();

	float* A = A_total + i * 9;
	//step 3: compute the eigenvectors of A
	float p1 = A[1] * A[1] + A[2] * A[2] + A[5] * A[5];
	float qi = 0.0f, p2 = 0.0f, p = 0.0f, r = 0.0f, phi = 0.0f;
	float eigen[3] = {};

	qi = (A[0] + A[4] + A[8]) / 3.0f;//trace(A)
	p2 = (A[0] - qi) * (A[0] - qi) +
		(A[4] - qi) * (A[4] - qi) +
		(A[8] - qi) * (A[8] - qi) + 2 * p1;
	p = (float)sqrt(p2 / 6.0f);
	r = ((float)1 / (2 * p * p * p)) *
		((A[0] - qi) * ((A[4] - qi) * (A[8] - qi) - A[5] * A[5])
			- A[1] * (A[1] * (A[8] - qi) - A[2] * A[5])
			+ A[2] * (A[1] * A[5] - A[2] * (A[4] - qi)));
	if (r <= -1) phi = (float)M_PI / 3.0f;
	else if (r >= 1) phi = 0.0f;
	else  phi = (float)acos(r) / 3.0f;

	//the eigenvalues satisfy eig3 <= eig2 <= eig1
	//eigen[0] = qi + 2 * p * (float)cos(phi);//eigenvalue 1
	eigen[2] = qi + 2 * p * (float)cos(phi + (2 * M_PI / 3));//eigenvalue 3
	//eigen[1] = 3 * qi - eigen[0] - eigen[2];//eigenvalue 2

	A[3] = A[1];
	A[0] -= eigen[2];
	A[4] -= eigen[2];
	float aux = A[3] / A[0];
	A[3] -= A[0] * aux;
	A[4] -= A[1] * aux;
	A[5] -= A[2] * aux;

	float eigenvector[3] = { 1.0f,1.0f,1.0f };
	eigenvector[1] = -A[5] / A[4];
	eigenvector[0] = -(A[1] * eigenvector[1] + A[2] * eigenvector[2]) / A[0];

	float modulo = sqrt(eigenvector[0] * eigenvector[0] + eigenvector[1] * eigenvector[1] + eigenvector[2] * eigenvector[2]);
	normals[0 + i * 3] = eigenvector[0]/ modulo;
	normals[1 + i * 3] = eigenvector[1]/ modulo;
	normals[2 + i * 3] = eigenvector[2] / modulo;
}

__global__
void Matching(float* Dt, float* M, int m, int* idx)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	float min = 100000;
	float d;
	for (int j = 0; j < m; j++)
	{
		d = (float)sqrt(pow((Dt[0 + i * 3] - M[0 + j * 3]), 2) + pow((Dt[1 + i * 3] - M[1 + j * 3]), 2) + pow((Dt[2 + i * 3] - M[2 + j * 3]), 2));
		if (d < min)
		{
			min = d;
			idx[i] = j;
		}
	}
}

//C has to be stored in column-major order
__global__
void Cxb(float* p, int n, float* q, int m, int* idx, float* normals, float* cn, float* C_total, float* b_total, float* C, float* b)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int stride = idx[i];
	float* aux = (float*)malloc((size_t)n * sizeof(float));
	cn[0 + i * 6] = p[1 + i * 3] * normals[2 + stride * 3] -
		p[2 + i * 3] * normals[1 + stride * 3];//cix
	cn[1 + i * 6] = p[2 + i * 3] * normals[0 + stride * 3] -
		p[0 + i * 3] * normals[2 + stride * 3];//ciy
	cn[2 + i * 6] = p[0 + i * 3] * normals[1 + stride * 3] -
		p[1 + i * 3] * normals[0 + stride * 3];//ciz
	cn[3 + i * 6] = normals[0 + stride * 3];//nix
	cn[4 + i * 6] = normals[1 + stride * 3];//niy
	cn[5 + i * 6] = normals[2 + stride * 3];//niz

	C_total[0 + i * 21] = cn[0 + i * 6] * cn[0 + i * 6]; C_total[1 + i * 21] = cn[0 + i * 6] * cn[1 + i * 6]; C_total[2 + i * 21] = cn[0 + i * 6] * cn[2 + i * 6];
	C_total[3 + i * 21] = cn[0 + i * 6] * cn[3 + i * 6]; C_total[4 + i * 21] = cn[0 + i * 6] * cn[4 + i * 6]; C_total[5 + i * 21] = cn[0 + i * 6] * cn[5 + i * 6];
	C_total[6 + i * 21] = cn[1 + i * 6] * cn[1 + i * 6]; C_total[7 + i * 21] = cn[1 + i * 6] * cn[2 + i * 6]; C_total[8 + i * 21] = cn[1 + i * 6] * cn[3 + i * 6];
	C_total[9 + i * 21] = cn[1 + i * 6] * cn[4 + i * 6]; C_total[10 + i * 21] = cn[1 + i * 6] * cn[5 + i * 6]; C_total[11 + i * 21] = cn[2 + i * 6] * cn[2 + i * 6];
	C_total[12 + i * 21] = cn[2 + i * 6] * cn[3 + i * 6]; C_total[13 + i * 21] = cn[2 + i * 6] * cn[4 + i * 6]; C_total[14 + i * 21] = cn[2 + i * 6] * cn[5 + i * 6];
	C_total[15 + i * 21] = cn[3 + i * 6] * cn[3 + i * 6]; C_total[16 + i * 21] = cn[3 + i * 6] * cn[4 + i * 6]; C_total[17 + i * 21] = cn[3 + i * 6] * cn[5 + i * 6];
	C_total[18 + i * 21] = cn[4 + i * 6] * cn[4 + i * 6]; C_total[19 + i * 21] = cn[4 + i * 6] * cn[5 + i * 6]; C_total[20 + i * 21] = cn[5 + i * 6] * cn[5 + i * 6];

	aux[i] = (p[0 + i * 3] - q[0 + i * 3]) * cn[3 + i * 6] +
		(p[1 + i * 3] - q[1 + i * 3]) * cn[4 + i * 6] +
		(p[2 + i * 3] - q[2 + i * 3]) * cn[5 + i * 6];

	b_total[0 + i * 6] = cn[0 + i * 6] * aux[i]; b_total[1 + i * 6] = cn[1 + i * 6] * aux[i]; b_total[2 + i * 6] = cn[2 + i * 6] * aux[i];
	b_total[3 + i * 6] = cn[3 + i * 6] * aux[i]; b_total[4 + i * 6] = cn[4 + i * 6] * aux[i]; b_total[5 + i * 6] = cn[5 + i * 6] * aux[i];
	__syncthreads();

	for (int s = 1; s < n; s *= 2)//parallel reduction
	{
		if (i % (2 * s) == 0)
		{
			//C
			C_total[0 + i * 21] += C_total[0 + (i + s) * 21]; C_total[1 + i * 21] += C_total[1 + (i + s) * 21]; C_total[2 + i * 21] += C_total[2 + (i + s) * 21];
			C_total[3 + i * 21] += C_total[3 + (i + s) * 21]; C_total[4 + i * 21] += C_total[4 + (i + s) * 21]; C_total[5 + i * 21] += C_total[5 + (i + s) * 21];
			C_total[6 + i * 21] += C_total[6 + (i + s) * 21]; C_total[7 + i * 21] += C_total[7 + (i + s) * 21]; C_total[8 + i * 21] += C_total[8 + (i + s) * 21];
			C_total[9 + i * 21] += C_total[9 + (i + s) * 21]; C_total[10 + i * 21] += C_total[10 + (i + s) * 21]; C_total[11 + i * 21] += C_total[11 + (i + s) * 21];
			C_total[12 + i * 21] += C_total[12 + (i + s) * 21]; C_total[13 + i * 21] += C_total[13 + (i + s) * 21]; C_total[14 + i * 21] += C_total[14 + (i + s) * 21];
			C_total[15 + i * 21] += C_total[15 + (i + s) * 21]; C_total[16 + i * 21] += C_total[16 + (i + s) * 21]; C_total[17 + i * 21] += C_total[17 + (i + s) * 21];
			C_total[18 + i * 21] += C_total[18 + (i + s) * 21]; C_total[19 + i * 21] += C_total[19 + (i + s) * 21]; C_total[20 + i * 21] += C_total[20 + (i + s) * 21];

			//b
			b_total[0 + i * 6] += b_total[0 + (i + s) * 6]; b_total[1 + i * 6] += b_total[1 + (i + s) * 6]; b_total[2 + i * 6] += b_total[2 + (i + s) * 6];
			b_total[3 + i * 6] += b_total[3 + (i + s) * 6]; b_total[4 + i * 6] += b_total[4 + (i + s) * 6]; b_total[5 + i * 6] += b_total[5 + (i + s) * 6];
		}
		__syncthreads();
	}

	if (i == 0)
	{
		//C
		C[0] = C_total[0 + i * 21]; C[6] = C_total[1 + i * 21]; C[12] = C_total[2 + i * 21]; C[18] = C_total[3 + i * 21]; C[24] = C_total[4 + i * 21]; C[30] = C_total[5 + i * 21];
		C[7] = C_total[6 + i * 21]; C[13] = C_total[7 + i * 21]; C[19] = C_total[8 + i * 21]; C[25] = C_total[9 + i * 21]; C[31] = C_total[10 + i * 21];
		C[14] = C_total[11 + i * 21]; C[20] = C_total[12 + i * 21]; C[26] = C_total[13 + i * 21]; C[32] = C_total[14 + i * 21];
		C[21] = C_total[15 + i * 21]; C[27] = C_total[16 + i * 21]; C[33] = C_total[17 + i * 21];
		C[28] = C_total[18 + i * 21]; C[34] = C_total[19 + i * 21];
		C[35] = C_total[20 + i * 21];

		//b
		b[0] = b_total[0 + i * 6]; b[1] = b_total[1 + i * 6]; b[2] = b_total[2 + i * 6];
		b[3] = b_total[3 + i * 6]; b[4] = b_total[4 + i * 6]; b[5] = b_total[5 + i * 6];
		b[6] = b_total[6 + i * 6]; b[7] = b_total[7 + i * 6]; b[6] = b_total[0 + i * 6];
	}
	free(aux);
}

__global__
void RyT(float* R, float* T, float* P, float* Q)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	Q[0 + i * 3] = R[0 + 0 * 3] * P[0 + i * 3] + R[0 + 1 * 3] * P[1 + i * 3] + R[0 + 2 * 3] * P[2 + i * 3] + T[0];
	Q[1 + i * 3] = R[1 + 0 * 3] * P[0 + i * 3] + R[1 + 1 * 3] * P[1 + i * 3] + R[1 + 2 * 3] * P[2 + i * 3] + T[1];
	Q[2 + i * 3] = R[2 + 0 * 3] * P[0 + i * 3] + R[2 + 1 * 3] * P[1 + i * 3] + R[2 + 2 * 3] * P[2 + i * 3] + T[2];
}

__global__
void Error(int n, float* aux, float* D, float* M, int* idx, float* error, int iteration)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;

	aux[0 + i * 3] = pow(M[0 + idx[i] * 3] - D[0 + i * 3], 2);
	aux[1 + i * 3] = pow(M[1 + idx[i] * 3] - D[1 + i * 3], 2);
	aux[2 + i * 3] = pow(M[2 + idx[i] * 3] - D[2 + i * 3], 2);
	__syncthreads();

	for (int s = 1; s < n; s *= 2)//parallel reduction
	{
		if (i % (2 * s) == 0)
		{
			aux[0 + i * 3] += aux[0 + (i + s) * 3];
			aux[1 + i * 3] += aux[1 + (i + s) * 3];
			aux[2 + i * 3] += aux[2 + (i + s) * 3];
		}
		__syncthreads();
	}

	if (i == 0)
	{
		error[iteration] = (float)sqrt((aux[0] + aux[1] + aux[2]) / (float)n);
		//printf("Error: %f\n",error[iteration]);
	}
}

int main(void)
{
	int num_points, i, j, k;
	float ti[3], ri[3];
	float lin_space[WIDTH], lenght;

	num_points = WIDTH * WIDTH;//number of points
	lenght = XY_max - XY_min;

	//for this specific case the number of points of the 2 clouds are the same
	int d_points = num_points;
	int m_points = num_points;

	////////////////1st:Creation of the synthetic data//////////////

	//create an array with all points equally separated
	int n = WIDTH;
	for (i = 0; i < WIDTH; i++)
	{
		lin_space[i] = (float)XY_min + ((float)i * (float)lenght) / (float(n) - 1.0f);
	}

	//create the meshgrid
	float* mesh_x = (float*)malloc(num_points * sizeof(float));
	float* mesh_y = (float*)malloc(num_points * sizeof(float));

	if ((mesh_x != NULL) && (mesh_y != NULL))
	{
		i = 0;
		k = 0;
		while (i < num_points)
		{
			j = 0;
			while (j < WIDTH)
			{
				mesh_y[i] = lin_space[j];
				mesh_x[i] = lin_space[k];
				i++; j++;
			}
			k++;
		}
	}
	else return 0;

	//Create the function z = f(x,y) = x^2-y^2
	float* z = (float*)malloc(num_points * sizeof(float));
	for (i = 0; i < num_points; i++) z[i] = pow(mesh_x[i], 2) - pow(mesh_y[i], 2);

	//Create data point cloud matrix
	size_t bytesD = (size_t)d_points * (size_t)3 * sizeof(float);
	float* h_D = (float*)malloc(bytesD);

	k = 0;
	for (i = 0; i < num_points; i++)
	{
		for (j = 0; j < 3; j++)
		{
			if (j == 0) h_D[k] = mesh_x[i];
			if (j == 1) h_D[k] = mesh_y[i];
			if (j == 2) h_D[k] = z[i];
			k++;
		}
	}

	//printf("Data point cloud\n");
	//printScloud(h_D, num_points, num_points);

	//Translation values
	ti[0] = 0.8f;//x
	ti[1] = -0.3f;//y
	ti[2] = 0.2f;//z

	//Rotation values (rad)
	ri[0] = 0.1f;//axis x
	ri[1] = -0.1f;//axis y
	ri[2] = 0.05f;//axis z

	float h_r[9] = {};
	float cx = (float)cos(ri[0]); float cy = (float)cos(ri[1]); float cz = (float)cos(ri[2]);
	float sx = (float)sin(ri[0]); float sy = (float)sin(ri[1]); float sz = (float)sin(ri[2]);
	h_r[0] = cy * cz; h_r[1] = (cz * sx * sy) + (cx * sz); h_r[2] = -(cx * cz * sy) + (sx * sz);
	h_r[3] = -cy * sz; h_r[4] = (cx * cz) - (sx * sy * sz); h_r[5] = (cx * sy * sz) + (cz * sx);
	h_r[6] = sy; h_r[7] = -cy * sx; h_r[8] = cx * cy;
	//printf("Ri:\n");
	//printScloud(h_r,3,3);

	//Create model point cloud matrix (target point cloud)
	//every matrix is defined using the colum-major order
	size_t bytesM = (size_t)m_points * (size_t)3 * sizeof(float);
	float* h_M = (float*)malloc(bytesM);

	//h_M = h_r*h_D
	SmatrixMul(h_r, h_D, h_M, 3, num_points, 3);
	//h_M = h_M + t
	for (i = 0; i < num_points; i++)
	{
		for (j = 0; j < 3; j++)
		{
			h_M[j + i * 3] += ti[j];
		}
	}
	//printf("\nModel point cloud\n");
	//printScloud(h_M, m_points, m_points);

	/////////End of 1st/////////

	//since this lines 
	//p assumes the value of D
	//q assumes the value of M
	//number of p and q points
	int p_points = d_points;
	int q_points = m_points;
	float* d_p, * d_q;
	cudaMalloc(&d_p, bytesD);//p points cloud
	cudaMalloc(&d_q, bytesM);//p points cloud//q point cloud
	//transfer data from D and M to p and q
	cudaMemcpy(d_p, h_D, bytesD, cudaMemcpyHostToDevice);//copy data cloud to p
	cudaMemcpy(d_q, h_M, bytesM, cudaMemcpyHostToDevice);//copy model cloud to q
	cudaError_t err = cudaSuccess;//for checking errors in kernels

	/////////2nd: Normals estimation/////////
	int GridSize = 8;
	int BlockSize = q_points / GridSize;
	printf("For normals:\nGrid Size: %d, Block Size: %d\n", GridSize, BlockSize);

	int* d_NeighborIds = NULL;
	float* d_dist = NULL;
	size_t neighbors_size = (size_t)p_points * (size_t)q_points * sizeof(int);
	cudaMalloc(&d_NeighborIds, neighbors_size);
	cudaMalloc(&d_dist, (size_t)p_points * (size_t)q_points * sizeof(float));
	k = 4;//number of nearest neighbors
	float* d_bar, * d_A;
	cudaMalloc(&d_bar, bytesM);
	cudaMalloc(&d_A, (size_t)9 * (size_t)q_points * sizeof(float));
	float* h_A = (float*)malloc((size_t)9 * (size_t)q_points * sizeof(float));
	cudaMemset(d_bar, 0, bytesM * sizeof(float));
	cudaMemset(d_A, 0, (size_t)9 * (size_t)q_points * sizeof(float));

	float* d_normals = NULL;
	cudaMalloc(&d_normals, bytesM);
	float* h_normals = (float*)malloc(bytesM);

	//cudaEventRecord(start);//start time normals estimation
	knn <<< GridSize, BlockSize >>> (d_q, q_points, d_q, q_points, d_NeighborIds, k + 1, d_dist);
	err = cudaGetLastError();
	if (err != cudaSuccess)
		printf("Error in knn kernel: %s\n", cudaGetErrorString(err));
	cudaDeviceSynchronize();
	int* h_NeighborIds = (int*)malloc(neighbors_size);
	cudaMemcpy(h_NeighborIds, d_NeighborIds, neighbors_size, cudaMemcpyDeviceToHost);
	/*printf("Neighbor IDs:\n");
	for (i = 0; i < p_points; i++)
	{
		printf("%d: ", i + 1);
		for (j = 0; j < k + 1; j++) printf("%d ", h_NeighborIds[j + i * q_points] + 1);
		printf("\n");
	}
	printf("\n");*/
	Normals <<< GridSize, BlockSize >>> (d_q, d_NeighborIds, p_points, q_points, k, d_bar, d_A, d_normals);
	err = cudaGetLastError();
	if (err != cudaSuccess)
		printf("Error in normals kernel: %s\n", cudaGetErrorString(err));
	cudaDeviceSynchronize();
	cudaMemcpy(h_A, d_A, (size_t)9 * (size_t)q_points * sizeof(float), cudaMemcpyDeviceToHost);
	for (i = 0; i < q_points; i++)
	{
		printf("A[%d]:\n", i + 1);
		for (j = 0; j < 3; j++)
		{
			for (int u = 0; u < 3; u++) printf("%.4f ", h_A[j + u]);
			printf("\n");
		}
		printf("\n");
	}


	cudaMemcpy(h_normals, d_normals, bytesM, cudaMemcpyDeviceToHost);
	/*printf("Normals:\n");
	for (i = 0; i < q_points; i++)
	{
		printf("%d: ", i + 1);
		for (j = 0; j < 3; j++) printf("%.4f ", h_normals[j + i * 3]);
		printf("\n");
	}
	printf("\n");*/
	/////////End of 2nd/////////

	free(mesh_x), free(mesh_y), free(z);
	free(h_M), free(h_D);
	cudaFree(d_p), cudaFree(d_q);// cudaFree(d_aux);
	cudaFree(d_NeighborIds), cudaFree(d_dist);free(h_NeighborIds);
	cudaFree(d_bar), cudaFree(d_A);
	cudaFree(d_normals); //free(h_normals);
	//cudaFree(d_idx); //free(h_idx);
	//cudaFree(d_error);
	//cudaFree(d_work), cudaFree(devInfo);
	//cudaFree(d_C), cudaFree(d_b), free(h_b);
	//cudaFree(d_cn), cudaFree(d_C_total), cudaFree(d_b_total);
	//cudaFree(d_temp_r), cudaFree(d_temp_T), free(h_temp_r), free(h_temp_T);

	return 0;
}

//double matrix multiplication colum-major order
void SmatrixMul(float* A, float* B, float* C, int m, int n, int k)
{
	int i, j, q;
	float temp = 0.0f;
	for (i = 0; i < n; i++)
	{
		for (j = 0; j < m; j++)
		{
			temp = 0.0f;
			for (q = 0; q < k; q++) temp += A[j + q * m] * B[q + i * k];
			C[j + i * m] = temp;
		}
	}
}

//print matrix
void printScloud(float* cloud, int num_points, int points2show)
{
	int i, j, offset;
	printf("x\ty\tz\n");
	if (points2show <= num_points)
	{
		for (i = 0; i < points2show; i++)
		{
			for (j = 0; j < 3; j++)
			{
				offset = j + i * 3;
				printf("%.4f\t", cloud[offset]);
				if (j % 3 == 2) printf("\n");
			}
		}
	}
	else printf("The cloud can't be printed\n\n");
}

//print vector with double values
void printSarray(float* array, int points2show)
{
	int i;
	for (i = 0; i < points2show; i++)
	{
		printf("%.4f ", array[i]);
	}
	printf("\n");
}

//print vector with integer values
void printIarray(int* array, int points2show)
{
	int i;
	for (i = 0; i < points2show; i++)
	{
		printf("%d ", array[i]);
	}
	printf("\n");
}
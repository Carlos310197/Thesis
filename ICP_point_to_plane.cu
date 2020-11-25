//For debugging:
//nvcc ICP_standard.cu -lcublas -lcurand -lcusolver -o ICP_cuda

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <time.h>
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

int main()
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
	ti[0] = 1.0f;//x
	ti[1] = -0.3f;//y
	ti[2] = 0.2f;//z

	//Rotation values (rad)
	ri[0] = 1.0f;//axis x
	ri[1] = -0.5f;//axis y
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
	//printScloud(h_M, NUM_POINTS, NUM_POINTS);

	/////////End of 1st/////////

	/////////2nd: Normals estimation/////////



	/////////End of 2nd/////////

	free(mesh_x), free(mesh_y), free(z);
	free(h_M), free(h_D);
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
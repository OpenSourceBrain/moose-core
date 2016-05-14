#include <stdio.h>
#include <stdlib.h>
#include <vector>
#include <algorithm>

#include "CudaGlobal.h"

#include "RateLookup.h"
#include "HSolveActive.h"

#ifdef USE_CUDA

#include "Gpu_timer.h"

#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/system/system_error.h>
#include <thrust/copy.h>


__global__
void get_lookup_rows_and_fractions_cuda(
		double* lookups,
		double* table,
		double min, double max, double dx,
		int* rows, double* fracs,
		unsigned int nColumns, unsigned int size){

	int tid = threadIdx.x + blockIdx.x * blockDim.x;

	if(tid < size){
		double x = lookups[tid];

		if ( x < min )
			x = min;
		else if ( x > max )
			x = max;

		double div = ( x - min ) / dx;
		unsigned int integer = ( unsigned int )( div );

		rows[tid] = integer*nColumns;
		fracs[tid] = div-integer;
	}
}

__global__
void advance_channels_cuda(
		int* rows,
		double* fracs,
		double* table,
		int* expand_indices,
		int* gate_to_comp,
		double* gate_values,
		int* gate_columns,
		int* chan_instants,
		unsigned int nColumns,
		double dt,
		int size
		){
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size){
		double a,b,C1,C2;
		int index, lookup_index, row_start_index, column;

		index = expand_indices[tid];
		lookup_index = gate_to_comp[tid];
		row_start_index = rows[lookup_index];
		column = gate_columns[index];

		a = table[row_start_index + column];
		b = table[row_start_index + column + nColumns];

		C1 = a + (b-a)*fracs[lookup_index];

		a = table[row_start_index + column + 1];
		b = table[row_start_index + column + 1 + nColumns];

		C2 = a + (b-a)*fracs[lookup_index];

		if(!chan_instants[index/3]){ // tid/3 bcos #gates = 3*#chans
			a = 1.0 + dt/2.0 * C2; // reusing a
			gate_values[index] = ( gate_values[index] * ( 2.0 - a ) + dt * C1 ) / a;
		}
		else{
			gate_values[index] = C1/C2;
		}
	}
}

__global__
void get_compressed_gate_values(double* expanded_array,
		int* expanded_indices, double* d_cmprsd_state, int size){
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size)
		d_cmprsd_state[tid] = expanded_array[expanded_indices[tid]];
}

__global__
void calculate_channel_currents(double* d_gate_values,
		double* d_gate_powers,
		double* d_chan_modulation,
		double* d_chan_Gbar,
		CurrentStruct* d_current_,
		double* d_chan_Gk,
		double* d_chan_GkEk,
		int size){
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size){
		double temp = d_chan_modulation[tid] *
				 d_chan_Gbar[tid] *
				 pow(d_gate_values[3*tid], d_gate_powers[3*tid]) *
				 pow(d_gate_values[3*tid+1], d_gate_powers[3*tid+1]) *
				 pow(d_gate_values[3*tid+2], d_gate_powers[3*tid+2]);

		d_current_[tid].Gk = temp;
		d_chan_Gk[tid] = temp;
		d_chan_GkEk[tid] = temp*d_current_[tid].Ek;
	}
}

__global__
void populating_expand_indices(int* d_keys, double* d_values, double* d_expand_values, int size){
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size){
		d_expand_values[d_keys[tid]] = d_values[tid];
	}
}

__global__
void update_matrix_kernel(double* d_V,
		double* d_HS_,
		double* d_comp_Gksum,
		double* d_comp_GkEksum,
		CompartmentStruct* d_compartment_,
		InjectStruct* d_inject_,
		double*	d_externalCurrent_,
		int size){

	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size){
		d_HS_[4*tid] = d_HS_[4*tid+2] + d_comp_Gksum[tid] + d_externalCurrent_[2*tid];
		d_HS_[4*tid+3] = d_V[tid]*d_compartment_[tid].CmByDt + d_compartment_[tid].EmByRm + d_comp_GkEksum[tid] +
				(d_inject_[tid].injectVarying + d_inject_[tid].injectBasal) + d_externalCurrent_[2*tid+1];

		d_inject_[tid].injectVarying = 0;
	}
}

__global__
void update_csr_matrix_kernel(double* d_V,
				double* d_mat_values, double* d_main_diag_passive, int* d_main_diag_map, double* d_tridiag_data, double* d_b,
				double* d_comp_Gksum,
				double* d_comp_GkEksum,
				CompartmentStruct* d_compartment_,
				InjectStruct* d_inject_,
				double*	d_externalCurrent_,
				int size){
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < size){
		double main_val = d_main_diag_passive[tid] + d_comp_Gksum[tid] + d_externalCurrent_[2*tid];
		d_mat_values[d_main_diag_map[tid]] = main_val;
		d_tridiag_data[size + tid] = main_val;
		d_b[tid] = d_V[tid]*d_compartment_[tid].CmByDt + d_compartment_[tid].EmByRm + d_comp_GkEksum[tid] +
				(d_inject_[tid].injectVarying + d_inject_[tid].injectBasal) + d_externalCurrent_[2*tid+1];

		d_inject_[tid].injectVarying = 0;
	}
}

__global__
void calculate_V_from_Vmid(double* d_Vmid, double* d_V, int size){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	if(tid < size){
		d_V[tid] = 2*d_Vmid[tid] - d_V[tid];
	}
}

__global__
void advance_calcium_cuda(int* d_catarget_channel_indices,
			double* d_chan_Gk, double* d_chan_GkEk,
			double* d_Vmid,
			double* d_capool_values, int* d_chan_to_comp,
			int size){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	if(tid < size){
		int chan_id = d_catarget_channel_indices[tid];
		d_capool_values[tid] = d_chan_GkEk[chan_id] - d_chan_Gk[chan_id]*d_Vmid[d_chan_to_comp[chan_id]];
	}
}

__global__
void advance_calcium_conc_cuda(CaConcStruct* d_caConc_, double* d_Ca, double* d_caActivation_values, int size ){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	if(tid < size){
		d_caConc_[tid].c_ = d_caConc_[tid].factor1_ * d_caConc_[tid].c_ + d_caConc_[tid].factor2_ * d_caActivation_values[tid];
		double new_ca = d_caConc_[tid].CaBasal_ + d_caConc_[tid].c_;

		if(new_ca >  d_caConc_[tid].ceiling_){
			new_ca = d_caConc_[tid].ceiling_;
			d_caConc_[tid].c_ = new_ca - d_caConc_[tid].ceiling_;
		}
		if(new_ca < d_caConc_[tid].floor_){
			new_ca = d_caConc_[tid].floor_;
			d_caConc_[tid].c_ = new_ca - d_caConc_[tid].floor_;
		}
		d_Ca[tid] = new_ca;
	}
}


void HSolveActive::get_lookup_rows_and_fractions_cuda_wrapper(double dt){

	int num_comps = V_.size();
	int num_Ca_pools = ca_.size();

	int BLOCKS = num_comps/THREADS_PER_BLOCK;
	BLOCKS = (num_comps%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	// Getting lookup metadata for Vm
	get_lookup_rows_and_fractions_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(d_V,
    		d_V_table,
    		vTable_.get_min(), vTable_.get_max(), vTable_.get_dx(),
    		d_V_rows, d_V_fractions,
    		vTable_.get_num_of_columns(), num_comps);

	// Getting lookup metadata from Ca pools
	get_lookup_rows_and_fractions_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(d_ca,
			d_Ca_table,
			caTable_.get_min(), caTable_.get_max(), caTable_.get_dx(),
			d_Ca_rows, d_Ca_fractions,
			caTable_.get_num_of_columns(), num_Ca_pools);

	cudaCheckError(); // Checking for cuda related errors.
}


void HSolveActive::advance_channels_cuda_wrapper(double dt){

	int num_vdep_gates = h_vgate_expand_indices.size();
	int num_cadep_gates = h_cagate_expand_indices.size();

    // Get the Row number and fraction values of Vm's from vTable
    int BLOCKS;
	BLOCKS = num_vdep_gates/THREADS_PER_BLOCK;
	BLOCKS = (num_vdep_gates%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	// For V dependent gates
	advance_channels_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(
			d_V_rows,
			d_V_fractions,
			d_V_table,
			d_vgate_expand_indices,
			d_vgate_compt_indices,
			d_gate_values,
			d_gate_columns,
			d_chan_instant,
			vTable_.get_num_of_columns(),
			dt, num_vdep_gates );

	if(num_cadep_gates > 0){
		BLOCKS = num_cadep_gates/THREADS_PER_BLOCK;
		BLOCKS = (num_cadep_gates%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

		// For Ca dependent gates.
		advance_channels_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(
				d_Ca_rows,
				d_Ca_fractions,
				d_Ca_table,
				d_cagate_expand_indices,
				d_cagate_capool_indices,
				d_gate_values,
				d_gate_columns,
				d_chan_instant,
				caTable_.get_num_of_columns(),
				dt, num_cadep_gates );
	}

	cudaCheckError(); // Checking for cuda related errors.
}


void HSolveActive::get_compressed_gate_values_wrapper(){

	int num_cmprsd_gates = state_.size();

	int BLOCKS = num_cmprsd_gates/THREADS_PER_BLOCK;
	BLOCKS = (num_cmprsd_gates%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	get_compressed_gate_values<<<BLOCKS,THREADS_PER_BLOCK>>>(
			d_gate_values,
			d_gate_expand_indices,
			d_state_,
			num_cmprsd_gates);

	cudaCheckError(); // Checking for cuda related errors.

}

void HSolveActive::calculate_channel_currents_cuda_wrapper(){
	int num_channels = channel_.size();

	int BLOCKS = num_channels/THREADS_PER_BLOCK;
	BLOCKS = (num_channels%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	calculate_channel_currents<<<BLOCKS,THREADS_PER_BLOCK>>>(
			d_gate_values,
			d_gate_powers,
			d_chan_modulation,
			d_chan_Gbar,
			d_current_,
			d_chan_Gk, d_chan_GkEk, num_channels);

	cudaCheckError(); // Checking for cuda related errors.
}

void HSolveActive::update_matrix_cuda_wrapper(){

	int num_channels = channel_.size();

	// Using Cusparse
	const double alpha = 1.0;
	const double beta = 0.0;

	cusparseDcsrmv(cusparse_handle,  CUSPARSE_OPERATION_NON_TRANSPOSE,
		nCompt_, nCompt_, num_channels, &alpha, cusparse_descr,
		d_chan_Gk, d_chan_rowPtr, d_chan_colIndex,
		d_chan_x , &beta, d_comp_Gksum);

	cusparseDcsrmv(cusparse_handle,  CUSPARSE_OPERATION_NON_TRANSPOSE,
		nCompt_, nCompt_, num_channels, &alpha, cusparse_descr,
		d_chan_GkEk, d_chan_rowPtr, d_chan_colIndex,
		d_chan_x , &beta, d_comp_GkEksum);

	// -----------------------------------------------CUSPARSE------------------------------------------------

	int BLOCKS = nCompt_/THREADS_PER_BLOCK;
	BLOCKS = (nCompt_%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	cudaMemcpy(d_inject_, &inject_[0], nCompt_*sizeof(InjectStruct), cudaMemcpyHostToDevice);
	cudaMemcpy(d_externalCurrent_, &(externalCurrent_.front()), 2 * nCompt_ * sizeof(double), cudaMemcpyHostToDevice);
	//cudaMemcpy(d_HS_, &HS_[0], HS_.size()*sizeof(double), cudaMemcpyHostToDevice);

	update_matrix_kernel<<<BLOCKS, THREADS_PER_BLOCK>>>(d_V,
			d_HS_,
			d_comp_Gksum,
			d_comp_GkEksum,
			d_compartment_,
			d_inject_,
			d_externalCurrent_,
			(int)nCompt_);

	cudaMemcpy(&inject_[0], d_inject_, nCompt_*sizeof(InjectStruct), cudaMemcpyDeviceToHost );
	cudaMemcpy(&HS_[0], d_HS_, HS_.size()*sizeof(double), cudaMemcpyDeviceToHost );

}

void HSolveActive::update_csrmatrix_cuda_wrapper(){
	// ---------------------------- GKSum & GkEkSum ---------------------------------------
	int num_channels = channel_.size();
	// Using Cusparse
	const double alpha_ = 1.0;
	const double beta_ = 0.0;

	cusparseDcsrmv(cusparse_handle,  CUSPARSE_OPERATION_NON_TRANSPOSE,
		nCompt_, nCompt_, num_channels, &alpha_, cusparse_descr,
		d_chan_Gk, d_chan_rowPtr, d_chan_colIndex,
		d_chan_x , &beta_, d_comp_Gksum);

	cusparseDcsrmv(cusparse_handle,  CUSPARSE_OPERATION_NON_TRANSPOSE,
		nCompt_, nCompt_, num_channels, &alpha_, cusparse_descr,
		d_chan_GkEk, d_chan_rowPtr, d_chan_colIndex,
		d_chan_x , &beta_, d_comp_GkEksum);


	// ----------------------------- UPDATE MATRIX ----------------------------------------
	int BLOCKS = nCompt_/THREADS_PER_BLOCK;
	BLOCKS = (nCompt_%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	cudaMemcpy(d_inject_, &inject_[0], nCompt_*sizeof(InjectStruct), cudaMemcpyHostToDevice);
	cudaMemcpy(d_externalCurrent_, &(externalCurrent_.front()), 2 * nCompt_ * sizeof(double), cudaMemcpyHostToDevice);

	update_csr_matrix_kernel<<<BLOCKS, THREADS_PER_BLOCK>>>(d_V,
			d_mat_values, d_main_diag_passive, d_main_diag_map, d_tridiag_data, d_b,
			d_comp_Gksum,
			d_comp_GkEksum,
			d_compartment_,
			d_inject_,
			d_externalCurrent_,
			(int)nCompt_);

	cudaMemcpy(&inject_[0], d_inject_, nCompt_*sizeof(InjectStruct), cudaMemcpyDeviceToHost );

}


void HSolveActive::hinesMatrixSolverWrapper(){
	// ---------------------- USING CUSOLVER LOW LEVEL LU SOLVER ---------------------------------------
	int BLOCKS = nCompt_/THREADS_PER_BLOCK;
	BLOCKS = (nCompt_%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	// copy updated matrix values back to CPU
	GpuTimer solverTimer;

	double pivot_thresh = 0; // No pivoting
	cusolverStatus_t cusolver_status;

	solverTimer.Start();

	cudaMemcpy(h_mat_values, d_mat_values, mat_nnz*sizeof(double), cudaMemcpyDeviceToHost);
	cudaMemcpy(h_b, d_b, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);

	cusolver_status = cusolverSpDcsrluFactorHost(cusolver_handle, nCompt_, mat_nnz, cusparse_descr, h_mat_values, h_mat_rowPtr, h_mat_colIndex,
			infoA, pivot_thresh ,workspaceBuffer);
	//cout << "Factorization " << cusolver_status << endl;

	cusolver_status = cusolverSpDcsrluSolveHost(cusolver_handle, nCompt_, h_b, &(VMid_[0]), infoA, internalBuffer);

	cudaMemcpy(d_Vmid, &(VMid_[0]) , nCompt_*sizeof(double), cudaMemcpyHostToDevice);
	calculate_V_from_Vmid<<<BLOCKS,THREADS_PER_BLOCK>>>(d_Vmid, d_V, nCompt_);
	//cudaMemcpy(&(V_[0]), d_V, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);

	solverTimer.Stop();


	/* ---------------------- USING CUSOLVER HIGH LEVEL LU SOLVER ---------------------------------------
	// Updating HS_ data
	cudaMemcpy(h_mat_values, d_mat_values, mat_nnz*sizeof(double), cudaMemcpyDeviceToHost);
	cudaMemcpy(h_b, d_b, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);

	for(int i=0;i<nCompt_;i++){
		HS_[4*i] = h_mat_values[h_main_diag_map[i]];
		HS_[4*i+3] = h_b[i];
	}

	HSolvePassive::forwardEliminate();
	HSolvePassive::backwardSubstitute();
	*/

	/*
	double tol = 0.1;
	int reorder = 0;
	int singularity;

	// Solve using cusparseDcsrlu host method
	cusolverStatus_t cusolver_status = cusolverSpDcsrlsvluHost(cusolver_handle,
			nCompt_,
			mat_nnz,
			cusparse_descr,
			h_mat_values,
			h_mat_rowPtr,
			h_mat_colIndex,
			h_b, tol, reorder,
			&(VMid_[0]), &singularity);

	cudaMemcpy(d_Vmid, &(VMid_[0]) , nCompt_*sizeof(double), cudaMemcpyHostToDevice);
	calculate_V_from_Vmid<<<BLOCKS,THREADS_PER_BLOCK>>>(d_Vmid, d_V, nCompt_);
	cudaMemcpy(&(V_[0]), d_V, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);
	*/


	/*
	// ---------------------------- BASIS AS TRI-DIAG SOLUTION ----------------------------------------
	GpuTimer cgTimer;
	if(step_num == 1){
		// Find the initial solution using tri-diagonal
		cudaMemcpy(d_Vmid, d_b, nCompt_*sizeof(double), cudaMemcpyDeviceToDevice);
		cusparseDgtsv_nopivot(cusparse_handle, nCompt_, 1, &(d_tridiag_data[0]), &(d_tridiag_data[nCompt_]), &(d_tridiag_data[2*nCompt_]),d_Vmid,nCompt_);
		cudaDeviceSynchronize();
	}
	// ----------------------------- CONJUGATE GRADIENT SOLVER  ----------------------------------------
	const double tol = 1e-16f;
	const int max_iter = 10000;
	double a, b, na, r0, r1;
	double alpha, beta, alpham1;
	double dot;
	int k;

	alpha = 1.0;
	alpham1 = -1.0;
	beta = 0.0;
	r0 = 0.0;
	cgTimer.Start();

//	cudaMemset(d_Vmid, 0, nCompt_*sizeof(double));
	cublasStatus_t cublasStatus;

	cusparseDcsrmv(cusparse_handle,CUSPARSE_OPERATION_NON_TRANSPOSE, nCompt_, nCompt_, mat_nnz, &alpha, cusparse_descr,
			d_mat_values, d_mat_rowPtr, d_mat_colIndex, d_Vmid,
			&beta, d_Ax);

	cublasDaxpy(cublas_handle, nCompt_, &alpham1, d_Ax, 1, d_b, 1);
	cublasStatus = cublasDdot(cublas_handle, nCompt_, d_b, 1, d_b, 1, &r1);

	k = 1;
	while (r1 > tol*tol && k <= max_iter)
	{
		if (k > 1)
		{
			b = r1 / r0;
			cublasStatus = cublasDscal(cublas_handle, nCompt_, &b, d_p, 1);
			cublasStatus = cublasDaxpy(cublas_handle, nCompt_, &alpha, d_b, 1, d_p, 1);
		}
		else
		{
			cublasStatus = cublasDcopy(cublas_handle, nCompt_, d_b, 1, d_p, 1);
		}

		cusparseDcsrmv(cusparse_handle, CUSPARSE_OPERATION_NON_TRANSPOSE, nCompt_, nCompt_, mat_nnz, &alpha, cusparse_descr,
				d_mat_values, d_mat_rowPtr, d_mat_colIndex,
				d_p, &beta, d_Ax);
		cublasStatus = cublasDdot(cublas_handle, nCompt_, d_p, 1, d_Ax, 1, &dot);
		a = r1 / dot;

		cublasStatus = cublasDaxpy(cublas_handle, nCompt_, &a, d_p, 1, d_Vmid, 1);
		na = -a;
		cublasStatus = cublasDaxpy(cublas_handle, nCompt_, &na, d_Ax, 1, d_b, 1);

		r0 = r1;
		cublasStatus = cublasDdot(cublas_handle, nCompt_, d_b, 1, d_b, 1, &r1);
		cudaThreadSynchronize();
		//printf("iteration = %3d, residual = %e\n", k, sqrt(r1));
		k++;
	}
	cgTimer.Stop();

	if(num_um_prints > -50){
		printf("%lf \n", cgTimer.Elapsed());
		num_um_prints--;
	}

	cudaMemcpy(&(VMid_[0]) , d_Vmid, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);
	calculate_V_from_Vmid<<<BLOCKS,THREADS_PER_BLOCK>>>(d_Vmid, d_V, nCompt_);
	cudaMemcpy(&(V_[0]), d_V, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);

	//getchar();
	/*
	// Check Vm from CG and gem
	double h_vmid[nCompt_];
	//double h_v[nCompt_];

	cudaMemcpy(h_vmid, d_Vmid, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);
	//cudaMemcpy(h_v, d_V, nCompt_*sizeof(double), cudaMemcpyDeviceToHost);
	double error = 0;
	for(int i=0;i<nCompt_;i++){
		printf("%d %lf %lf %lf\n", i,  h_vmid[i], VMid_[i], h_vmid[i]-VMid_[i]);
		error += (h_vmid[i] - VMid_[i]);
	}

	printf("error %lf \n",error);
	getchar();
	*/

}

void HSolveActive::advance_calcium_cuda_wrapper(){

	int num_ca_pools = caConc_.size();
	int num_catarget_channels = h_catarget_channel_indices.size();
	double alpha = 1;
	double beta = 0;

	int BLOCKS = num_catarget_channels/THREADS_PER_BLOCK;
	BLOCKS = (num_catarget_channels%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	advance_calcium_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(d_catarget_channel_indices,
			d_chan_Gk, d_chan_GkEk,
			d_Vmid,
			d_capool_values, d_chan_to_comp,
			num_catarget_channels);

	cusparseDcsrmv(cusparse_handle,
			CUSPARSE_OPERATION_NON_TRANSPOSE,
			num_ca_pools, num_catarget_channels, num_catarget_channels ,
			&alpha, cusparse_descr,
			d_capool_values, d_capool_rowPtr, d_capool_colIndex, d_capool_onex,
			&beta, d_caActivation_values);

	BLOCKS = num_ca_pools/THREADS_PER_BLOCK;
	BLOCKS = (num_ca_pools%THREADS_PER_BLOCK == 0)?BLOCKS:BLOCKS+1; // Adding 1 to handle last threads

	advance_calcium_conc_cuda<<<BLOCKS,THREADS_PER_BLOCK>>>(d_caConc_, d_ca, d_caActivation_values, num_ca_pools);

	cudaCheckError(); // Checking for cuda related errors.
}

#endif

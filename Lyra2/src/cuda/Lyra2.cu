/**
 * Implementation of the Lyra2 Password Hashing Scheme (PHS). 
 * Experimental CUDA implementation.
 * Note: Implemented without shared memory optimizations.
 * Author: The Lyra PHC team (http://www.lyra-kdf.net/) -- 2014.
 * This software is hereby placed in the public domain.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS ''AS IS'' AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "Lyra2.h"
#include "Sponge.h"

/**
  * Executes Lyra2 based on the G function from Blake2b. The number of columns of the memory matrix is set to nCols = 64.
 * This version supports salts and passwords whose combined length is smaller than the size of the memory matrix,
 * (i.e., (nRows x nCols x b) bits, where "b" is the underlying sponge's bitrate). In this implementation, the "basil" 
 * is composed by all integer parameters (treated as type "unsigned int") in the order they are provided, plus the value 
 * of nCols, (i.e., basil = kLen || pwdlen || saltlen || timeCost || nRows || nCols).
 * 
 * @param out     The derived key to be output by the algorithm
 * @param outlen  Desired key length
 * @param in      User password
 * @param inlen   Password length
 * @param salt    Salt
 * @param saltlen Salt length
 * @param t_cost  Parameter to determine the processing time (T)
 * @param m_cost  Memory cost parameter (defines the number of rows of the memory matrix, R)
 * 
 * @return          0 if the key is generated correctly; -1 if there is an error (usually due to lack of memory for allocation)
 */
int PHS(void *out, size_t outlen, const void *in, size_t inlen, const void *salt, size_t saltlen, unsigned int t_cost, unsigned int m_cost){
	const unsigned char *inPWD = (const unsigned char *)in;
	const unsigned char *saltG = (const unsigned char *)salt;
	unsigned char *outK = (unsigned char *)out;

	return LYRA2(outK, outlen, inPWD, inlen, saltG, saltlen, t_cost, m_cost, N_COLS);
}


void print64(uint64_t *v){
    int i;
    for (i = 0; i < 16; i++)    {
        printf("%ld|",v[i]);
    }
    printf("\n");
}

/**
 * Executes Lyra2 based on the G function from Blake2b. This version supports salts and passwords
 * whose combined length is smaller than the size of the memory matrix, (i.e., (nRows x nCols x b) bits, 
 * where "b" is the underlying sponge's bitrate). In this implementation, the "basil" is composed by all 
 * integer parameters (treated as type "unsigned int") in the order they are provided, plus the value 
 * of nCols, (i.e., basil = kLen || pwdlen || saltlen || timeCost || nRows || nCols). 
 * 
 * @param K         The derived key to be output by the algorithm
 * @param kLen      Desired key length
 * @param pwd       User password
 * @param pwdlen    Password length
 * @param salt      Salt
 * @param saltlen   Salt length
 * @param timeCost  Parameter to determine the processing time (T)
 * @param nRows     Number or rows of the memory matrix (R)
 * @param nCols     Number of columns of the memory matrix (C)
 * 
 * @return          0 if the key is generated correctly; -1 if there is an error (usually due to lack of memory for allocation)
 */
int LYRA2(unsigned char *K, int kLen, const unsigned char *pwd, int pwdlen, const unsigned char *salt, int saltlen, int timeCost, int nRows, int nCols) {

    int rowaCPU, i;

    //Checks whether or not the salt+password are within the accepted limits
    if (pwdlen + saltlen > ROW_LEN_BYTES) {
        return -1;
    }

    //========== Initializing the Memory Matrix and pointers to it =============//
    
    //Tries to allocate enough space for the whole memory matrix
    uint64_t *MemMatrixDev;
    cudaMalloc((void***) &MemMatrixDev, nRows * ROW_LEN_BYTES);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory allocation error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        return -1;
    }

    // Memory matrix cleanup:
    cudaMemset(MemMatrixDev, 0, nRows * ROW_LEN_BYTES);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory setting error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        return -1;
    }

    // CPU state alloc:
    //Sponge state (initialized to zeros): 16 uint64_t, 8 of them for the bitrate (b) and the remainder 8 for the capacity (c)
    uint64_t *stateHost = (uint64_t *) malloc(16 * sizeof (uint64_t));
    if (stateHost == NULL) {
        printf("Malloc error in file %s, line %d!\n", __FILE__, __LINE__);
        cudaFree(MemMatrixDev);
        free(stateHost);
        MemMatrixDev = NULL;
        return -1;
    }
    memset(stateHost, 0, 16 * sizeof (uint64_t));

    // GPU state alloc:
	//Sponge state: 16 uint64_t, BLOCK_LEN_INT64 words of them for the bitrate (b) and the remainder for the capacity (c)
    uint64_t *stateDev;
    cudaMalloc((void**) &stateDev, 16 * sizeof (uint64_t));
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory allocation error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        free(stateHost);
        cudaFree(stateDev);
        stateDev = NULL;
        return -1;
    }
    
    // GPU state cleanup
    cudaMemset(stateDev, 0, 16 * sizeof (uint64_t));
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory setting error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        return -1;
    }

    // GPU rowa alloc:
    int *rowADev;
    cudaMalloc((void**) &rowADev, sizeof (int));
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory allocation error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }

    cudaMemset(rowADev, 0, sizeof (int));
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory setting error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }
    //==========================================================================/
	
    //============= Getting the password + salt + basil padded with 10*1 ===============//

    //OBS.:The memory matrix will temporarily hold the password: not for saving memory,
    //but this ensures that the password copied locally will be overwritten as soon as possible
    uint64_t * MemMatrixHost = (uint64_t*) malloc(ROW_LEN_BYTES);
    if (MemMatrixHost == NULL) {
        printf("Malloc error in file %s, line %d!\n", __FILE__, __LINE__);
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        free(MemMatrixHost);
        return -1;
    }
    memset(MemMatrixHost, 0, ROW_LEN_BYTES);
    
	//Computes the number of blocks taken by the salt, password and basil
    int nBlocksInput = ((saltlen + pwdlen + 6*sizeof(int)) / BLOCK_LEN_BYTES) + 1;
	
    //Prepends the password    
    byte *ptrMem = (byte*) MemMatrixHost;
	memcpy(ptrMem, pwd, pwdlen);
    
    //Concatenates the salt
    ptrMem += pwdlen;
    memcpy(ptrMem, salt, saltlen);
    ptrMem += saltlen;
	
    //Concatenates the basil: every integer passed as parameter, in the order they are provided by the interface
    memcpy(ptrMem, &kLen, sizeof(int));
    ptrMem += sizeof(int);
    memcpy(ptrMem, &pwdlen, sizeof(int));
    ptrMem += sizeof(int);
    memcpy(ptrMem, &saltlen, sizeof(int));
    ptrMem += sizeof(int);
    memcpy(ptrMem, &timeCost, sizeof(int));
    ptrMem += sizeof(int);
    memcpy(ptrMem, &nRows, sizeof(int));
    ptrMem += sizeof(int);
    memcpy(ptrMem, &nCols, sizeof(int));
    ptrMem += sizeof(int);	
	
    //Now comes the padding
    *ptrMem = 0x80; //first byte of padding: right after the password
    ptrMem = (byte*) (MemMatrixHost);
    ptrMem += nBlocksInput * BLOCK_LEN_BYTES - 1; //sets the pointer to the correct position: end of incomplete block
    *ptrMem ^= 0x01; //last byte of padding: at the end of the last incomplete block

    //Copy the result to GPU memory
    cudaMemcpy(MemMatrixDev, MemMatrixHost, ROW_LEN_BYTES, cudaMemcpyHostToDevice);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory copy error in file %s, line %d!\n", __FILE__, __LINE__);
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }
    //Clean local password 
    memset(MemMatrixHost, 0, ROW_LEN_BYTES);
    //========================================================//

    //============== Initialing the Sponge State =============//
    initState(stateDev);
    //========================================================//	
	
    //====================== Setup Phase =====================//
 

	//Absorbing salt, password and basil
    uint64_t *ptrWord = MemMatrixDev;
    for (i = 0; i < nBlocksInput; i++) {
        absorbBlock << <1, 1 >> >(stateDev, ptrWord); //absorbs each block of pad(pwd || salt || basil)
        if (cudaSuccess != cudaGetLastError()) {
            printf("CUDA kernel call error in file %s, line %d!\n", __FILE__, __LINE__);
            printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
            free(stateHost);
            cudaFree(stateDev);
            cudaFree(MemMatrixDev);
            MemMatrixDev = NULL;
            stateDev = NULL;
            cudaFree(rowADev);
            rowADev = NULL;
            return -1;
        }
        ptrWord = &MemMatrixDev[((i + 1) * BLOCK_LEN_INT64)]; //goes to next block of pad(pwd || salt || basil)
    }
    //========================================================//

    //Initializes M[0] and M[1]
    reducedSqueezeRow << <1, 1 >> >(stateDev, MemMatrixDev); //The GPU copied password is overwritten here
    ptrWord = &MemMatrixDev[(ROW_LEN_INT64)];
    reducedSqueezeRow << <1, 1 >> >(stateDev, ptrWord);

    setupGPU << <1, 1 >> >(stateDev, MemMatrixDev, nRows);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA kernel call error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }

    //================== Wandering Phase =====================//
    wandering << <1, 1 >> > (stateDev, MemMatrixDev, timeCost, nRows, rowADev);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA kernel call error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }

    //Recover rowa from GPU
    cudaMemcpy(&rowaCPU, rowADev, sizeof (int), cudaMemcpyDeviceToHost);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory copy error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }
    //========================================================//

    //==================== Wrap-up Phase =====================//
    //Absorbs the last block of the memory matrix
    absorbBlock << <1, 1 >> >(stateDev, &MemMatrixDev[(rowaCPU * ROW_LEN_INT64)]);
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA kernel call error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
        cudaFree(stateDev);
        cudaFree(MemMatrixDev);
        MemMatrixDev = NULL;
        stateDev = NULL;
        cudaFree(rowADev);
        rowADev = NULL;
        return -1;
    }


    //Squeezes the key
    squeeze(stateDev, K, kLen);
    //========================================================//

    //=============== Freeing the memory =====================//
    cudaFree(MemMatrixDev);
	//Wiping out the sponge's internal state before freeing it
	cudaMemset(stateDev, 0, 16 * sizeof (uint64_t));
    if (cudaSuccess != cudaGetLastError()) {
        printf("CUDA memory setting error in file %s, line %d!\n", __FILE__, __LINE__);
        printf("Error: %s \n", cudaGetErrorString(cudaGetLastError()));
        free(stateHost);
		free(MemMatrixHost);
        cudaFree(stateDev);
		cudaFree(rowADev);
        return -1;
    }
    cudaFree(stateDev);
    cudaFree(rowADev);
    free(stateHost);
    free(MemMatrixHost);
    MemMatrixDev = NULL;
    stateDev = NULL;
    rowADev = NULL;
    stateHost = NULL;
    MemMatrixHost = NULL;
    //========================================================//

    return 0;
}





#include "OceanPatch.h"

#include <iostream>
#include <fstream>
#include <string.h>

#include "Topology/HeightField.h"

namespace dyno {

//Round a / b to nearest higher integer value
int cuda_iDivUp(int a, int b)
{
    return (a + (b - 1)) / b;
}

// complex math functions
__device__
    Vec2f
    conjugate(Vec2f arg)
{
    return Vec2f(arg.x, -arg.y);
}

__device__
    Vec2f
    complex_exp(float arg)
{
    return Vec2f(cosf(arg), sinf(arg));
}

__device__
    Vec2f
    complex_add(Vec2f a, Vec2f b)
{
    return Vec2f(a.x + b.x, a.y + b.y);
}

__device__
    Vec2f
    complex_mult(Vec2f ab, Vec2f cd)
{
    return Vec2f(ab.x * cd.x - ab.y * cd.y, ab.x * cd.y + ab.y * cd.x);
}

// generate wave heightfield at time t based on initial heightfield and dispersion relationship
__global__ void generateSpectrumKernel(Vec2f* h0,
                                       Vec2f*      ht,
                                       unsigned int in_width,
                                       unsigned int out_width,
                                       unsigned int out_height,
                                       float        t,
                                       float        patchSize)
{
    unsigned int x         = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y         = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int in_index  = y * in_width + x;
    unsigned int in_mindex = (out_height - y) * in_width + (out_width - x);  // mirrored
    unsigned int out_index = y * out_width + x;

    // calculate wave vector
    Vec2f k;
    k.x = (-( int )out_width / 2.0f + x) * (2.0f * CUDART_PI_F / patchSize);
    k.y = (-( int )out_width / 2.0f + y) * (2.0f * CUDART_PI_F / patchSize);

    // calculate dispersion w(k)
    float k_len = sqrtf(k.x * k.x + k.y * k.y);
    float w     = sqrtf(9.81f * k_len);

    if ((x < out_width) && (y < out_height))
    {
        Vec2f h0_k  = h0[in_index];
        Vec2f h0_mk = h0[in_mindex];

        // output frequency-space complex values
        ht[out_index] = complex_add(complex_mult(h0_k, complex_exp(w * t)), complex_mult(conjugate(h0_mk), complex_exp(-w * t)));
        //ht[out_index] = h0_k;
    }
}

// update height map values based on output of FFT
__global__ void updateHeightmapKernel(float*       heightMap,
                                      Vec2f*      ht,
                                      unsigned int width)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int i = y * width + x;

    // cos(pi * (m1 + m2))
    float sign_correction = ((x + y) & 0x01) ? -1.0f : 1.0f;

    heightMap[i] = ht[i].x * sign_correction;
}

// update height map values based on output of FFT
__global__ void updateHeightmapKernel_y(float*       heightMap,
                                        Vec2f*      ht,
                                        unsigned int width)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int i = y * width + x;

    // cos(pi * (m1 + m2))
    float sign_correction = ((x + y) & 0x01) ? -1.0f : 1.0f;

    heightMap[i] = ht[i].y * sign_correction;
}

// generate slope by partial differences in spatial domain
__global__ void calculateSlopeKernel(float* h, Vec2f* slopeOut, unsigned int width, unsigned int height)
{
    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int i = y * width + x;

    Vec2f slope = Vec2f(0.0f, 0.0f);

    if ((x > 0) && (y > 0) && (x < width - 1) && (y < height - 1))
    {
        slope.x = h[i + 1] - h[i - 1];
        slope.y = h[i + width] - h[i - width];
    }

    slopeOut[i] = slope;
}

__global__ void generateDispalcementKernel(
    Vec2f*      ht,
    Vec2f*      Dxt,
    Vec2f*      Dzt,
    unsigned int width,
    unsigned int height,
    float        patchSize)
{
    unsigned int x  = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int y  = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int id = y * width + x;

    // calculate wave vector
    float kx        = (-( int )width / 2.0f + x) * (2.0f * CUDART_PI_F / patchSize);
    float ky        = (-( int )height / 2.0f + y) * (2.0f * CUDART_PI_F / patchSize);
    float k_squared = kx * kx + ky * ky;
    if (k_squared == 0.0f)
    {
        k_squared = 1.0f;
    }
    kx = kx / sqrtf(k_squared);
    ky = ky / sqrtf(k_squared);

    Vec2f ht_ij = ht[id];
    Vec2f idoth = Vec2f(-ht_ij.y, ht_ij.x);

    Dxt[id] = kx * idoth;
    Dzt[id] = ky * idoth;
}

template<typename TDataType>
OceanPatch<TDataType>::OceanPatch(int size, float patchSize, int windType, std::string name)
    : Node(name)
{
	auto heights = std::make_shared<HeightField<TDataType>>();
	this->currentTopology()->setDataPtr(heights);

    std::ifstream input("../../data/windparam.txt", std::ios::in);
    for (int i = 0; i <= 12; i++)
    {
        WindParam param;
        int       dummy;
        input >> dummy;
        input >> param.windSpeed;
        input >> param.A;
        input >> param.choppiness;
        input >> param.global;
        m_params.push_back(param);
    }

    mResolution = size;

    mSpectrumWidth = size + 1;
    mSpectrumHeight = size + 4;

    m_windType      = windType;
    m_realPatchSize = patchSize;
    m_windSpeed     = m_params[m_windType].windSpeed;
    A               = m_params[m_windType].A;
    m_maxChoppiness = m_params[m_windType].choppiness;
    mChoppiness    = m_params[m_windType].choppiness;
    m_globalShift   = m_params[m_windType].global;

    m_ht = NULL;

}

template<typename TDataType>
OceanPatch<TDataType>::OceanPatch(int size, float wind_dir, float windSpeed, float A_p, float max_choppiness, float global)
{
	auto heights = std::make_shared<HeightField<TDataType>>();
	this->currentTopology()->setDataPtr(heights);

    mResolution          = size;
    mSpectrumWidth     = size + 1;
    mSpectrumHeight     = size + 4;
    m_realPatchSize = mResolution;
    windDir         = wind_dir;
    m_windSpeed     = windSpeed;
    A               = A_p;
    m_maxChoppiness = max_choppiness;
    mChoppiness    = 1.0f;
    m_globalShift   = global;

    m_ht            = NULL;
    //initialize();
}

template<typename TDataType>
OceanPatch<TDataType>::~OceanPatch()
{

    cudaFree(m_h0);
    cudaFree(m_ht);
    cudaFree(m_Dxt);
    cudaFree(m_Dzt);
    cudaFree(m_displacement);
    cudaFree(m_gradient);

}

template<typename TDataType>
void OceanPatch<TDataType>::resetStates()
{
    cufftPlan2d(&fftPlan, mResolution, mResolution, CUFFT_C2C);

    int spectrumSize = mSpectrumWidth * mSpectrumHeight * sizeof(Vec2f);
    cuSafeCall(cudaMalloc(( void** )&m_h0, spectrumSize));
    //m_h0.resize(mSpectrumWidth, mSpectrumHeight);
    //synchronCheck;
    Vec2f* host_h0 = ( Vec2f* )malloc(spectrumSize);
    generateH0(host_h0);

    cuSafeCall(cudaMemcpy(m_h0, host_h0, spectrumSize, cudaMemcpyHostToDevice));

    int outputSize = mResolution * mResolution * sizeof(Vec2f);
    cudaMalloc(( void** )&m_ht, outputSize);
    cudaMalloc(( void** )&m_Dxt, outputSize);
    cudaMalloc(( void** )&m_Dzt, outputSize);
    cudaMalloc(( void** )&m_displacement, mResolution * mResolution * sizeof(Vec4f));
    cuSafeCall(cudaMalloc(( void** )&m_gradient, mResolution * mResolution * sizeof(Vec4f)));

    //gl_utility::createTexture(m_size, m_size, GL_RGBA32F, m_displacement_texture, GL_REPEAT, GL_LINEAR, GL_LINEAR, GL_RGBA, GL_FLOAT);
    //cudaCheck(cudaGraphicsGLRegisterImage(&m_cuda_displacement_texture, m_displacement_texture, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsWriteDiscard));
    //gl_utility::createTexture(m_size, m_size, GL_RGBA32F, m_gradient_texture, GL_REPEAT, GL_LINEAR, GL_LINEAR, GL_RGBA, GL_FLOAT);
    //cudaCheck(cudaGraphicsGLRegisterImage(&m_cuda_gradient_texture, m_gradient_texture, GL_TEXTURE_2D, cudaGraphicsMapFlagsWriteDiscard));

	auto topo = TypeInfo::cast<HeightField<TDataType>>(this->currentTopology()->getDataPtr());
	Real h = m_realPatchSize / mResolution;
	topo->setExtents(mResolution, mResolution);
	topo->setGridSpacing(h);
	topo->setOrigin(Vec3f(-0.5*h*topo->width(), 0, -0.5*h*topo->height()));
}

float t = 0.0f;
template<typename TDataType>
void OceanPatch<TDataType>::updateStates()
{
	t += 0.016f;
	this->animate(t);
}

__global__ void O_UpdateDisplacement(
    Vec4f* displacement,
    Vec2f* Dh,
    Vec2f* Dx,
    Vec2f* Dz,
    int     patchSize)
{
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
    if (i < patchSize && j < patchSize)
    {
        int id = i + j * patchSize;

        float sign_correction = ((i + j) & 0x01) ? -1.0f : 1.0f;
        float h_ij            = sign_correction * Dh[id].x;
        float x_ij            = sign_correction * Dx[id].x;
        float z_ij            = sign_correction * Dz[id].x;

        displacement[id] = Vec4f(x_ij, h_ij, z_ij, 0);
    }
}

template<typename TDataType>
void OceanPatch<TDataType>::animate(float t)
{
    t = m_fft_flow_speed * t;
    dim3 block(8, 8, 1);
    dim3 grid(cuda_iDivUp(mResolution, block.x), cuda_iDivUp(mResolution, block.y), 1);
    generateSpectrumKernel<<<grid, block>>>(m_h0, m_ht, mSpectrumWidth, mResolution, mResolution, t, m_realPatchSize);
    cuSynchronize();
    generateDispalcementKernel<<<grid, block>>>(m_ht, m_Dxt, m_Dzt, mResolution, mResolution, m_realPatchSize);
    cuSynchronize();

    cufftExecC2C(fftPlan, (float2*)m_ht, (float2*)m_ht, CUFFT_INVERSE);
    cufftExecC2C(fftPlan, (float2*)m_Dxt, (float2*)m_Dxt, CUFFT_INVERSE);
    cufftExecC2C(fftPlan, (float2*)m_Dzt, (float2*)m_Dzt, CUFFT_INVERSE);

    int  x = (mResolution + 16 - 1) / 16;
    int  y = (mResolution + 16 - 1) / 16;
    dim3 threadsPerBlock(16, 16);
    dim3 blocksPerGrid(x, y);
    O_UpdateDisplacement<<<blocksPerGrid, threadsPerBlock>>>(m_displacement, m_ht, m_Dxt, m_Dzt, mResolution);
    cuSynchronize();
}

template <typename Coord>
__global__ void O_UpdateTopology(
	DArray2D<Coord> displacement,
	Vec4f* dis,
	float choppiness)
{
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y * blockDim.y + threadIdx.y;
	if (i < displacement.nx() && j < displacement.ny())
	{
		int id = displacement.index(i, j);

		Vec4f Dij = dis[id];

		Coord v;
		v.x = choppiness * Dij.x;
		v.y = Dij.y;
		v.z = choppiness*Dij.z;

		displacement(i, j) = v;
	}
}

template<typename TDataType>
void OceanPatch<TDataType>::updateTopology()
{
	auto topo = TypeInfo::cast<HeightField<TDataType>>(this->currentTopology()->getDataPtr());
	
	auto& shifts = topo->getDisplacement();
		
	uint2 extent;
	extent.x = shifts.nx();
	extent.y = shifts.ny();
	cuExecute2D(extent,
		O_UpdateTopology,
		shifts,
		m_displacement,
		mChoppiness);
}


template<typename TDataType>
float OceanPatch<TDataType>::getMaxChoppiness()
{
    return m_maxChoppiness;
}

template<typename TDataType>
float OceanPatch<TDataType>::getChoppiness()
{
    return mChoppiness;
}

template<typename TDataType>
void OceanPatch<TDataType>::generateH0(Vec2f* h0)
{
    for (unsigned int y = 0; y <= mResolution; y++)
    {
        for (unsigned int x = 0; x <= mResolution; x++)
        {
            float kx = (-( int )mResolution / 2.0f + x) * (2.0f * CUDART_PI_F / m_realPatchSize);
            float ky = (-( int )mResolution / 2.0f + y) * (2.0f * CUDART_PI_F / m_realPatchSize);

            float P = sqrtf(phillips(kx, ky, windDir, m_windSpeed, A, dirDepend));

            if (kx == 0.0f && ky == 0.0f)
            {
                P = 0.0f;
            }

            //float Er = urand()*2.0f-1.0f;
            //float Ei = urand()*2.0f-1.0f;
            float Er = gauss();
            float Ei = gauss();

            float h0_re = Er * P * CUDART_SQRT_HALF_F;
            float h0_im = Ei * P * CUDART_SQRT_HALF_F;

            int i   = y * mSpectrumWidth + x;
            h0[i].x = h0_re;
            h0[i].y = h0_im;
        }
    }
}

template<typename TDataType>
float OceanPatch<TDataType>::phillips(float Kx, float Ky, float Vdir, float V, float A, float dir_depend)
{
    float k_squared = Kx * Kx + Ky * Ky;

    if (k_squared == 0.0f)
    {
        return 0.0f;
    }

    // largest possible wave from constant wind of velocity v
    float L = V * V / g;

    float k_x     = Kx / sqrtf(k_squared);
    float k_y     = Ky / sqrtf(k_squared);
    float w_dot_k = k_x * cosf(Vdir) + k_y * sinf(Vdir);

    float phillips = A * expf(-1.0f / (k_squared * L * L)) / (k_squared * k_squared) * w_dot_k * w_dot_k;

    // filter out waves moving opposite to wind
    if (w_dot_k < 0.0f)
    {
        phillips *= dir_depend;
    }

    // damp out waves with very small length w << l
    //float w = L / 10000;
    //phillips *= expf(-k_squared * w * w);

    return phillips;
}

template<typename TDataType>
float OceanPatch<TDataType>::gauss()
{
    float u1 = rand() / ( float )RAND_MAX;
    float u2 = rand() / ( float )RAND_MAX;

    if (u1 < 1e-6f)
    {
        u1 = 1e-6f;
    }

    return sqrtf(-2 * logf(u1)) * cosf(2 * CUDART_PI_F * u2);
}

DEFINE_CLASS(OceanPatch);
}  // namespace PhysIKA
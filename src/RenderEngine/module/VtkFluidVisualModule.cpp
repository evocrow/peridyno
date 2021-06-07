#include "VtkFluidVisualModule.h"
// opengl
#include <glad/glad.h>
#include "RenderEngine.h"
// framework
#include "Topology/TriangleSet.h"
#include "Framework/Node.h"

#include <vtkActor.h>
#include <vtkProperty.h>
#include <vtkRenderer.h>
#include <vtkOpenGLVertexBufferObjectGroup.h>
#include <vtkPolyData.h>
#include <vtkOpenGLVertexBufferObject.h>
#include <vtkOpenGLIndexBufferObject.h>
#include <vtkVolume.h>

#include <vtkOpenGLFluidMapper.h>

#include <cuda_gl_interop.h>

#include "Framework/SceneGraph.h"

using namespace dyno;

class FluidMapper : public vtkOpenGLFluidMapper
{
public:
	FluidMapper(FluidVisualModule* v) : m_module(v)
	{
		// create psedo data, required by the vtkOpenGLPolyDataMapper to render content
		vtkNew<vtkPoints> points;

		Vec3f bbox0 = SceneGraph::getInstance().getLowerBound();
		Vec3f bbox1 = SceneGraph::getInstance().getUpperBound();
		points->InsertNextPoint(bbox0[0], bbox0[1], bbox0[2]);
		points->InsertNextPoint(bbox1[0], bbox1[1], bbox1[2]);

		vtkNew<vtkPolyData> polyData;
		polyData->SetPoints(points);
		SetInputData(polyData);
	}

	void Update() override
	{
		vtkOpenGLFluidMapper::Update();

		// hack for VBO update...
		vtkOpenGLVertexBufferObject* vertexBuffer = this->VBOs->GetVBO("vertexMC");

		if (vertexBuffer)
		{
			//printf("update\n");
			// update the VBO build time, so vtk will not write to VBO
			this->VBOBuildTime.Modified();
			
			if (!m_module->isInitialized())	
				return;

			auto node = m_module->getParent();
			auto pSet = std::dynamic_pointer_cast<dyno::PointSet<dyno::DataType3f>>(node->getTopologyModule());
			auto verts = pSet->getPoints();

			cudaError_t error;

			if (!m_initialized)
			{
				printf("Intialize\n");
				m_initialized = true;

				vtkNew<vtkPoints> points;
				points->SetNumberOfPoints(verts.size());
				vertexBuffer->UploadDataArray(points->GetData());

				// create memory mapper for CUDA
				error = cudaGraphicsGLRegisterBuffer(&m_cudaVBO, vertexBuffer->GetHandle(), cudaGraphicsRegisterFlagsWriteDiscard);
				//printf("%s\n", cudaGetErrorName(error));
			}

			// copy vertex memory
			{
				size_t size;
				void*  cudaPtr = 0;

				// upload vertex
				error = cudaGraphicsMapResources(1, &m_cudaVBO); 
				//printf("%s\n", cudaGetErrorName(error));
				error = cudaGraphicsResourceGetMappedPointer(&cudaPtr, &size, m_cudaVBO);
				//printf("%s\n", cudaGetErrorName(error));
				error = cudaMemcpy(cudaPtr, verts.begin(), verts.size() * sizeof(float) * 3, cudaMemcpyDeviceToDevice);
				//printf("%s\n", cudaGetErrorName(error));
				error = cudaGraphicsUnmapResources(1, &m_cudaVBO);
				//printf("%s\n", cudaGetErrorName(error));
			}
		
			/// seems not necessary
			vtkIdType numPts = verts.size();
			this->GLHelperDepthThickness.IBO->IndexCount = static_cast<size_t>(numPts);
		}
		else
		{
			// wait for the vtkOpenGLFluidMapper to initialize VBO...
		}

	}



private:
	dyno::FluidVisualModule*	m_module;
	cudaGraphicsResource*		m_cudaVBO;
	bool						m_initialized = false;

};

IMPLEMENT_CLASS_COMMON(FluidVisualModule, 0)

FluidVisualModule::FluidVisualModule()
{
	this->setName("fluid_renderer");
	m_volume = vtkVolume::New();

	FluidMapper* fluidMapper = new FluidMapper(this);

	fluidMapper->SetParticleRadius(0.01f);
	fluidMapper->SetSurfaceFilterIterations(3);
	fluidMapper->SetSurfaceFilterRadius(3);

	fluidMapper->SetSurfaceFilterMethod(vtkOpenGLFluidMapper::FluidSurfaceFilterMethod::NarrowRange);
	fluidMapper->SetDisplayMode(vtkOpenGLFluidMapper::FluidDisplayMode::TransparentFluidVolume);
	fluidMapper->SetAttenuationColor(0.8f, 0.2f, 0.15f);
	fluidMapper->SetAttenuationScale(1.0f);
	fluidMapper->SetOpaqueColor(0.0f, 0.0f, 0.9f);
	fluidMapper->SetParticleColorPower(0.1f);
	fluidMapper->SetParticleColorScale(0.57f);
	fluidMapper->SetAdditionalReflection(0.0f);
	fluidMapper->SetRefractiveIndex(1.33f);
	fluidMapper->SetRefractionScale(0.07f);

	m_volume->SetMapper(fluidMapper);
}


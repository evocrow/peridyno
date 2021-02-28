#pragma once
#include "PointSet.h"


namespace dyno
{
	template<typename DataType3f>
	class UnstructuredPointSet : public PointSet<DataType3f>
	{
	public:
		UnstructuredPointSet();
		~UnstructuredPointSet();

	private:

		/**
		* @brief Neighboring particles
		*
		*/
		DEF_EMPTY_IN_NEIGHBOR_LIST(Neighborhood, int, "Neighboring particles' ids");
	};


#ifdef PRECISION_FLOAT
	template class UnstructuredPointSet<DataType3f>;
#else
	template class UnstructuredPointSet<DataType3d>;
#endif
}

#pragma once
#include "Module/TopologyMapping.h"

#include "Topology/DiscreteElements.h"
#include "Topology/TriangleSet.h"

namespace dyno
{
	template<typename TDataType>
	class DiscreteElementsToTriangleSet : public TopologyMapping
	{
	public:
		typedef typename TDataType::Real Real;
		typedef typename TDataType::Coord Coord;

		DiscreteElementsToTriangleSet();

	protected:
		bool apply() override;

	public:
		DEF_INSTANCE_IN(DiscreteElements<TDataType>, DiscreteElements, "");
		DEF_INSTANCE_OUT(TriangleSet<TDataType>, TriangleSet, "");
	};
}
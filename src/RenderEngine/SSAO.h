/**
 * Copyright 2017-2021 Jian SHI
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#pragma once

#include "GLFramebuffer.h"
#include "GLTexture.h"
#include "GLBuffer.h"
#include "GLShader.h"

namespace dyno 
{
	class SSAO
	{
	public:
		SSAO();
		~SSAO();

		void initialize();
		void resize(unsigned int w, unsigned int h);

	private:

		// SSAO
		GLBuffer		mSSAOKernelUBO;
		GLTexture2D		mSSAONoiseTex;
		GLShaderProgram mSSAOProgram;

		GLFramebuffer	mDepthFramebuffer;
		GLTexture2D		mDepthTex;

		GLFramebuffer	mSSAOFramebuffer;
		GLTexture2D		mSSAOTex;

		GLFramebuffer	mSSAOFilterFramebuffer;
		GLTexture2D		mSSAOFilterTex;

		unsigned int	mWidth;
		unsigned int	mHeight;
	};
}

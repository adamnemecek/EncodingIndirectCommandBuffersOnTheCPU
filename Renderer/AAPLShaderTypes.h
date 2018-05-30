/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Header containing types and enum constants shared between Metal shaders and C/ObjC source
*/
#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#define AAPLNumShapes 16

// Structure defining the layout of each vertex.  Shared between C code filling in the vertex data
//   and Metal vertex shader consuming the vertices
typedef struct
{
    vector_float3 position;
    packed_float2 texcoord;
} AAPLVertex;

// Buffer index values shared between shader and C code to ensure Metal shader buffer inputs match
//   Metal API buffer set calls
typedef enum AAPLBufferIndex
{
    AAPLBufferIndexVertices = 0,
    AAPLBufferIndexUniforms = 1,
} AAPLBufferIndex;

// Texture index values shared between shader and C code to ensure Metal shader texture indices
//   match indices of Metal API texture set calls
typedef enum AAPLTextureIndex
{
    AAPLTextureIndexBaseColor = 0,
} AAPLTextureIndex;

// Structure shared between shader and C code to ensure the layout of uniform data accessed in
// Metal shaders matches the layout of uniform data set in C code
typedef struct
{
    // Per Frame Uniforms
    vector_float3 cameraPos;

    // Per Mesh Uniforms
    matrix_float4x4 modelMatrix;
    matrix_float4x4 modelViewProjectionMatrix;
    matrix_float3x3 normalMatrix;

} AAPLUniforms;

typedef enum AAPLArgumentBufferBufferID
{
    AAPLArgumentBufferIDICB,
    AAPLArgumentBufferIDUniformBuffer,
    AAPLArgumentBufferIDDepth,
    AAPLArgumentBufferIDVertexBuffer,
    AAPLArgumentBufferIDVertexNumBuffer = 50
} AAPLArgumentBufferBufferID;

typedef enum AAPLVertexBufferIndex
{
    AAPLVertexBufferIndexArgument
}AAPLVertexBufferIndex;

#endif /* ShaderTypes_h */

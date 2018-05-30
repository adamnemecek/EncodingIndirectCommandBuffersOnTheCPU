/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Metal shaders used for this sample
*/

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands
#import "AAPLShaderTypes.h"

// Vertex shader outputs and per-fragment inputs.  Includes clip-space position and vertex outputs
//  interpolated by rasterizer and fed to each fragment generated by clip-space primitives.
typedef struct
{
    float4 position [[position]];
    float2 texcoord;
} ColorInOut;

vertex ColorInOut vertexShader(uint vertexID [[ vertex_id ]],
                               device  AAPLVertex *in [[ buffer(AAPLBufferIndexVertices) ]],
                               constant AAPLUniforms & uniforms [[ buffer(AAPLBufferIndexUniforms) ]])
{
    ColorInOut out;

    float4 position = float4(in[vertexID].position.x, in[vertexID].position.y, in[vertexID].position.z, 1);

    // Calculate the position of our vertex in clip space and output for clipping and rasterization
    float depth = in[vertexID].position.z;
    out.position = uniforms.modelViewProjectionMatrix * position;
    // For simplicity purpose in this sample, force Z and W value.
    out.position.z = depth / AAPLNumShapes;
    out.position.x = out.position.x/out.position.w;
    out.position.y = out.position.y/out.position.w;
    out.position.w = 1;
    out.texcoord = in[vertexID].texcoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]])
{
    return float4(in.texcoord.x, in.texcoord.y, 0, 1);
}

// Argument buffer for indirect command buffer.
typedef struct arguments {
    command_buffer cmd_buffer [[ id(AAPLArgumentBufferIDICB) ]];
    constant AAPLUniforms * uniforms [[ id(AAPLArgumentBufferIDUniformBuffer) ]];
    float depth [[ id(AAPLArgumentBufferIDDepth) ]];
    array<device float *, AAPLNumShapes> vertex_buffers [[ id(AAPLArgumentBufferIDVertexBuffer) ]];
    array<uint8_t, AAPLNumShapes> vertex_num [[ id(AAPLArgumentBufferIDVertexNumBuffer) ]];
} arguments;

// Kernel to encode indirect command buffer.
kernel void kernelShader(uint cmd_idx [[ thread_position_in_threadgroup ]],
                         device arguments &args [[ buffer(AAPLVertexBufferIndexArgument) ]])
{
    render_command cmd(args.cmd_buffer, cmd_idx);
    if (args.depth == (((device AAPLVertex *)args.vertex_buffers[cmd_idx])[0].position.z) / AAPLNumShapes)
    {
        cmd.set_vertex_buffer(args.vertex_buffers[cmd_idx], AAPLBufferIndexVertices);
        cmd.set_vertex_buffer(args.uniforms, AAPLBufferIndexUniforms);
        cmd.draw_primitives(primitive_type::triangle_strip, 0, args.vertex_num[cmd_idx], 1, 0);
    }
    else
    {
        cmd.reset();
    }
}

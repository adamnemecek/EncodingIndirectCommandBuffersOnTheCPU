/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implementation of renderer class which performs Metal setup and per frame rendering
*/
@import simd;
@import MetalKit;

#import "AAPLRenderer.h"
#import "AAPLMathUtilities.h"

// Include header shared between C code here, which executes Metal API commands, and .metal files
#import "AAPLShaderTypes.h"

// The max number of command buffers in flight
static const NSUInteger AAPLMaxBuffersInFlight = 3;

// Main class performing the rendering
@implementation AAPLRenderer
{
    dispatch_semaphore_t _inFlightSemaphore;
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;

    // Metal objects
    id <MTLBuffer> _uniformBuffers;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLComputePipelineState> _computePipeline;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _baseColorMap;
    id <MTLIndirectCommandBuffer> _icb;
    id <MTLBuffer> _vertexBuffer[AAPLNumShapes];
    id <MTLFunction> _kernelFunction;
    id <MTLBuffer> _kernelShaderArgumentBuffer;

    // Current buffer to fill with dynamic uniform data and set for the current frame
    uint _currentBufferIndex;
    uint _currentFrameIndex;
    uint _currentFrameID;

    // Projection matrix calculated as a function of view size
    matrix_float4x4 _projectionMatrix;

    MTLSize _threadgroupSize;
    MTLSize _threadgroupCount;

    // Current rotation of our object in radians
    float _rotation;
    float _currentWidth;
    float _currentHeight;
    float _currentDepth;
}

/// Initialize with the MetalKit view from which we'll obtain our Metal device.  We'll also use this
/// mtkView object to set the pixel format and other properties of our drawable
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if(self)
    {
        _device = mtkView.device;
        _inFlightSemaphore = dispatch_semaphore_create(AAPLMaxBuffersInFlight);
        [self loadMetal:mtkView];
        [self loadAssets];
    }

    return self;
}

/// Create our metal render state objects including our shaders and render state pipeline objects
- (void) loadMetal:(nonnull MTKView *)mtkView
{
    // Create and load our basic Metal state objects

    // Load all the shader files with a metal file extension in the project
    id <MTLLibrary> defaultLibrary = [_device newDefaultLibrary];

    // Load the vertex function into the library
    id <MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];

    // Load the fragment function into the library
    id <MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentShader"];

    _uniformBuffers = [_device newBufferWithLength:sizeof(AAPLUniforms)
                                           options:MTLResourceStorageModeShared];

    AAPLUniforms * uniforms = (AAPLUniforms*)_uniformBuffers.contents;
    const matrix_float4x4 modelMatrix = matrix4x4_scale(3, 3, 1);

    const vector_float3 cameraTranslation = {0.0, 0.0, -8.0};
    const matrix_float4x4 viewMatrix = matrix4x4_translation (-cameraTranslation);
    _projectionMatrix = matrix_perspective_left_hand(65.0f * (M_PI / 180.0f), mtkView.drawableSize.width / (float)mtkView.drawableSize.height, 0.1f, 100.0f);
    const matrix_float4x4 viewProjectionMatrix  = matrix_multiply (_projectionMatrix, viewMatrix);

    uniforms->cameraPos = cameraTranslation;
    uniforms->modelMatrix = modelMatrix;
    uniforms->modelViewProjectionMatrix = matrix_multiply (viewProjectionMatrix, modelMatrix);

    mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    mtkView.sampleCount = 1;

    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    pipelineStateDescriptor.sampleCount = mtkView.sampleCount;
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;
    pipelineStateDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat;
    // Needed for this pipeline state to be used in indirect command buffers.
    pipelineStateDescriptor.supportIndirectCommandBuffers = TRUE;

    NSError *error = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState)
    {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }

    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionEqual;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];

    // Create kernel function for GPU encoding. This is always done no matter if GPU encoding is
    // enabled just for simplicity.
    _kernelFunction = [defaultLibrary newFunctionWithName:@"kernelShader"];

    _computePipeline = [_device newComputePipelineStateWithFunction:_kernelFunction
                                                              error:&error];
    if (!_computePipeline)
    {
        NSLog(@"Failed to created compute pipeline state, error %@", error);
    }

    _threadgroupSize = MTLSizeMake(AAPLNumShapes, 1, 1);
    _threadgroupCount = MTLSizeMake(1, 1, 1);
    _threadgroupCount.width  = AAPLNumShapes;
    _threadgroupCount.height = 1;

    _currentDepth = 100.0f;

    for (int indx = 0; indx < AAPLNumShapes; indx++)
    {
        _vertexBuffer[indx] = [self createCircleMeshWithTriangleStrip:(indx+3)];
    }

    // Create the command queue
    _commandQueue = [_device newCommandQueue];
}

- (id<MTLBuffer>)createCircleMeshWithTriangleStrip:(uint32_t)numSides
{
    assert(numSides >= 3);

    uint32_t bufferSize = sizeof(AAPLVertex)*numSides;

    id<MTLBuffer> metalBuffer = [_device newBufferWithLength:bufferSize options:0];

    AAPLVertex *meshVertices = (AAPLVertex *)metalBuffer.contents;

    const float angle = 2*M_PI/(float)numSides;
    for(int vtx = 0;vtx < numSides; vtx++)
    {
        int point = (vtx%2) ? (vtx+1)/2 : -vtx/2;
        vector_float3 position = {sin(point*angle), cos(point*angle), (numSides - 3) * 1.0f};
        vector_float2 pos = {sin(point*angle), cos(point*angle)};
        meshVertices[vtx].position = position;
        meshVertices[vtx].texcoord = (pos + 1.0) / 2.0;
    }
    
    return metalBuffer;
}

/// Create and load our assets into Metal objects including meshes and textures
- (void) loadAssets
{
    // Build indirect command buffers
    MTLIndirectCommandBufferDescriptor* icbDescriptor = [[MTLIndirectCommandBufferDescriptor alloc] init];

    icbDescriptor.commandTypes = MTLIndirectCommandTypeDraw;
#if !TARGET_IOS
    icbDescriptor.inheritPipelineState = TRUE;
#endif
    icbDescriptor.inheritBuffers = FALSE;
    icbDescriptor.maxVertexBufferBindCount = 2;
    icbDescriptor.maxFragmentBufferBindCount = 0;

    _icb = [_device newIndirectCommandBufferWithDescriptor:icbDescriptor maxCommandCount:AAPLNumShapes options:0];

#if USE_CPU
    for (int indx = 0; indx < AAPLNumShapes; indx++)
    {
        NSUInteger vertexCount = _vertexBuffer[indx].length/sizeof(AAPLVertex);

        id<MTLIndirectRenderCommand> cmd = [_icb indirectRenderCommandAtIndex:indx];

        [cmd setVertexBuffer:_vertexBuffer[indx] offset:0 atIndex:AAPLBufferIndexVertices];
        [cmd setVertexBuffer:_uniformBuffers offset:0 atIndex:AAPLBufferIndexUniforms];

        [cmd drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:vertexCount
              instanceCount:1
               baseInstance:0];
    }
    
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Indirect Command Buffer Optimization";
    
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    blitEncoder.label = @"Indirect Command Buffer Optimization Encoding";
    
    [blitEncoder optimizeIndirectCommandBuffer:_icb withRange:NSMakeRange(0, AAPLNumShapes)];
    [blitEncoder endEncoding];
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
#endif
}

/// Called whenever view changes orientation or layout is changed
- (void) mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    /// React to resize of our draw rect.  In particular update our perspective matrix
    // Update the aspect ratio and projection matrix since the view orientation or size has changed
    float aspect = size.width / (float)size.height;
    _currentWidth = size.width;
    _currentHeight = size.height;
    _projectionMatrix = matrix_perspective_left_hand(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0);
}

// Called whenever the view needs to render
- (void) drawInMTKView:(nonnull MTKView *)view
{
    float targetDepth = (_currentFrameIndex * 1.0f) / AAPLNumShapes;
    if (targetDepth != _currentDepth)
    {
        _currentDepth = targetDepth;

#if !USE_CPU
        id <MTLArgumentEncoder> argumentEncoder = [_kernelFunction newArgumentEncoderWithBufferIndex:AAPLVertexBufferIndexArgument];
        NSUInteger argumentBufferLength = argumentEncoder.encodedLength;

        _kernelShaderArgumentBuffer = [_device newBufferWithLength:argumentBufferLength options:0];
        _kernelShaderArgumentBuffer.label = @"Argument Buffer for ICB";

        [argumentEncoder setArgumentBuffer:_kernelShaderArgumentBuffer offset:0];
        [argumentEncoder setIndirectCommandBuffer:_icb atIndex:AAPLArgumentBufferIDICB];
        [argumentEncoder setBuffer:_uniformBuffers offset:0 atIndex:AAPLArgumentBufferIDUniformBuffer];
        for (int indx = 0; indx < AAPLNumShapes; indx++)
        {
            [argumentEncoder setBuffer:_vertexBuffer[indx] offset:0 atIndex:AAPLArgumentBufferIDVertexBuffer + indx];
            uint8_t *vertexNumAddr = [argumentEncoder constantDataAtIndex:AAPLArgumentBufferIDVertexNumBuffer + indx];
            *vertexNumAddr = (uint8_t)(_vertexBuffer[indx].length / sizeof(AAPLVertex));
        }
        float *depthValAddr = [argumentEncoder constantDataAtIndex:AAPLArgumentBufferIDDepth];
        *depthValAddr = _currentDepth;

        id <MTLCommandBuffer> commandComputeBuffer = [_commandQueue commandBuffer];
        commandComputeBuffer.label = @"Indirect Command Buffer Encoding";
        id<MTLComputeCommandEncoder> computeEncoder = [commandComputeBuffer computeCommandEncoder];
        computeEncoder.label = @"Indirect Command Buffer GPU Encoding";

        [computeEncoder setComputePipelineState:_computePipeline];
        [computeEncoder useResource:_icb usage:MTLResourceUsageWrite];
        for (int indx = 0; indx < AAPLNumShapes; indx++)
        {
            [computeEncoder useResource:_vertexBuffer[indx] usage:MTLResourceUsageRead];
        }
        [computeEncoder useResource:_uniformBuffers usage:MTLResourceUsageRead];
        [computeEncoder setBuffer:_kernelShaderArgumentBuffer
                           offset:0
                          atIndex:0];
        [computeEncoder dispatchThreadgroups:_threadgroupCount
                       threadsPerThreadgroup:_threadgroupSize];

        [computeEncoder endEncoding];
        
        id<MTLBlitCommandEncoder> blitEncoder = [commandComputeBuffer blitCommandEncoder];
        blitEncoder.label = @"Indirect Command Buffer Optimization";
        
        [blitEncoder optimizeIndirectCommandBuffer:_icb withRange:NSMakeRange(0, AAPLNumShapes)];
        [blitEncoder endEncoding];
        
        [commandComputeBuffer commit];
        [commandComputeBuffer waitUntilCompleted];
#endif

    }
    // Wait to ensure only AAPLMaxBuffersInFlight are getting processed by any stage in the Metal
    //   pipeline (App, Metal, Drivers, GPU, etc)
    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);

    // Create a new command buffer for each render pass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";

    // Add completion hander which signals _inFlightSemaphore when Metal and the GPU has fully
    //   finished processing the commands we're encoding this frame.  This indicates when the
    //   dynamic buffers, that we're writing to this frame, will no longer be needed by Metal
    //   and the GPU, meaning we can change the buffer contents without corrupting the rendering.
    __block dispatch_semaphore_t block_sema = _inFlightSemaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer)
     {
         dispatch_semaphore_signal(block_sema);
     }];

    // Obtain a renderPassDescriptor generated from the view's drawable textures
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;

    // If we've gotten a renderPassDescriptor we can render to the drawable, otherwise we'll skip
    //   any rendering this frame because we have no drawable to draw to
    if(renderPassDescriptor != nil) {
        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.clearDepth = _currentDepth;

        // Create a render command encoder so we can render into something
        id <MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = @"MyRenderEncoder";

        [renderEncoder setCullMode:MTLCullModeNone];

        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        [renderEncoder pushDebugGroup:@"DrawShapes"];

        // Set render command encoder state
        [renderEncoder setCullMode:MTLCullModeBack];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setDepthStencilState:_depthState];
        [renderEncoder useResource:_uniformBuffers usage:MTLResourceUsageRead];
        for (int indx = 0; indx < AAPLNumShapes; indx++)
        {
            [renderEncoder useResource:_vertexBuffer[indx] usage:MTLResourceUsageRead];
        }

        // Draw everything in the ICB.
        // CPU encoding: all commands are encoded with a draw, but only 1 draw can pass depth test.
        // GPU encoding: Only 1 command is encoded in the indirect command buffer.
        [renderEncoder executeCommandsInBuffer:_icb withRange:NSMakeRange(0, AAPLNumShapes)];

        _currentFrameID ++;
        if ((_currentFrameID % AAPLNumShapes) == 0)
        {
            _currentFrameIndex = (_currentFrameIndex + 1) % AAPLNumShapes;
        }

        [renderEncoder popDebugGroup];

        // We're done encoding commands
        [renderEncoder endEncoding];

        // Schedule a present once the framebuffer is complete using the current drawable
        [commandBuffer presentDrawable:view.currentDrawable];
    }

    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

@end

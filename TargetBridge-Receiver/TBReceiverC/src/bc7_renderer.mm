#include "bc7_renderer.h"
#include "bc7_cursor.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

#include <SDL.h>
#include <SDL_syswm.h>
#include <stdio.h>

typedef struct {
    vector_float2 cursor_position;
    vector_float2 drawable_size;
    uint32_t cursor_visible;
    uint32_t cursor_type;
    float cursor_size;
    uint32_t padding;
} TBCursorUniforms;

typedef struct {
    vector_float4 destination;
    vector_float4 source_uv;
    vector_float2 canvas_size;
    vector_float2 padding;
} TBBlitUniforms;

@interface TBPassthroughView : NSView
@end

@implementation TBPassthroughView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@interface TBBC7Renderer : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> compositionPipeline;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) id<MTLTexture> displayCanvas;
@property(nonatomic, strong) id<MTLTexture> patchTexture;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, assign) uint32_t textureWidth;
@property(nonatomic, assign) uint32_t textureHeight;
@property(nonatomic, assign) BOOL adaptiveCanvasActive;
@property(nonatomic, assign) int cursorX;
@property(nonatomic, assign) int cursorY;
@property(nonatomic, assign) int cursorSourceWidth;
@property(nonatomic, assign) int cursorSourceHeight;
@property(nonatomic, assign) BOOL cursorVisible;
@property(nonatomic, assign) int cursorType;
- (instancetype)initWithWindow:(SDL_Window *)window;
- (BOOL)renderBlocks:(const uint8_t *)blocks
              length:(size_t)length
               width:(uint32_t)width
              height:(uint32_t)height
         bytesPerRow:(uint32_t)bytesPerRow
   waitForCompletion:(BOOL)waitForCompletion;
- (BOOL)renderCurrentTextureWaitingForCompletion:(BOOL)waitForCompletion;
- (BOOL)applyAdaptiveFrame:(const struct tb_bc7_adaptive_frame *)frame
         waitForCompletion:(BOOL)waitForCompletion;
@end

static NSString *TBBC7RendererShader(void) {
    return [NSString stringWithUTF8String:R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct CursorUniforms {
    float2 cursor_position;
    float2 drawable_size;
    uint cursor_visible;
    uint cursor_type;
    float cursor_size;
    uint padding;
};

struct BlitUniforms {
    float4 destination;
    float4 source_uv;
    float2 canvas_size;
    float2 padding;
};

inline bool inside_rect(float2 p, float2 lo, float2 hi) {
    return all(p >= lo) && all(p <= hi);
}

inline bool inside_arrow(float2 p, float inset) {
    float2 q = p - inset;
    bool body = q.x >= 0.0 && q.y >= 0.0 && q.y <= 33.0 - 2.0 * inset &&
                q.x <= max(1.0, q.y * 0.62);
    bool stem = q.x >= 8.0 && q.x <= 14.0 - inset &&
                q.y >= 16.0 && q.y <= 31.0 - inset;
    return body || stem;
}

inline bool inside_horizontal_resize(float2 p, float inset) {
    float half_width = 16.0 - inset;
    float half_height = 6.0 - inset * 0.5;
    bool shaft = inside_rect(p, float2(-half_width + 6.0, -2.0 + inset),
                            float2(half_width - 6.0, 2.0 - inset));
    bool left = p.x >= -half_width && p.x <= -half_width + 8.0 &&
                abs(p.y) <= (p.x + half_width) + half_height * 0.25;
    bool right = p.x <= half_width && p.x >= half_width - 8.0 &&
                 abs(p.y) <= (half_width - p.x) + half_height * 0.25;
    return shaft || left || right;
}

inline bool inside_vertical_resize(float2 p, float inset) {
    return inside_horizontal_resize(p.yx, inset);
}

inline bool inside_diagonal_resize(float2 p, bool descending, float inset) {
    float2 q = descending ? p : float2(p.x, -p.y);
    float width = 4.0 - inset;
    bool shaft = abs(q.y - q.x) <= width && abs(q.x) <= 10.0 && abs(q.y) <= 10.0;
    bool first = q.x <= -8.0 && q.y <= -8.0 &&
                 q.x >= -16.0 + inset && q.y >= -16.0 + inset &&
                 (q.x <= -12.0 || q.y <= -12.0);
    bool second = q.x >= 8.0 && q.y >= 8.0 &&
                  q.x <= 16.0 - inset && q.y <= 16.0 - inset &&
                  (q.x >= 12.0 || q.y >= 12.0);
    return shaft || first || second;
}

inline bool cursor_mask(float2 pixel_delta, uint type, float size, float inset) {
    float scale = 32.0 / max(size, 1.0);
    float2 p = pixel_delta * scale;

    if (type == 1u) {
        bool bars = inside_rect(p, float2(-8.0 + inset, -14.0 + inset),
                               float2(8.0 - inset, -10.0 + inset)) ||
                    inside_rect(p, float2(-8.0 + inset, 10.0 - inset),
                               float2(8.0 - inset, 14.0 - inset));
        bool stem = inside_rect(p, float2(-2.0 + inset, -12.0 + inset),
                               float2(2.0 - inset, 12.0 - inset));
        return bars || stem;
    }
    if (type == 2u) {
        p += float2(10.0, 0.0);
        bool palm = inside_rect(p, float2(3.0 + inset, 11.0 + inset),
                               float2(16.0 - inset, 25.0 - inset));
        bool finger = inside_rect(p, float2(8.0 + inset, 1.0 + inset),
                                 float2(13.0 - inset, 17.0 - inset));
        bool thumb = p.x >= 0.0 + inset && p.x <= 9.0 - inset &&
                     p.y >= 12.0 + inset && p.y <= 21.0 - inset &&
                     p.y >= 21.0 - p.x;
        return palm || finger || thumb;
    }
    if (type == 3u) return inside_horizontal_resize(p, inset);
    if (type == 4u) return inside_vertical_resize(p, inset);
    if (type == 6u) {
        return inside_rect(p, float2(-15.0 + inset, -2.0 + inset),
                          float2(-2.0 - inset, 2.0 - inset)) ||
               inside_rect(p, float2(2.0 + inset, -2.0 + inset),
                          float2(15.0 - inset, 2.0 - inset)) ||
               inside_rect(p, float2(-2.0 + inset, -15.0 + inset),
                          float2(2.0 - inset, -2.0 - inset)) ||
               inside_rect(p, float2(-2.0 + inset, 2.0 + inset),
                          float2(2.0 - inset, 15.0 - inset));
    }
    if (type == 7u) return inside_diagonal_resize(p, true, inset);
    if (type == 8u) return inside_diagonal_resize(p, false, inset);
    return inside_arrow(p, inset);
}

vertex VertexOut tb_bc7_vertex(uint vertex_id [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    VertexOut out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    out.uv = uvs[vertex_id];
    return out;
}

vertex VertexOut tb_blit_vertex(
    uint vertex_id [[vertex_id]],
    constant BlitUniforms &blit [[buffer(0)]]
) {
    const float2 corners[3] = {
        float2(0.0, 0.0),
        float2(2.0, 0.0),
        float2(0.0, 2.0)
    };
    float2 corner = corners[vertex_id];
    float2 pixel = blit.destination.xy + corner * blit.destination.zw;
    VertexOut out;
    out.position = float4(
        pixel.x / blit.canvas_size.x * 2.0 - 1.0,
        1.0 - pixel.y / blit.canvas_size.y * 2.0,
        0.0,
        1.0
    );
    out.uv = blit.source_uv.xy + corner * blit.source_uv.zw;
    return out;
}

fragment float4 tb_blit_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]
) {
    constexpr sampler linear_sampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    float4 color = texture.sample(linear_sampler, in.uv);
    color.a = 1.0;
    return color;
}

fragment float4 tb_bc7_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]],
    constant CursorUniforms &cursor [[buffer(0)]]
) {
    constexpr sampler linear_sampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    float4 color = texture.sample(linear_sampler, in.uv);
    color.a = 1.0;
    if (cursor.cursor_visible == 0u) {
        return color;
    }

    float2 delta = in.position.xy - cursor.cursor_position;
    bool outer = cursor_mask(delta, cursor.cursor_type, cursor.cursor_size, 0.0);
    if (!outer) {
        return color;
    }

    bool inner = cursor_mask(delta, cursor.cursor_type, cursor.cursor_size, 1.5);
    return inner ? float4(0.0, 0.0, 0.0, 1.0)
                 : float4(1.0, 1.0, 1.0, 1.0);
}
)METAL"];
}

@implementation TBBC7Renderer

- (instancetype)initWithWindow:(SDL_Window *)window {
    self = [super init];
    if (!self || !window) return nil;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device || ![_device supportsBCTextureCompression]) {
        return nil;
    }
    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) return nil;

    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:TBBC7RendererShader()
                                                   options:nil
                                                     error:&error];
    if (!library) {
        fprintf(stderr, "[bc7] shader compile failed: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"tb_bc7_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"tb_bc7_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipeline) {
        fprintf(stderr, "[bc7] render pipeline creation failed: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }
    MTLRenderPipelineDescriptor *compositionDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    compositionDescriptor.vertexFunction =
        [library newFunctionWithName:@"tb_blit_vertex"];
    compositionDescriptor.fragmentFunction =
        [library newFunctionWithName:@"tb_blit_fragment"];
    compositionDescriptor.colorAttachments[0].pixelFormat =
        MTLPixelFormatBGRA8Unorm;
    _compositionPipeline =
        [_device newRenderPipelineStateWithDescriptor:compositionDescriptor
                                                error:&error];
    if (!_compositionPipeline) {
        fprintf(stderr, "[bc7] composition pipeline creation failed: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || !info.info.cocoa.window) {
        fprintf(stderr, "[bc7] unable to access SDL Cocoa window\n");
        return nil;
    }

    NSWindow *nsWindow = info.info.cocoa.window;
    NSView *contentView = nsWindow.contentView;
    if (!contentView) return nil;

    _view = [[TBPassthroughView alloc] initWithFrame:contentView.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.wantsLayer = YES;

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.contentsScale = nsWindow.backingScaleFactor;
    _view.layer = _metalLayer;
    _view.hidden = YES;
    [contentView addSubview:_view positioned:NSWindowAbove relativeTo:nil];

    _cursorSourceWidth = 1;
    _cursorSourceHeight = 1;
    return self;
}

- (void)updateDrawableSize {
    CGFloat scale = self.view.window.backingScaleFactor;
    CGSize size = self.view.bounds.size;
    self.metalLayer.contentsScale = scale;
    self.metalLayer.frame = self.view.bounds;
    self.metalLayer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}

- (BOOL)ensureTextureWidth:(uint32_t)width height:(uint32_t)height {
    if (self.texture && self.textureWidth == width && self.textureHeight == height) {
        return YES;
    }

    self.adaptiveCanvasActive = NO;
    self.patchTexture = nil;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC7_RGBAUnorm
                                                          width:width
                                                         height:height
                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = self.device.hasUnifiedMemory
        ? MTLStorageModeShared
        : MTLStorageModeManaged;
    self.texture = [self.device newTextureWithDescriptor:descriptor];
    self.textureWidth = self.texture ? width : 0;
    self.textureHeight = self.texture ? height : 0;
    return self.texture != nil;
}

- (BOOL)ensureDisplayCanvas {
    if (self.displayCanvas &&
        self.displayCanvas.width == TB_BC7_ADAPTIVE_CANVAS_WIDTH &&
        self.displayCanvas.height == TB_BC7_ADAPTIVE_CANVAS_HEIGHT) {
        return YES;
    }
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:TB_BC7_ADAPTIVE_CANVAS_WIDTH
                                                         height:TB_BC7_ADAPTIVE_CANVAS_HEIGHT
                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    self.displayCanvas = [self.device newTextureWithDescriptor:descriptor];
    return self.displayCanvas != nil;
}

- (id<MTLTexture>)makePatchTextureWidth:(uint32_t)width
                                  height:(uint32_t)height {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC7_RGBAUnorm
                                                          width:width
                                                         height:height
                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = self.device.hasUnifiedMemory
        ? MTLStorageModeShared
        : MTLStorageModeManaged;
    return [self.device newTextureWithDescriptor:descriptor];
}

- (void)encodeTexture:(id<MTLTexture>)source
          destination:(vector_float4)destination
             sourceUV:(vector_float4)sourceUV
              encoder:(id<MTLRenderCommandEncoder>)encoder {
    TBBlitUniforms uniforms = {
        .destination = destination,
        .source_uv = sourceUV,
        .canvas_size = {
            (float)TB_BC7_ADAPTIVE_CANVAS_WIDTH,
            (float)TB_BC7_ADAPTIVE_CANVAS_HEIGHT
        },
        .padding = {0.0f, 0.0f}
    };
    [encoder setRenderPipelineState:self.compositionPipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

- (BOOL)encodeCanvasPassWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                    clear:(BOOL)clear
                                    block:(void (^)(id<MTLRenderCommandEncoder>))block {
    if (!commandBuffer || !self.displayCanvas) return NO;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = self.displayCanvas;
    pass.colorAttachments[0].loadAction =
        clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;
    block(encoder);
    [encoder endEncoding];
    return YES;
}

- (BOOL)copyNativeRectToCanvasX:(uint32_t)x
                              y:(uint32_t)y
                          width:(uint32_t)width
                         height:(uint32_t)height
                          clear:(BOOL)clear {
    if (![self ensureDisplayCanvas] || !self.texture) return NO;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return NO;
    const vector_float4 destination = {
        (float)x, (float)y, (float)width, (float)height
    };
    const vector_float4 sourceUV = {
        (float)x / (float)self.textureWidth,
        (float)y / (float)self.textureHeight,
        (float)width / (float)self.textureWidth,
        (float)height / (float)self.textureHeight
    };
    if (![self encodeCanvasPassWithCommandBuffer:commandBuffer
                                           clear:clear
                                           block:^(id<MTLRenderCommandEncoder> encoder) {
        [self encodeTexture:self.texture
                destination:destination
                   sourceUV:sourceUV
                    encoder:encoder];
    }]) {
        return NO;
    }
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return commandBuffer.status == MTLCommandBufferStatusCompleted;
}

- (BOOL)renderBlocks:(const uint8_t *)blocks
              length:(size_t)length
               width:(uint32_t)width
              height:(uint32_t)height
         bytesPerRow:(uint32_t)bytesPerRow
   waitForCompletion:(BOOL)waitForCompletion {
    if (!blocks || width == 0 || height == 0 || (width & 3u) || (height & 3u)) {
        return NO;
    }
    size_t required = (size_t)bytesPerRow * (height / 4u);
    if (bytesPerRow != (width / 4u) * 16u || length < required) {
        return NO;
    }
    if (![self ensureTextureWidth:width height:height]) {
        return NO;
    }

    [self.texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:blocks
                    bytesPerRow:bytesPerRow];
    self.view.hidden = NO;
    return [self renderCurrentTextureWaitingForCompletion:waitForCompletion];
}

- (BOOL)uploadBlocks:(const uint8_t *)blocks
              length:(size_t)length
               width:(uint32_t)width
              height:(uint32_t)height
         bytesPerRow:(uint32_t)bytesPerRow {
    if (!blocks || width == 0 || height == 0 || (width & 3u) || (height & 3u)) {
        return NO;
    }
    size_t required = (size_t)bytesPerRow * (height / 4u);
    if (bytesPerRow != (width / 4u) * 16u || length < required ||
        ![self ensureTextureWidth:width height:height]) {
        return NO;
    }
    [self.texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:blocks
                    bytesPerRow:bytesPerRow];
    if (self.adaptiveCanvasActive &&
        ![self copyNativeRectToCanvasX:0 y:0 width:width height:height clear:YES]) {
        return NO;
    }
    self.view.hidden = NO;
    return YES;
}

- (BOOL)uploadBlocks:(const uint8_t *)blocks
              length:(size_t)length
        textureWidth:(uint32_t)textureWidth
       textureHeight:(uint32_t)textureHeight
                   x:(uint32_t)x
                   y:(uint32_t)y
               width:(uint32_t)width
              height:(uint32_t)height
         bytesPerRow:(uint32_t)bytesPerRow {
    if (!blocks || !self.texture ||
        self.textureWidth != textureWidth || self.textureHeight != textureHeight ||
        width == 0 || height == 0 || (x & 3u) || (y & 3u) ||
        (width & 3u) || (height & 3u) ||
        x + width > textureWidth || y + height > textureHeight) {
        return NO;
    }
    size_t required = (size_t)bytesPerRow * (height / 4u);
    if (bytesPerRow != (width / 4u) * 16u || length < required) {
        return NO;
    }
    [self.texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                    mipmapLevel:0
                      withBytes:blocks
                    bytesPerRow:bytesPerRow];
    if (self.adaptiveCanvasActive &&
        ![self copyNativeRectToCanvasX:x y:y width:width height:height clear:NO]) {
        return NO;
    }
    return YES;
}

- (BOOL)encodePresentWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              drawable:(id<CAMetalDrawable>)drawable {
    if (!commandBuffer || !drawable) return NO;
    id<MTLTexture> presentedTexture =
        self.adaptiveCanvasActive ? self.displayCanvas : self.texture;
    if (!presentedTexture) return NO;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;

    CGSize drawableSize = self.metalLayer.drawableSize;
    float cursorX = ((float)self.cursorX / (float)MAX(self.cursorSourceWidth, 1)) *
                    (float)drawableSize.width;
    float cursorY = ((float)self.cursorY / (float)MAX(self.cursorSourceHeight, 1)) *
                    (float)drawableSize.height;
    TBCursorUniforms cursor = {
        .cursor_position = { cursorX, cursorY },
        .drawable_size = { (float)drawableSize.width, (float)drawableSize.height },
        .cursor_visible = self.cursorVisible ? 1u : 0u,
        .cursor_type = (uint32_t)self.cursorType,
        .cursor_size = tb_bc7_cursor_size_for_drawable_width((float)drawableSize.width),
        .padding = 0
    };

    [encoder setRenderPipelineState:self.pipeline];
    [encoder setFragmentTexture:presentedTexture atIndex:0];
    [encoder setFragmentBytes:&cursor length:sizeof(cursor) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    return YES;
}

- (BOOL)renderCurrentTextureWaitingForCompletion:(BOOL)waitForCompletion {
    if ((!self.texture && !self.displayCanvas) || self.view.hidden) return NO;
    [self updateDrawableSize];
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return NO;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return NO;
    if (![self encodePresentWithCommandBuffer:commandBuffer drawable:drawable]) {
        return NO;
    }
    [commandBuffer commit];
    if (waitForCompletion) {
        [commandBuffer waitUntilCompleted];
        return commandBuffer.status == MTLCommandBufferStatusCompleted;
    }
    return YES;
}

- (BOOL)applyAdaptiveFrame:(const struct tb_bc7_adaptive_frame *)frame
         waitForCompletion:(BOOL)waitForCompletion {
    if (!frame || !self.texture ||
        self.textureWidth != frame->canvas_width ||
        self.textureHeight != frame->canvas_height ||
        ![self ensureDisplayCanvas]) {
        return NO;
    }
    const BOOL seedCanvas = !self.adaptiveCanvasActive;
    id<MTLTexture> patchTexture =
        [self makePatchTextureWidth:frame->atlas_width height:frame->atlas_height];
    if (!patchTexture) return NO;
    [patchTexture replaceRegion:MTLRegionMake2D(
                                    0, 0, frame->atlas_width, frame->atlas_height)
                    mipmapLevel:0
                      withBytes:frame->atlas_data
                    bytesPerRow:frame->atlas_bytes_per_row];

    for (uint16_t index = 0; index < frame->native_run_count; index++) {
        const struct tb_bc7_delta_run *run = &frame->native_runs[index];
        const uint32_t x =
            (uint32_t)run->tile_x * TB_BC7_DELTA_TILE_SIZE;
        const uint32_t y =
            (uint32_t)run->tile_y * TB_BC7_DELTA_TILE_SIZE;
        const uint32_t width =
            (uint32_t)run->tile_count_x * TB_BC7_DELTA_TILE_SIZE;
        const uint32_t rowBytes = (width / 4u) * 16u;
        [self.texture replaceRegion:MTLRegionMake2D(
                                        x, y, width, run->pixel_height)
                        mipmapLevel:0
                          withBytes:run->data
                        bytesPerRow:rowBytes];
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return NO;
    if (![self encodeCanvasPassWithCommandBuffer:commandBuffer
                                           clear:seedCanvas
                                           block:^(id<MTLRenderCommandEncoder> encoder) {
        if (seedCanvas) {
            [self encodeTexture:self.texture
                    destination:(vector_float4){
                        0.0f, 0.0f,
                        (float)frame->canvas_width,
                        (float)frame->canvas_height
                    }
                       sourceUV:(vector_float4){0.0f, 0.0f, 1.0f, 1.0f}
                        encoder:encoder];
        } else {
            for (uint16_t index = 0; index < frame->native_run_count; index++) {
                const struct tb_bc7_delta_run *run = &frame->native_runs[index];
                const float x =
                    (float)((uint32_t)run->tile_x * TB_BC7_DELTA_TILE_SIZE);
                const float y =
                    (float)((uint32_t)run->tile_y * TB_BC7_DELTA_TILE_SIZE);
                const float width =
                    (float)((uint32_t)run->tile_count_x * TB_BC7_DELTA_TILE_SIZE);
                const float height = (float)run->pixel_height;
                [self encodeTexture:self.texture
                        destination:(vector_float4){x, y, width, height}
                           sourceUV:(vector_float4){
                               x / (float)frame->canvas_width,
                               y / (float)frame->canvas_height,
                               width / (float)frame->canvas_width,
                               height / (float)frame->canvas_height
                           }
                            encoder:encoder];
            }
        }
        for (uint16_t index = 0; index < frame->patch_count; index++) {
            const struct tb_bc7_adaptive_patch *patch = &frame->patches[index];
            [self encodeTexture:patchTexture
                    destination:(vector_float4){
                        (float)patch->destination_x,
                        (float)patch->destination_y,
                        (float)patch->destination_width,
                        (float)patch->destination_height
                    }
                       sourceUV:(vector_float4){
                           (float)patch->atlas_source_x / frame->atlas_width,
                           (float)patch->atlas_source_y / frame->atlas_height,
                           (float)patch->atlas_source_width / frame->atlas_width,
                           (float)patch->atlas_source_height / frame->atlas_height
                       }
                        encoder:encoder];
        }
    }]) {
        return NO;
    }

    self.adaptiveCanvasActive = YES;
    self.patchTexture = patchTexture;
    self.view.hidden = NO;
    [self updateDrawableSize];
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable ||
        ![self encodePresentWithCommandBuffer:commandBuffer drawable:drawable]) {
        self.adaptiveCanvasActive = seedCanvas ? NO : YES;
        return NO;
    }
    [commandBuffer commit];
    if (waitForCompletion) {
        [commandBuffer waitUntilCompleted];
        return commandBuffer.status == MTLCommandBufferStatusCompleted;
    }
    return YES;
}

@end

int tb_bc7_renderer_supported(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device && [device supportsBCTextureCompression] ? 1 : 0;
}

int tb_bc7_renderer_copy_device_name(char *buffer, size_t buffer_size) {
    if (!buffer || buffer_size == 0) return -1;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    const char *name = device.name.UTF8String;
    if (!device || !name) {
        buffer[0] = '\0';
        return -1;
    }
    snprintf(buffer, buffer_size, "%s", name);
    return 0;
}

struct tb_bc7_renderer *tb_bc7_renderer_create(SDL_Window *window) {
    TBBC7Renderer *renderer = [[TBBC7Renderer alloc] initWithWindow:window];
    return (__bridge_retained struct tb_bc7_renderer *)renderer;
}

void tb_bc7_renderer_destroy(struct tb_bc7_renderer *renderer) {
    if (!renderer) return;
    TBBC7Renderer *object = CFBridgingRelease(renderer);
    [object.view removeFromSuperview];
}

void tb_bc7_renderer_set_visible(struct tb_bc7_renderer *renderer, int visible) {
    if (!renderer) return;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    if (!visible) {
        object.adaptiveCanvasActive = NO;
        object.patchTexture = nil;
    }
    object.view.hidden = visible ? NO : YES;
}

int tb_bc7_renderer_render(struct tb_bc7_renderer *renderer,
                           const uint8_t *blocks,
                           size_t length,
                           uint32_t width,
                           uint32_t height,
                           uint32_t bytes_per_row,
                           int wait_for_completion) {
    if (!renderer) return -1;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    return [object renderBlocks:blocks
                         length:length
                          width:width
                         height:height
                    bytesPerRow:bytes_per_row
              waitForCompletion:wait_for_completion ? YES : NO] ? 0 : -1;
}

int tb_bc7_renderer_upload(struct tb_bc7_renderer *renderer,
                           const uint8_t *blocks,
                           size_t length,
                           uint32_t width,
                           uint32_t height,
                           uint32_t bytes_per_row) {
    if (!renderer) return -1;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    return [object uploadBlocks:blocks
                        length:length
                         width:width
                        height:height
                   bytesPerRow:bytes_per_row] ? 0 : -1;
}

int tb_bc7_renderer_upload_region(struct tb_bc7_renderer *renderer,
                                  const uint8_t *blocks,
                                  size_t length,
                                  uint32_t texture_width,
                                  uint32_t texture_height,
                                  uint32_t x,
                                  uint32_t y,
                                  uint32_t width,
                                  uint32_t height,
                                  uint32_t bytes_per_row) {
    if (!renderer) return -1;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    return [object uploadBlocks:blocks
                        length:length
                  textureWidth:texture_width
                 textureHeight:texture_height
                             x:x
                             y:y
                         width:width
                        height:height
                   bytesPerRow:bytes_per_row] ? 0 : -1;
}

int tb_bc7_renderer_present(struct tb_bc7_renderer *renderer,
                            int wait_for_completion) {
    if (!renderer) return -1;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    return [object renderCurrentTextureWaitingForCompletion:
        wait_for_completion ? YES : NO] ? 0 : -1;
}

int tb_bc7_renderer_apply_adaptive(
    struct tb_bc7_renderer *renderer,
    const struct tb_bc7_adaptive_frame *frame,
    int wait_for_completion) {
    if (!renderer) return -1;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    return [object applyAdaptiveFrame:frame
                    waitForCompletion:wait_for_completion ? YES : NO] ? 0 : -1;
}

void tb_bc7_renderer_set_cursor(struct tb_bc7_renderer *renderer,
                                int x,
                                int y,
                                int source_width,
                                int source_height,
                                int visible,
                                int type) {
    if (!renderer) return;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    object.cursorX = x;
    object.cursorY = y;
    object.cursorSourceWidth = MAX(source_width, 1);
    object.cursorSourceHeight = MAX(source_height, 1);
    object.cursorVisible = visible ? YES : NO;
    object.cursorType = tb_bc7_cursor_normalize_type(type);
}

void tb_bc7_renderer_redraw(struct tb_bc7_renderer *renderer) {
    if (!renderer) return;
    TBBC7Renderer *object = (__bridge TBBC7Renderer *)renderer;
    [object renderCurrentTextureWaitingForCompletion:NO];
}

#include "bc7_renderer.h"
#include "bc7_cursor.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

#include <SDL.h>
#include <SDL_syswm.h>

typedef struct {
    vector_float2 cursor_position;
    vector_float2 drawable_size;
    uint32_t cursor_visible;
    uint32_t cursor_type;
    float cursor_size;
    uint32_t padding;
} TBCursorUniforms;

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
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, assign) uint32_t textureWidth;
@property(nonatomic, assign) uint32_t textureHeight;
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

- (BOOL)renderCurrentTextureWaitingForCompletion:(BOOL)waitForCompletion {
    if (!self.texture || self.view.hidden) return NO;
    [self updateDrawableSize];
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return NO;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return NO;
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
    [encoder setFragmentTexture:self.texture atIndex:0];
    [encoder setFragmentBytes:&cursor length:sizeof(cursor) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
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

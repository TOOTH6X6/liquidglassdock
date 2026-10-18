// LiquidGlassDock v0.2: experimental iOS 26 style Liquid Glass Dock for iOS 16 (SpringBoard), real-time backdrop.
// The refraction maths is ported from "Backdrop" by Kyant (Apache-2.0), see NOTICE.txt.
// Changes from the original AGSL: ported to Metal (MSL); the corner radius is read from the
// centred coordinate (the original used the raw coordinate); chromatic aberration uses 3 taps
// instead of 7; blur is an MPS Gaussian blur re-run every captured frame (dock region only).
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <simd/simd.h>

// ---- look (tuned to resemble the iOS 26 Dock: light frosted pill, thin rim, soft edge lensing) ----
#define LG_REFRACT_HEIGHT 14.0   // pt: width of the refracting rim
#define LG_REFRACT_AMOUNT 22.0   // pt: how far the rim bends the image
#define LG_CORNER 36.0           // pt: max corner radius
#define LG_BLUR_SIGMA 3.5        // pt: backdrop blur (lower = more see-through)
#define LG_CHROMA 0.8            // 0 = no colour fringing
#define LG_SAT 1.25              // backdrop saturation boost
#define LG_TINT 0.10             // white veil strength (0..1)
#define LG_RIM 0.55              // rim highlight strength
#define LG_GLOW 0.05             // soft inner glow near the edge
// ---- real-time ----
#define LG_LIVE 1                // 1 = real-time (Dock hidden from capture via disableUpdateMask), 0 = old one-shot capture
#define LG_FPS 60                // capture/render rate while the Dock is visible
#define LG_MASK_BITS 0x12        // CALayer disableUpdateMask bits: hide from screenshots / recording
#define LG_TAG(...) @#__VA_ARGS__

static NSString *const kMSL = LG_TAG(
struct U { float2 size; float2 origin; float4 radii; float refH; float refA; float depth; float chroma; float scale; float tint; float sat; float rim; float glow; };
float radiusAt(float2 c, float4 r) { return c.x >= 0.0 ? (c.y <= 0.0 ? r.y : r.z) : (c.y <= 0.0 ? r.x : r.w); }
float sdRR(float2 c, float2 hs, float r) {
  float2 q = abs(c) - (hs - float2(r));
  return length(max(q, 0.0)) - r + min(max(q.x, q.y), 0.0);
}
float2 gradRR(float2 c, float2 hs, float r) {
  float2 q = abs(c) - (hs - float2(r));
  if (q.x >= 0.0 || q.y >= 0.0) { float2 m = max(q, 0.0); return sign(c) * m / max(length(m), 1e-4); }
  float gx = step(q.y, q.x);
  return sign(c) * float2(gx, 1.0 - gx);
}
vertex float4 vmain(uint v [[vertex_id]]) {
  float2 p = float2((v << 1) & 2, v & 2);
  return float4(p * 2.0 - 1.0, 0.0, 1.0);
}
fragment float4 fmain(float4 pos [[position]], constant U &u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
  float2 hs = u.size * 0.5;
  float2 cc = pos.xy - hs;
  float rad = radiusAt(cc, u.radii);
  float sd = sdRR(cc, hs, rad);
  float alpha = clamp(0.5 - sd, 0.0, 1.0);
  if (alpha <= 0.0) return float4(0.0);
  float depthIn = -min(sd, 0.0);
  float gr = min(rad * 1.5, min(hs.x, hs.y));
  float2 n = gradRR(cc, hs, gr);
  float2 off = float2(0.0);
  if (depthIn < u.refH) {
    float x = clamp(1.0 - depthIn / u.refH, 0.0, 1.0);
    float d = (1.0 - sqrt(1.0 - x * x)) * u.refA;
    float2 g = n + u.depth * normalize(cc + 1e-4);
    off = d * g / max(length(g), 1e-4);
  }
  float2 p = pos.xy + u.origin + off;
  float2 disp = off * u.chroma * (cc.x * cc.y) / (hs.x * hs.y);
  float3 col = float3(t.sample(s, p + disp).r, t.sample(s, p).g, t.sample(s, p - disp).b);
  float lum = dot(col, float3(0.299, 0.587, 0.114));
  col = mix(float3(lum), col, u.sat);
  float vy = pos.y / u.size.y;
  col = mix(col, float3(1.0), u.tint + 0.05 * (1.0 - vy));
  col += float3(exp(-depthIn / (7.0 * u.scale)) * u.glow);
  float rim = exp(-depthIn / (1.2 * u.scale)) * pow(abs(dot(n, normalize(float2(-1.0, -1.0)))), 1.5) * u.rim;
  col = clamp(col + rim, 0.0, 1.0);
  return float4(col * alpha, alpha);
}
);

typedef struct { simd_float2 size; simd_float2 origin; simd_float4 radii; float refH, refA, depth, chroma, scale, tint, sat, rim, glow; } LGU;

@interface CALayer (LGPrivate) @property (nonatomic) uint32_t disableUpdateMask; @end

static id<MTLDevice> gDev; static id<MTLCommandQueue> gQ; static id<MTLRenderPipelineState> gPSO; static id<MTLTexture> gTex, gSrc;
static __weak UIView *gDock; static char kGlassKey;
static IOSurfaceRef gSurf; static size_t gW, gH;
static MPSImageGaussianBlur *gBlur;
static void (*gCapFn)(uint32_t, CFStringRef, IOSurfaceRef, int, int);
static dispatch_queue_t gCapQ;
static CADisplayLink *gLink; static BOOL gBusy;
static uint32_t gOldMask __attribute__((unused)); static CGFloat gOldAlpha __attribute__((unused));
static int gBlankTok = -1;

@interface LGGlass : UIView @end
@implementation LGGlass
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
  if ((self = [super initWithFrame:f])) {
    self.userInteractionEnabled = NO; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    ml.device = gDev; ml.pixelFormat = MTLPixelFormatBGRA8Unorm; ml.framebufferOnly = YES; ml.opaque = NO;
  }
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat sc = UIScreen.mainScreen.scale;
  CAMetalLayer *ml = (CAMetalLayer *)self.layer;
  ml.contentsScale = sc;
  if (!CGRectIsEmpty(self.bounds)) ml.drawableSize = CGSizeMake(self.bounds.size.width * sc, self.bounds.size.height * sc);
}
@end

static BOOL LGSetup(void) {
  if (gSrc && gTex && gBlur && gCapFn) return YES;
  UIScreen *s = UIScreen.mainScreen; gW = s.nativeBounds.size.width; gH = s.nativeBounds.size.height;
  gCapFn = (void (*)(uint32_t, CFStringRef, IOSurfaceRef, int, int))dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
  if (!gCapFn) { NSLog(@"[LGDock] CARenderServerRenderDisplay not found"); return NO; }
  NSDictionary *props = @{ (id)kIOSurfaceWidth: @(gW), (id)kIOSurfaceHeight: @(gH), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241) };
  gSurf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!gSurf) { NSLog(@"[LGDock] IOSurfaceCreate failed"); return NO; }
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:gW height:gH mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  gSrc = [gDev newTextureWithDescriptor:td iosurface:gSurf plane:0];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  gTex = [gDev newTextureWithDescriptor:td];
  if (!gSrc || !gTex) { NSLog(@"[LGDock] texture creation failed"); return NO; }
  gBlur = [[MPSImageGaussianBlur alloc] initWithDevice:gDev sigma:LG_BLUR_SIGMA * s.scale];
  gBlur.edgeMode = MPSImageEdgeModeClamp;
  gCapQ = dispatch_queue_create("com.example.liquidglassdock.capture", DISPATCH_QUEUE_SERIAL);
  NSLog(@"[LGDock] capture buffers %zux%zu", gW, gH);
  return YES;
}

// Hide the whole Dock (glass + icons) from the display capture so the glass only sees the wallpaper / content behind it.
static void LGHide(BOOL hide) {
  UIView *d = gDock; if (!d) return;
#if LG_LIVE
  if (hide) { gOldMask = d.layer.disableUpdateMask; d.layer.disableUpdateMask = gOldMask | LG_MASK_BITS; }
  else d.layer.disableUpdateMask = gOldMask;
#else
  if (hide) { gOldAlpha = d.alpha; d.alpha = 0; } else d.alpha = gOldAlpha;
#endif
}

// One frame: capture the display without the Dock, blur the Dock region, draw the glass. Call on the main thread.
static void LGFrame(void) {
  UIView *dock = gDock; LGGlass *g = dock ? objc_getAssociatedObject(dock, &kGlassKey) : nil;
  if (!g || !g.window || gBusy || !gPSO) return;
  if (!LGSetup()) return;
  CAMetalLayer *ml = (CAMetalLayer *)g.layer;
  if (ml.drawableSize.width < 1 || ml.drawableSize.height < 1) return;
  CGFloat sc = UIScreen.mainScreen.scale;
  CGRect r = [g convertRect:g.bounds toView:nil];  // window coords (= screen coords for the SpringBoard window)
  CGFloat m = (LG_REFRACT_AMOUNT + 3.0 * LG_BLUR_SIGMA + 4.0) * sc;
  NSInteger x0 = MAX(0, (NSInteger)floor(r.origin.x * sc - m)), y0 = MAX(0, (NSInteger)floor(r.origin.y * sc - m));
  NSInteger x1 = MIN((NSInteger)gW, (NSInteger)ceil((r.origin.x + r.size.width) * sc + m));
  NSInteger y1 = MIN((NSInteger)gH, (NSInteger)ceil((r.origin.y + r.size.height) * sc + m));
  if (x1 <= x0 || y1 <= y0) return;
  MTLRegion clip = MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0);
  CGFloat w = g.bounds.size.width, h = g.bounds.size.height;
  float rad = MIN(LG_CORNER, MIN(w, h) / 2) * sc;
  LGU u = { .size = simd_make_float2(w * sc, h * sc), .origin = simd_make_float2(r.origin.x * sc, r.origin.y * sc),
            .radii = simd_make_float4(rad, rad, rad, rad), .refH = LG_REFRACT_HEIGHT * sc, .refA = -LG_REFRACT_AMOUNT * sc,
            .depth = 0, .chroma = LG_CHROMA, .scale = sc, .tint = LG_TINT, .sat = LG_SAT, .rim = LG_RIM, .glow = LG_GLOW };
  gBusy = YES;
  LGHide(YES); [CATransaction flush];
  double delay = LG_LIVE ? 0.0 : 0.08;
  dispatch_async(gCapQ, ^{
    if (delay > 0) [NSThread sleepForTimeInterval:delay];
    gCapFn(0, CFSTR("LCD"), gSurf, 0, 0);
    dispatch_async(dispatch_get_main_queue(), ^{ LGHide(NO); });
    id<MTLCommandBuffer> cb = [gQ commandBuffer];
    gBlur.clipRect = clip;
    gBlur.offset = (MPSOffset){ .x = x0, .y = y0, .z = 0 };
    [gBlur encodeToCommandBuffer:cb sourceTexture:gSrc destinationTexture:gTex];
    id<CAMetalDrawable> dr = [ml nextDrawable];
    if (dr) {
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
      rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
      LGU uu = u;
      [en setRenderPipelineState:gPSO]; [en setFragmentBytes:&uu length:sizeof(uu) atIndex:0]; [en setFragmentTexture:gTex atIndex:0];
      [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
      [cb presentDrawable:dr];
    }
    [cb commit]; [cb waitUntilCompleted];
    dispatch_async(dispatch_get_main_queue(), ^{ gBusy = NO; });
  });
}

static BOOL LGShouldRun(void) {
  UIView *d = gDock; if (!d || !d.window) return NO;
  for (UIView *v = d; v; v = v.superview) if (v.hidden || v.alpha < 0.01) return NO;
  if (gBlankTok >= 0) { uint64_t st = 0; notify_get_state(gBlankTok, &st); if (st) return NO; }
  return YES;
}

@interface LGTicker : NSObject @end
@implementation LGTicker
- (void)tick:(CADisplayLink *)l { if (LGShouldRun()) LGFrame(); }
@end

static void LGStart(void) {
#if LG_LIVE
  if (gLink) return;
  static LGTicker *tk; tk = [LGTicker new];
  gLink = [CADisplayLink displayLinkWithTarget:tk selector:@selector(tick:)];
  gLink.preferredFramesPerSecond = LG_FPS;
  [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  NSLog(@"[LGDock] live capture started (%d fps)", LG_FPS);
#else
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LGFrame(); });
#endif
}
static void onNotify(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef i) {
  dispatch_async(dispatch_get_main_queue(), ^{ LGFrame(); });
}

@interface SBDockView : UIView @end
%hook SBDockView
- (void)layoutSubviews {
  %orig;
  UIView *bg = nil;
  for (NSString *k in @[@"backgroundView", @"_backgroundView"]) {
    @try { bg = [self valueForKey:k]; } @catch (NSException *e) { bg = nil; }
    if ([bg isKindOfClass:UIView.class]) break;
  }
  if (![bg isKindOfClass:UIView.class]) {
    static BOOL once; if (!once) { once = YES; NSLog(@"[LGDock] SBDockView has no backgroundView; subviews: %@", self.subviews); }
    return;
  }
  LGGlass *g = objc_getAssociatedObject(self, &kGlassKey);
  if (!g) {
    g = [[LGGlass alloc] initWithFrame:bg.frame];
    objc_setAssociatedObject(self, &kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self insertSubview:g aboveSubview:bg];
    gDock = self;
    NSLog(@"[LGDock] glass attached over %@", NSStringFromClass(bg.class));
    LGStart();
  }
  if (!CGRectEqualToRect(g.frame, bg.frame)) g.frame = bg.frame;
  bg.alpha = 0;
}
%end

%ctor {
  gDev = MTLCreateSystemDefaultDevice(); if (!gDev) { NSLog(@"[LGDock] no Metal device"); return; }
  gQ = [gDev newCommandQueue];
  NSError *e = nil;
  id<MTLLibrary> lib = [gDev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:kMSL] options:nil error:&e];
  if (!lib) { NSLog(@"[LGDock] MSL compile error: %@", e); return; }
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [lib newFunctionWithName:@"vmain"]; pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  gPSO = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
  if (!gPSO) { NSLog(@"[LGDock] pipeline error: %@", e); return; }
  notify_register_check("com.apple.springboard.hasBlankedScreen", &gBlankTok);
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onNotify, CFSTR("com.example.liquidglassdock.recapture"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
  %init;
  NSLog(@"[LGDock] ready");
}

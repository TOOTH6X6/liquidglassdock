// LiquidGlassDock v0.5: experimental iOS 26 style Liquid Glass Dock for iOS 16 (SpringBoard), live backdrop.
// The refraction maths is ported from "Backdrop" by Kyant (Apache-2.0), see NOTICE.txt.
// Changes from the original AGSL: ported to Metal (MSL); the corner radius is read from the
// centred coordinate (the original used the raw coordinate); chromatic aberration uses 3 taps
// instead of 7. The blurred glass body is a live CABackdropLayer (real-time, handled by the render server,
// never sees the Dock icons). A Metal layer on top adds the veil, glow, rim and edge refraction.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <simd/simd.h>

#define LG_REFRACT_HEIGHT 14.0   // pt: width of the refracting rim
#define LG_REFRACT_AMOUNT 22.0   // pt: how far the rim bends the image
#define LG_CORNER 36.0           // pt: max corner radius
#define LG_BLUR_RADIUS 9.0       // live backdrop blur radius (pt), the glass body
#define LG_BACKDROP_SAT 1.3      // live backdrop saturation
#define LG_REFRACT_MIX 0.7       // 0..1 how strongly the rim shows the refracted wallpaper capture
#define LG_BLUR_SIGMA 4.0        // pt: blur of the wallpaper capture used at the rim
#define LG_CHROMA 0.8            // 0 = no colour fringing
#define LG_SAT 1.25              // rim saturation boost
#define LG_TINT 0.10             // white veil strength over the live blur (0..1)
#define LG_RIM 0.55              // rim highlight strength
#define LG_GLOW 0.05             // soft inner glow near the edge
#define LG_TAG(...) @#__VA_ARGS__

static NSString *const kMSL = LG_TAG(
struct U { float2 size; float2 origin; float4 radii; float refH; float refA; float depth; float chroma; float scale; float tint; float sat; float rim; float glow; float refMix; };
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
  float wr = 0.0;
  float3 col = float3(1.0);
  if (depthIn < u.refH) {
    float x = clamp(1.0 - depthIn / u.refH, 0.0, 1.0);
    float d = (1.0 - sqrt(1.0 - x * x)) * u.refA;
    float2 g = n + u.depth * normalize(cc + 1e-4);
    float2 off = d * g / max(length(g), 1e-4);
    float2 p = pos.xy + u.origin + off;
    float2 disp = off * u.chroma * (cc.x * cc.y) / (hs.x * hs.y);
    float3 r = float3(t.sample(s, p + disp).r, t.sample(s, p).g, t.sample(s, p - disp).b);
    float lum = dot(r, float3(0.299, 0.587, 0.114));
    r = mix(float3(lum), r, u.sat);
    col = mix(r, float3(1.0), u.tint);
    wr = (1.0 - smoothstep(0.0, u.refH, depthIn)) * u.refMix;
  }
  float vy = pos.y / u.size.y;
  float veil = u.tint + 0.05 * (1.0 - vy);
  float a = max(veil, wr);
  float3 base = mix(float3(1.0), col, wr);
  float glow = exp(-depthIn / (7.0 * u.scale)) * u.glow;
  float rim = exp(-depthIn / (1.2 * u.scale)) * pow(abs(dot(n, normalize(float2(-1.0, -1.0)))), 1.5) * u.rim;
  float h = glow + rim;
  float3 pm = clamp(base * a + float3(h), 0.0, 1.0);
  float aa = clamp(a + h, 0.0, 1.0);
  return float4(pm * alpha, aa * alpha);
}
);

typedef struct { simd_float2 size; simd_float2 origin; simd_float4 radii; float refH, refA, depth, chroma, scale, tint, sat, rim, glow, refMix; } LGU;

static id<MTLDevice> gDev; static id<MTLCommandQueue> gQ; static id<MTLRenderPipelineState> gPSO; static id<MTLTexture> gTex;
static NSHashTable *gViews; static __weak UIView *gDock; static char kGlassKey; static char kBackdropKey;

@interface LGGlass : UIView @end
@implementation LGGlass
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
  if ((self = [super initWithFrame:f])) {
    self.userInteractionEnabled = NO; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    ml.device = gDev; ml.pixelFormat = MTLPixelFormatBGRA8Unorm; ml.framebufferOnly = YES; ml.opaque = NO;
    [gViews addObject:self];
  }
  return self;
}
- (void)layoutSubviews { [super layoutSubviews]; [self render]; }
- (void)render {
  if (!gPSO || CGRectIsEmpty(self.bounds)) return;
  CGFloat sc = UIScreen.mainScreen.scale, w = self.bounds.size.width, h = self.bounds.size.height;
  CAMetalLayer *ml = (CAMetalLayer *)self.layer;
  ml.contentsScale = sc; ml.drawableSize = CGSizeMake(w * sc, h * sc);
  CGRect r = [self convertRect:self.bounds toView:nil];
  float rad = MIN(LG_CORNER, MIN(w, h) / 2) * sc;
  LGU u = { .size = simd_make_float2(w * sc, h * sc), .origin = simd_make_float2(r.origin.x * sc, r.origin.y * sc),
            .radii = simd_make_float4(rad, rad, rad, rad), .refH = LG_REFRACT_HEIGHT * sc, .refA = -LG_REFRACT_AMOUNT * sc,
            .depth = 0, .chroma = LG_CHROMA, .scale = sc, .tint = LG_TINT, .sat = LG_SAT, .rim = LG_RIM, .glow = LG_GLOW, .refMix = LG_REFRACT_MIX };
  id<CAMetalDrawable> dr = [ml nextDrawable]; if (!dr) return;
  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLCommandBuffer> cb = [gQ commandBuffer];
  id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:gPSO]; [en setFragmentBytes:&u length:sizeof(u) atIndex:0];
  if (gTex) [en setFragmentTexture:gTex atIndex:0];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  [cb presentDrawable:dr]; [cb commit];
}
@end

// Capture the whole display once (Dock hidden), blur it, keep it as the texture used for the rim refraction.
static void LGCapture(void) {
  UIScreen *s = UIScreen.mainScreen; size_t W = s.nativeBounds.size.width, H = s.nativeBounds.size.height;
  typedef void (*Fn)(uint32_t, CFStringRef, IOSurfaceRef, int, int);
  Fn fn = (Fn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
  if (!fn) { NSLog(@"[LGDock] CARenderServerRenderDisplay not found"); return; }
  NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241) };
  IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!surf) { NSLog(@"[LGDock] IOSurfaceCreate failed"); return; }
  fn(0, CFSTR("LCD"), surf, 0, 0);
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> src = [gDev newTextureWithDescriptor:td iosurface:surf plane:0];
  CFRelease(surf);
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> dst = [gDev newTextureWithDescriptor:td];
  if (!src || !dst) { NSLog(@"[LGDock] texture creation failed"); return; }
  MPSImageGaussianBlur *g = [[MPSImageGaussianBlur alloc] initWithDevice:gDev sigma:LG_BLUR_SIGMA * s.scale];
  g.edgeMode = MPSImageEdgeModeClamp;
  id<MTLCommandBuffer> cb = [gQ commandBuffer];
  [g encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst];
  [cb commit]; [cb waitUntilCompleted];
  gTex = dst;
  NSLog(@"[LGDock] captured %zux%zu", W, H);
  for (LGGlass *v in gViews.allObjects) [v render];
}
static void LGRecapture(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *d = gDock; if (!d || !d.window) return;
    CGFloat old = d.alpha;
    d.alpha = 0; [CATransaction flush]; [NSThread sleepForTimeInterval:0.08];
    LGCapture();
    d.alpha = old;
  });
}
static void onNotify(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef i) { LGRecapture(); }

static CALayer *LGMakeBackdrop(void) {
  Class BL = NSClassFromString(@"CABackdropLayer"), FL = NSClassFromString(@"CAFilter");
  if (!BL || !FL) { NSLog(@"[LGDock] CABackdropLayer or CAFilter missing"); return nil; }
  CALayer *b = [[BL alloc] init];
  @try {
    [b setValue:@YES forKey:@"windowServerAware"];
    [b setValue:@"LGDockBackdrop" forKey:@"groupName"];
    id (*mk)(Class, SEL, NSString *) = (id (*)(Class, SEL, NSString *))objc_msgSend;
    id blur = mk(FL, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
    [blur setValue:@(LG_BLUR_RADIUS) forKey:@"inputRadius"];
    [blur setValue:@YES forKey:@"inputNormalizeEdges"];
    id sat = mk(FL, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
    [sat setValue:@(LG_BACKDROP_SAT) forKey:@"inputAmount"];
    b.filters = @[blur, sat];
  } @catch (NSException *e) { NSLog(@"[LGDock] backdrop setup failed: %@", e); }
  b.masksToBounds = YES; b.cornerCurve = kCACornerCurveContinuous;
  return b;
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
  CALayer *bd = objc_getAssociatedObject(self, &kBackdropKey);
  if (!g) {
    g = [[LGGlass alloc] initWithFrame:bg.frame];
    objc_setAssociatedObject(self, &kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self insertSubview:g aboveSubview:bg];
    bd = LGMakeBackdrop();
    if (bd) {
      objc_setAssociatedObject(self, &kBackdropKey, bd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      [self.layer insertSublayer:bd below:g.layer];
    }
    gDock = self;
    NSLog(@"[LGDock] glass attached over %@ (backdrop %@)", NSStringFromClass(bg.class), bd ? @"yes" : @"no");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LGRecapture(); });
  }
  if (!CGRectEqualToRect(g.frame, bg.frame)) g.frame = bg.frame;
  if (bd) {
    bd.frame = bg.frame;
    bd.cornerRadius = MIN(LG_CORNER, MIN(bg.bounds.size.width, bg.bounds.size.height) / 2);
  }
  bg.alpha = 0;
}
%end

%ctor {
  gDev = MTLCreateSystemDefaultDevice(); if (!gDev) { NSLog(@"[LGDock] no Metal device"); return; }
  gQ = [gDev newCommandQueue]; gViews = [NSHashTable weakObjectsHashTable];
  NSError *e = nil;
  id<MTLLibrary> lib = [gDev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:kMSL] options:nil error:&e];
  if (!lib) { NSLog(@"[LGDock] MSL compile error: %@", e); return; }
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [lib newFunctionWithName:@"vmain"]; pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  gPSO = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
  if (!gPSO) { NSLog(@"[LGDock] pipeline error: %@", e); return; }
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onNotify, CFSTR("com.example.liquidglassdock.recapture"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
  %init;
  NSLog(@"[LGDock] ready");
}

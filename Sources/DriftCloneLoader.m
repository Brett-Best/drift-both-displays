#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

typedef void (*DriftVoidIMP)(id, SEL);

static DriftVoidIMP DriftOriginalPrepare;
static DriftVoidIMP DriftOriginalStart;
static NSBundle *DriftRendererBundle;
static const void *DriftForcedScreenKey = &DriftForcedScreenKey;
#if DRIFT_PIXEL_DIAGNOSTICS
static DriftVoidIMP DriftInheritedAnimate;
static const void *DriftDiagnosticFrameKey = &DriftDiagnosticFrameKey;
static const void *DriftDiagnosticLoggedKey = &DriftDiagnosticLoggedKey;
#endif

static id DriftReadObjectIvar(id object, const char *name)
{
    if (object == nil) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar == NULL ? nil : object_getIvar(object, ivar);
}

static CGDirectDisplayID DriftDisplayID(NSScreen *screen)
{
    return (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

static NSScreen *DriftTargetScreen(NSView *view, NSWindow *window)
{
    NSSize wanted = view.bounds.size;
    NSScreen *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;

    for (NSScreen *screen in NSScreen.screens) {
        NSSize points = screen.frame.size;
        CGFloat scale = MAX(screen.backingScaleFactor, 1.0);
        CGFloat pointScore = fabs(wanted.width - points.width) +
                             fabs(wanted.height - points.height);
        CGFloat pixelScore = fabs(wanted.width - points.width * scale) +
                             fabs(wanted.height - points.height * scale);
        CGFloat score = MIN(pointScore, pixelScore);
        if (score < bestScore) {
            bestScore = score;
            best = screen;
        }
    }

    if (best != nil && bestScore <= 8.0) return best;
    return window.screen ?: best ?: NSScreen.mainScreen;
}

static NSScreen *DriftWindowScreen(id self, SEL selector)
{
    NSScreen *forced = objc_getAssociatedObject(self, DriftForcedScreenKey);
    if (forced != nil) return forced;

    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass(object_getClass(self)),
    };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, selector);
}

static CGFloat DriftWindowBackingScaleFactor(id self, SEL selector)
{
    NSScreen *forced = objc_getAssociatedObject(self, DriftForcedScreenKey);
    if (forced != nil) return MAX(forced.backingScaleFactor, 1.0);

    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass(object_getClass(self)),
    };
    return ((CGFloat (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, selector);
}

static Class DriftTemporaryWindowClass(Class originalClass)
{
    char name[96];
    snprintf(name, sizeof(name), "DriftScreenWindow_%lx", (unsigned long)originalClass);
    Class subclass = objc_lookUpClass(name);
    if (subclass != Nil) return subclass;

    subclass = objc_allocateClassPair(originalClass, name, 0);
    if (subclass == Nil) return Nil;
    class_addMethod(subclass, @selector(screen), (IMP)DriftWindowScreen, "@@:");
    class_addMethod(subclass,
                    @selector(backingScaleFactor),
                    (IMP)DriftWindowBackingScaleFactor,
                    "d@:");
    objc_registerClassPair(subclass);
    return subclass;
}

static void DriftPatchedPrepare(id self, SEL selector)
{
    if (DriftReadObjectIvar(self, "orchestrator") != nil) return;

    NSView *view = self;
    NSWindow *window = view.window;
    NSSize size = view.bounds.size;
    if (window == nil || size.width <= 1.0 || size.height <= 1.0) {
        NSLog(@"DriftDirectClone: deferred prepare size=%@ window=%p",
              NSStringFromSize(size), window);
        return;
    }

    NSScreen *target = DriftTargetScreen(view, window);
    if (target == nil) {
        NSLog(@"DriftDirectClone: deferred prepare because no target screen matched size=%@",
              NSStringFromSize(size));
        return;
    }

    NSScreen *reported = window.screen;
    Class originalWindowClass = object_getClass(window);
    BOOL forceScreen = DriftDisplayID(reported) != DriftDisplayID(target);
    if (forceScreen) {
        Class temporaryClass = DriftTemporaryWindowClass(originalWindowClass);
        if (temporaryClass == Nil) {
            NSLog(@"DriftDirectClone: could not create temporary window class");
            return;
        }
        objc_setAssociatedObject(window,
                                 DriftForcedScreenKey,
                                 target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        object_setClass(window, temporaryClass);
    }

    @try {
        DriftOriginalPrepare(self, selector);
    } @finally {
        if (forceScreen) {
            object_setClass(window, originalWindowClass);
            objc_setAssociatedObject(window,
                                     DriftForcedScreenKey,
                                     nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    }

    NSLog(@"DriftDirectClone: prepared targetDisplay=%u reportedDisplay=%u "
           "size=%@ subviews=%lu orchestrator=%p displayLinker=%p",
          DriftDisplayID(target),
          DriftDisplayID(reported),
          NSStringFromSize(size),
          (unsigned long)view.subviews.count,
          DriftReadObjectIvar(self, "orchestrator"),
          DriftReadObjectIvar(self, "displayLinker"));
}

static void DriftPatchedStart(id self, SEL selector)
{
    if (DriftReadObjectIvar(self, "orchestrator") == nil) {
        DriftPatchedPrepare(self, @selector(prepareToAnimate));
    }
#if DRIFT_PIXEL_DIAGNOSTICS
    NSView *firstSubview = [(NSView *)self subviews].firstObject;
    if ([firstSubview isKindOfClass:MTKView.class]) {
        ((MTKView *)firstSubview).framebufferOnly = NO;
    }
#endif
    DriftOriginalStart(self, selector);
    NSLog(@"DriftDirectClone: started size=%@ subviews=%lu orchestrator=%p displayLinker=%p",
          NSStringFromSize([(NSView *)self bounds].size),
          (unsigned long)[(NSView *)self subviews].count,
          DriftReadObjectIvar(self, "orchestrator"),
          DriftReadObjectIvar(self, "displayLinker"));
}

#if DRIFT_PIXEL_DIAGNOSTICS
static NSUInteger DriftRGBSignal(const uint8_t *pixel, NSUInteger bytesPerPixel)
{
    if (bytesPerPixel == 8) {
        uint16_t red = 0, green = 0, blue = 0;
        memcpy(&red, pixel, sizeof(red));
        memcpy(&green, pixel + 2, sizeof(green));
        memcpy(&blue, pixel + 4, sizeof(blue));
        return (red & 0x7fff) + (green & 0x7fff) + (blue & 0x7fff);
    }
    if (bytesPerPixel == 16) {
        uint32_t red = 0, green = 0, blue = 0;
        memcpy(&red, pixel, sizeof(red));
        memcpy(&green, pixel + 4, sizeof(green));
        memcpy(&blue, pixel + 8, sizeof(blue));
        return (red & 0x7fffffff) + (green & 0x7fffffff) + (blue & 0x7fffffff);
    }
    return (NSUInteger)pixel[0] + pixel[1] + pixel[2];
}

static BOOL DriftLogPixels(id self)
{
    NSView *view = self;
    MTKView *metal = [view.subviews.firstObject isKindOfClass:MTKView.class]
        ? (MTKView *)view.subviews.firstObject : nil;
    id<MTLTexture> texture = metal.currentDrawable.texture;
    if (texture == nil) return NO;

    NSUInteger bytesPerPixel = 4;
    switch (texture.pixelFormat) {
        case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRGBA16Unorm:
        case MTLPixelFormatRGBA16Snorm:
            bytesPerPixel = 8;
            break;
        case MTLPixelFormatRGBA32Float:
            bytesPerPixel = 16;
            break;
        default:
            break;
    }

    const NSUInteger rowsPerStrip = 8;
    NSUInteger bytesPerRow = texture.width * bytesPerPixel;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * rowsPerStrip];
    NSUInteger stepX = MAX((NSUInteger)1, texture.width / 128);
    NSUInteger samples = 0;
    NSUInteger nonBlack = 0;
    unsigned long long signalSum = 0;
    const double positions[] = {0.2, 0.5, 0.8};

    for (NSUInteger strip = 0; strip < 3; strip++) {
        NSUInteger originY = MIN((NSUInteger)(texture.height * positions[strip]),
                                 texture.height - rowsPerStrip);
        [texture getBytes:data.mutableBytes
              bytesPerRow:bytesPerRow
               fromRegion:MTLRegionMake2D(0, originY, texture.width, rowsPerStrip)
              mipmapLevel:0];
        const uint8_t *bytes = data.bytes;
        for (NSUInteger row = 0; row < rowsPerStrip; row++) {
            for (NSUInteger x = 0; x < texture.width; x += stepX) {
                NSUInteger signal = DriftRGBSignal(bytes + row * bytesPerRow +
                                                   x * bytesPerPixel,
                                                   bytesPerPixel);
                signalSum += signal;
                nonBlack += signal > 8;
                samples++;
            }
        }
    }

    NSScreen *target = DriftTargetScreen(view, view.window);
    NSLog(@"DriftDirectClone: PIXELS targetDisplay=%u texture=%lux%lu "
           "format=%lu nonBlackRGB=%lu/%lu meanRGBSignal=%.2f",
          DriftDisplayID(target),
          (unsigned long)texture.width,
          (unsigned long)texture.height,
          (unsigned long)texture.pixelFormat,
          (unsigned long)nonBlack,
          (unsigned long)samples,
          samples ? (double)signalSum / (double)samples : 0.0);
    return YES;
}

static void DriftDiagnosticAnimate(id self, SEL selector)
{
    if (DriftInheritedAnimate != NULL) DriftInheritedAnimate(self, selector);
    if ([objc_getAssociatedObject(self, DriftDiagnosticLoggedKey) boolValue]) return;

    NSUInteger frame =
        [objc_getAssociatedObject(self, DriftDiagnosticFrameKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self,
                             DriftDiagnosticFrameKey,
                             @(frame),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (frame >= 15 && DriftLogPixels(self)) {
        objc_setAssociatedObject(self,
                                 DriftDiagnosticLoggedKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
#endif

@interface DriftCloneLoader : NSObject
@end

@implementation DriftCloneLoader

+ (void)load
{
    NSBundle *hostBundle = [NSBundle bundleForClass:self];
    NSString *rendererPath = [hostBundle pathForResource:@"DriftRenderer"
                                                  ofType:@"bundle"];
    NSBundle *renderer = [NSBundle bundleWithPath:rendererPath];
    NSError *error = nil;
    if (renderer == nil || ![renderer loadAndReturnError:&error]) {
        NSLog(@"DriftDirectClone: could not load complete Apple renderer at %@: %@",
              rendererPath, error);
        return;
    }
    DriftRendererBundle = renderer;

    Class flowClass = NSClassFromString(@"Drift.FlowView");
    Method prepareMethod = class_getInstanceMethod(flowClass, @selector(prepareToAnimate));
    Method startMethod = class_getInstanceMethod(flowClass, @selector(startAnimation));
    if (flowClass == Nil || prepareMethod == NULL || startMethod == NULL) {
        NSLog(@"DriftDirectClone: Apple Drift.FlowView lifecycle methods are missing");
        return;
    }

    DriftOriginalPrepare = (DriftVoidIMP)method_setImplementation(prepareMethod,
                                                                  (IMP)DriftPatchedPrepare);
    DriftOriginalStart = (DriftVoidIMP)method_setImplementation(startMethod,
                                                                (IMP)DriftPatchedStart);
#if DRIFT_PIXEL_DIAGNOSTICS
    Class superClass = class_getSuperclass(flowClass);
    DriftInheritedAnimate = (DriftVoidIMP)class_getMethodImplementation(
        superClass, @selector(animateOneFrame));
    class_addMethod(flowClass,
                    @selector(animateOneFrame),
                    (IMP)DriftDiagnosticAnimate,
                    "v@:");
#endif
    NSLog(@"DriftDirectClone: loaded complete Apple Drift clone and installed screen-context fix");
}

@end

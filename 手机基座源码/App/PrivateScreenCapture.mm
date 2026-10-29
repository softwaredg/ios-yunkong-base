#import "PrivateScreenCapture.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>

// iPhoneOS SDK often lacks public IOSurface/IOSurface.h — declare what we need.
typedef struct __IOSurface *IOSurfaceRef;
typedef void *IOSurfaceAcceleratorRef;

typedef IOSurfaceRef (*IOSurfaceCreateFn)(CFDictionaryRef);
typedef size_t (*IOSurfaceAlignPropertyFn)(CFStringRef, size_t);
typedef CFIndex (*CARenderServerGetDirtyFrameCountFn)(void *);
typedef void (*CARenderServerRenderDisplayFn)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);
typedef kern_return_t (*IOSurfaceAcceleratorCreateFn)(CFAllocatorRef, void *, IOSurfaceAcceleratorRef *);
typedef kern_return_t (*IOSurfaceAcceleratorTransferSurfaceFn)(IOSurfaceAcceleratorRef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *, void *, void *);
typedef CFRunLoopSourceRef (*IOSurfaceAcceleratorGetRunLoopSourceFn)(IOSurfaceAcceleratorRef);
typedef CVReturn (*CVPixelBufferCreateWithIOSurfaceFn)(CFAllocatorRef, IOSurfaceRef, CFDictionaryRef, CVPixelBufferRef _Nullable * _Nonnull);

@implementation PrivateScreenCapture {
    CADisplayLink *_link;
    IOSurfaceRef _dst;
    IOSurfaceRef _src;
    IOSurfaceAcceleratorRef _accel;
    void (^_handler)(CVPixelBufferRef, uint64_t);
    CFIndex _lastDirty;
    NSInteger _ticksSinceEmit;
    NSInteger _fps;
    IOSurfaceCreateFn _surfaceCreate;
    IOSurfaceAlignPropertyFn _alignProp;
    CARenderServerGetDirtyFrameCountFn _dirtyFn;
    CARenderServerRenderDisplayFn _renderFn;
    IOSurfaceAcceleratorCreateFn _accelCreate;
    IOSurfaceAcceleratorTransferSurfaceFn _accelTransfer;
    IOSurfaceAcceleratorGetRunLoopSourceFn _accelSource;
    CVPixelBufferCreateWithIOSurfaceFn _pbFromSurface;
    CFStringRef _kBytesPerElement;
    CFStringRef _kBytesPerRow;
    CFStringRef _kWidth;
    CFStringRef _kHeight;
    CFStringRef _kPixelFormat;
    CFStringRef _kAllocSize;
    BOOL _resolved;
    BOOL _available;
}

+ (instancetype)shared {
    static PrivateScreenCapture *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _fps = 15;
    _lastDirty = -1;
    _ticksSinceEmit = 0;
    [self resolveSymbols];
    return self;
}

- (void)resolveSymbols {
    if (_resolved) return;
    _resolved = YES;
    _surfaceCreate = (IOSurfaceCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    _alignProp = (IOSurfaceAlignPropertyFn)dlsym(RTLD_DEFAULT, "IOSurfaceAlignProperty");
    _dirtyFn = (CARenderServerGetDirtyFrameCountFn)dlsym(RTLD_DEFAULT, "CARenderServerGetDirtyFrameCount");
    _renderFn = (CARenderServerRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    _accelCreate = (IOSurfaceAcceleratorCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorCreate");
    _accelTransfer = (IOSurfaceAcceleratorTransferSurfaceFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorTransferSurface");
    _accelSource = (IOSurfaceAcceleratorGetRunLoopSourceFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorGetRunLoopSource");
    _pbFromSurface = (CVPixelBufferCreateWithIOSurfaceFn)dlsym(RTLD_DEFAULT, "CVPixelBufferCreateWithIOSurface");

    // Resolve IOSurface property keys (they are CFString constants in the framework).
    CFStringRef *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerElement"))) _kBytesPerElement = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerRow"))) _kBytesPerRow = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceWidth"))) _kWidth = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceHeight"))) _kHeight = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfacePixelFormat"))) _kPixelFormat = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceAllocSize"))) _kAllocSize = *p;

    // Fallback string keys if constants unavailable.
    if (!_kBytesPerElement) _kBytesPerElement = CFSTR("BytesPerElement");
    if (!_kBytesPerRow) _kBytesPerRow = CFSTR("BytesPerRow");
    if (!_kWidth) _kWidth = CFSTR("Width");
    if (!_kHeight) _kHeight = CFSTR("Height");
    if (!_kPixelFormat) _kPixelFormat = CFSTR("PixelFormat");
    if (!_kAllocSize) _kAllocSize = CFSTR("AllocSize");

    _available = (_renderFn != NULL && _surfaceCreate != NULL && _pbFromSurface != NULL);
}

- (BOOL)isAvailable {
    [self resolveSymbols];
    return _available;
}

- (NSDictionary *)surfaceProperties {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    int width = (int)round(MAX(px.width, 2));
    int height = (int)round(MAX(px.height, 2));
    int bytesPerElement = 4;
    size_t bytesPerRow = (size_t)bytesPerElement * (size_t)width;
    if (_alignProp) {
        bytesPerRow = _alignProp(_kBytesPerRow, bytesPerRow);
    } else {
        bytesPerRow = (bytesPerRow + 63) & ~((size_t)63);
    }
    return @{
        (__bridge id)_kBytesPerElement : @(bytesPerElement),
        (__bridge id)_kBytesPerRow : @(bytesPerRow),
        (__bridge id)_kWidth : @(width),
        (__bridge id)_kHeight : @(height),
        (__bridge id)_kPixelFormat : @(kCVPixelFormatType_32BGRA),
        (__bridge id)_kAllocSize : @(bytesPerRow * (size_t)height),
    };
}

- (BOOL)ensureSurfaces {
    if (_dst) return YES;
    NSDictionary *props = [self surfaceProperties];
    _dst = _surfaceCreate((__bridge CFDictionaryRef)props);
    _src = _surfaceCreate((__bridge CFDictionaryRef)props);
    if (!_dst) return NO;
    if (_accelCreate && !_accel) {
        _accelCreate(kCFAllocatorDefault, NULL, &_accel);
        if (_accel && _accelSource) {
            CFRunLoopSourceRef src = _accelSource(_accel);
            if (src) CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        }
    }
    return YES;
}

- (void)setPreferredFPS:(NSInteger)fps {
    _fps = MAX(5, MIN(60, fps));
    if (_link) {
        if (@available(iOS 15.0, *)) {
            _link.preferredFrameRateRange = CAFrameRateRangeMake((float)_fps, (float)_fps, (float)_fps);
        } else {
            _link.preferredFramesPerSecond = (int)_fps;
        }
    }
}

- (void)startWithHandler:(void (^)(CVPixelBufferRef, uint64_t))handler {
    [self resolveSymbols];
    if (!_available) return;
    _handler = [handler copy];
    void (^go)(void) = ^{
        if (![self ensureSurfaces]) return;
        if (self->_link) return;
        self->_lastDirty = -1;
        self->_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
        [self setPreferredFPS:self->_fps];
        [self->_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    };
    if (NSThread.isMainThread) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

- (void)stop {
    void (^stop)(void) = ^{
        [self->_link invalidate];
        self->_link = nil;
        self->_handler = nil;
    };
    if (NSThread.isMainThread) stop();
    else dispatch_sync(dispatch_get_main_queue(), stop);
}

- (void)onTick:(CADisplayLink *)link {
    if (!_handler || !_renderFn || !_dst) return;

    // Dirty skip is an optimization only — never stall the stream. Static UI
    // used to stop all frames after the first key, so PC saw "no traffic".
    _ticksSinceEmit += 1;
    BOOL changed = YES;
    if (_dirtyFn) {
        CFIndex dirty = _dirtyFn(NULL);
        changed = (dirty != _lastDirty);
        if (changed) _lastDirty = dirty;
    }
    // At 15fps: force at least ~5fps even when the display claims unchanged.
    if (!changed && _ticksSinceEmit < 3) return;
    _ticksSinceEmit = 0;

    // Prefer direct render into destination — accelerator path can silently
    // leave an empty surface on some devices / entitlement sets.
    _renderFn(0, CFSTR("LCD"), _dst, 0, 0);
    if (_src && _accel && _accelTransfer) {
        // Optional second path: render to src then copy (TrollVNC style).
        _renderFn(0, CFSTR("LCD"), _src, 0, 0);
        _accelTransfer(_accel, _src, _dst, NULL, NULL, NULL, NULL);
    }

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    if (_pbFromSurface(kCFAllocatorDefault, _dst, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return;
    }
    uint64_t ptsUs = (uint64_t)llround(link.timestamp * 1e6);
    if (ptsUs == 0) ptsUs = (uint64_t)llround(CACurrentMediaTime() * 1e6);
    // Caller must retain if it hops off this stack before encode.
    _handler(pb, ptsUs);
    CVPixelBufferRelease(pb);
}

- (void)dealloc {
    [self stop];
    if (_dst) CFRelease(_dst);
    if (_src) CFRelease(_src);
}

@end

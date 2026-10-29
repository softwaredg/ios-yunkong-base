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
// First arg is an OUT kern_return_t* (passing 0/NULL is ok). Wrong calling
// convention previously passed kern_return_t by value and could no-op render.
typedef void (*CARenderServerRenderDisplayFn)(kern_return_t * _Nullable, CFStringRef, IOSurfaceRef, int, int);
typedef kern_return_t (*IOSurfaceAcceleratorCreateFn)(CFAllocatorRef, void *, IOSurfaceAcceleratorRef *);
typedef kern_return_t (*IOSurfaceAcceleratorTransferSurfaceFn)(IOSurfaceAcceleratorRef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *, void *, void *);
typedef CFRunLoopSourceRef (*IOSurfaceAcceleratorGetRunLoopSourceFn)(IOSurfaceAcceleratorRef);
typedef CVReturn (*CVPixelBufferCreateWithIOSurfaceFn)(CFAllocatorRef, IOSurfaceRef, CFDictionaryRef, CVPixelBufferRef _Nullable * _Nonnull);
typedef void *(*IOSurfaceGetBaseAddressFn)(IOSurfaceRef);
typedef size_t (*IOSurfaceGetAllocSizeFn)(IOSurfaceRef);
typedef kern_return_t (*IOSurfaceLockFn)(IOSurfaceRef, uint32_t, uint32_t *);
typedef kern_return_t (*IOSurfaceUnlockFn)(IOSurfaceRef, uint32_t, uint32_t *);

@implementation PrivateScreenCapture {
    CADisplayLink *_link;
    IOSurfaceRef _dst;
    IOSurfaceRef _src;
    IOSurfaceAcceleratorRef _accel;
    void (^_handler)(CVPixelBufferRef, uint64_t);
    void (^_blankHandler)(void);
    CFIndex _lastDirty;
    NSInteger _ticksSinceEmit;
    NSInteger _fps;
    NSInteger _blankStreak;
    BOOL _blankNotified;
    CFStringRef _displayName;
    IOSurfaceCreateFn _surfaceCreate;
    IOSurfaceAlignPropertyFn _alignProp;
    CARenderServerGetDirtyFrameCountFn _dirtyFn;
    CARenderServerRenderDisplayFn _renderFn;
    IOSurfaceAcceleratorCreateFn _accelCreate;
    IOSurfaceAcceleratorTransferSurfaceFn _accelTransfer;
    IOSurfaceAcceleratorGetRunLoopSourceFn _accelSource;
    CVPixelBufferCreateWithIOSurfaceFn _pbFromSurface;
    IOSurfaceGetBaseAddressFn _surfaceBase;
    IOSurfaceGetAllocSizeFn _surfaceAlloc;
    IOSurfaceLockFn _surfaceLock;
    IOSurfaceUnlockFn _surfaceUnlock;
    CFStringRef _kBytesPerElement;
    CFStringRef _kBytesPerRow;
    CFStringRef _kWidth;
    CFStringRef _kHeight;
    CFStringRef _kPixelFormat;
    CFStringRef _kAllocSize;
    BOOL _resolved;
    BOOL _available;
    BOOL _sentinelReady;
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
    _blankStreak = 0;
    _blankNotified = NO;
    _displayName = CFSTR("LCD");
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
    _surfaceBase = (IOSurfaceGetBaseAddressFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    _surfaceAlloc = (IOSurfaceGetAllocSizeFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetAllocSize");
    _surfaceLock = (IOSurfaceLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    _surfaceUnlock = (IOSurfaceUnlockFn)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");

    CFStringRef *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerElement"))) _kBytesPerElement = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerRow"))) _kBytesPerRow = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceWidth"))) _kWidth = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceHeight"))) _kHeight = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfacePixelFormat"))) _kPixelFormat = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceAllocSize"))) _kAllocSize = *p;

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

- (void)setBlankHandler:(void (^)(void))handler {
    _blankHandler = [handler copy];
}

- (void)startWithHandler:(void (^)(CVPixelBufferRef, uint64_t))handler {
    [self resolveSymbols];
    if (!_available) return;
    _handler = [handler copy];
    _blankStreak = 0;
    _blankNotified = NO;
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

/// Magenta sentinel — if still dominant after CARender, the surface was not written.
static const uint32_t kSentinelBGRA = 0xFF00FFFE; // A=FF B=00 G=FF R=FE

- (void)fillSurfaceSentinel:(IOSurfaceRef)surface {
    _sentinelReady = NO;
    if (!surface || !_surfaceBase || !_surfaceAlloc || !_surfaceLock || !_surfaceUnlock) return;
    if (_surfaceLock(surface, 0, NULL) != KERN_SUCCESS) return;
    void *base = _surfaceBase(surface);
    size_t n = _surfaceAlloc(surface);
    if (base && n >= 4) {
        uint32_t *p = (uint32_t *)base;
        size_t count = n / 4;
        for (size_t i = 0; i < count; i++) p[i] = kSentinelBGRA;
        _sentinelReady = YES;
    }
    _surfaceUnlock(surface, 0, NULL);
}

/// True when render replaced the sentinel with real pixels (not leftover garbage / black).
- (BOOL)pixelBufferHasContent:(CVPixelBufferRef)pb {
    // Without a successful sentinel paint we cannot tell garbage from UI — treat as blank.
    if (!_sentinelReady) return NO;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    BOOL ok = NO;
    if (base && h > 0 && w > 0 && stride >= 4) {
        size_t stepY = MAX((size_t)1, h / 32);
        size_t stepX = MAX((size_t)4, (w / 32) * 4);
        uint32_t samples = 0;
        uint32_t sentinel = 0;
        uint32_t black = 0;
        uint32_t other = 0;
        for (size_t y = 0; y < h; y += stepY) {
            uint8_t *row = (uint8_t *)base + y * stride;
            for (size_t x = 0; x + 3 < stride && (x / 4) < w; x += stepX) {
                uint32_t px;
                memcpy(&px, row + x, 4);
                samples++;
                if (px == kSentinelBGRA) sentinel++;
                else if ((px & 0x00FFFFFF) == 0) black++;
                else other++;
            }
        }
        // Real frame: most samples neither sentinel nor pure black.
        ok = samples > 0 && other * 5 > samples; // >20% real-looking pixels
        if (!ok) {
            NSLog(@"[PrivateScreenCapture] empty render samples=%u sent=%u black=%u other=%u",
                  samples, sentinel, black, other);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return ok;
}

- (void)renderInto:(IOSurfaceRef)surface {
    if (!_renderFn || !surface) return;
    kern_return_t kr = KERN_SUCCESS;
    static CFStringRef names[] = {
        NULL, // filled with _displayName
        CFSTR("LCD"),
        CFSTR("Main"),
        CFSTR("Display"),
    };
    names[0] = _displayName;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (!names[i]) continue;
        kr = KERN_SUCCESS;
        _renderFn(&kr, names[i], surface, 0, 0);
        if (kr == KERN_SUCCESS) {
            _displayName = names[i];
            return;
        }
    }
}

- (void)onTick:(CADisplayLink *)link {
    if (!_handler || !_renderFn || !_dst) return;

    (void)_dirtyFn;
    (void)_lastDirty;
    _ticksSinceEmit = 0;

    // Paint sentinel, then render — if CARender no-ops we still see the sentinel.
    [self fillSurfaceSentinel:_dst];
    [self renderInto:_dst];
    if (_src && _accel && _accelTransfer) {
        [self fillSurfaceSentinel:_src];
        [self renderInto:_src];
        _accelTransfer(_accel, _src, _dst, NULL, NULL, NULL, NULL);
    }

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    if (_pbFromSurface(kCFAllocatorDefault, _dst, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return;
    }

    if (![self pixelBufferHasContent:pb]) {
        _blankStreak++;
        CVPixelBufferRelease(pb);
        if (_blankStreak >= 8 && !_blankNotified) {
            _blankNotified = YES;
            NSLog(@"[PrivateScreenCapture] blank frames — notifying fallback");
            if (_blankHandler) _blankHandler();
        }
        return;
    }
    _blankStreak = 0;

    uint64_t ptsUs = (uint64_t)llround(link.timestamp * 1e6);
    if (ptsUs == 0) ptsUs = (uint64_t)llround(CACurrentMediaTime() * 1e6);
    _handler(pb, ptsUs);
    CVPixelBufferRelease(pb);
}

- (void)dealloc {
    [self stop];
    if (_dst) CFRelease(_dst);
    if (_src) CFRelease(_src);
}

@end

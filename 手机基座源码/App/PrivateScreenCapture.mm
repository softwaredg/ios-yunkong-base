#import "PrivateScreenCapture.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import <string.h>

typedef struct __IOSurface *IOSurfaceRef;

typedef IOSurfaceRef (*IOSurfaceCreateFn)(CFDictionaryRef);
typedef CFIndex (*CARenderServerGetDirtyFrameCountFn)(void *);
/// CaptureMyScreen / DirectPhoneBase style: first arg by value.
typedef void (*CARenderServerRenderDisplayByValueFn)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);
/// Alternate ABI seen on some iOS builds: first arg pointer.
typedef void (*CARenderServerRenderDisplayByPtrFn)(kern_return_t *, CFStringRef, IOSurfaceRef, int, int);
typedef CVReturn (*CVPixelBufferCreateWithIOSurfaceFn)(CFAllocatorRef, IOSurfaceRef, CFDictionaryRef, CVPixelBufferRef _Nullable * _Nonnull);
typedef void *(*IOSurfaceGetBaseAddressFn)(IOSurfaceRef);
typedef size_t (*IOSurfaceGetBytesPerRowFn)(IOSurfaceRef);
typedef size_t (*IOSurfaceGetWidthFn)(IOSurfaceRef);
typedef size_t (*IOSurfaceGetHeightFn)(IOSurfaceRef);
typedef kern_return_t (*IOSurfaceLockFn)(IOSurfaceRef, uint32_t, uint32_t *);
typedef kern_return_t (*IOSurfaceUnlockFn)(IOSurfaceRef, uint32_t, uint32_t *);

// Apple fourcc 'BGRA' == 0x42475241 (same constant commercial VT paths feed into pools).
static const OSType kFourCC_BGRA = 0x42475241;
static const OSType kFourCC_ARGB = 0x41524742;

typedef NS_ENUM(NSInteger, PSCRenderMode) {
    PSCRenderModeByValueLCD = 0,
    PSCRenderModeByPtrLCD,
    PSCRenderModeByValueMain,
    PSCRenderModeByPtrMain,
    PSCRenderModeCount
};

@implementation PrivateScreenCapture {
    CADisplayLink *_link;
    IOSurfaceRef _surface;
    OSType _pixelFormat;
    void (^_handler)(CVPixelBufferRef, uint64_t);
    void (^_blankHandler)(void);
    NSInteger _fps;
    NSInteger _blankStreak;
    NSInteger _surfaceResets;
    BOOL _blankNotified;
    CFIndex _lastDirty;
    BOOL _haveDirty;
    PSCRenderMode _mode;
    IOSurfaceCreateFn _surfaceCreate;
    CARenderServerGetDirtyFrameCountFn _dirtyFn;
    CARenderServerRenderDisplayByValueFn _renderByValue;
    CARenderServerRenderDisplayByPtrFn _renderByPtr;
    CVPixelBufferCreateWithIOSurfaceFn _pbFromSurface;
    IOSurfaceGetBaseAddressFn _surfaceBase;
    IOSurfaceGetBytesPerRowFn _surfaceBytesPerRow;
    IOSurfaceGetWidthFn _surfaceWidth;
    IOSurfaceGetHeightFn _surfaceHeight;
    IOSurfaceLockFn _surfaceLock;
    IOSurfaceUnlockFn _surfaceUnlock;
    CFStringRef _kBytesPerElement;
    CFStringRef _kBytesPerRow;
    CFStringRef _kWidth;
    CFStringRef _kHeight;
    CFStringRef _kPixelFormat;
    CFStringRef _kAllocSize;
    CFStringRef _kIsGlobal;
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
    _blankStreak = 0;
    _surfaceResets = 0;
    _blankNotified = NO;
    _lastDirty = -1;
    _haveDirty = NO;
    _mode = PSCRenderModeByValueLCD;
    _pixelFormat = kFourCC_BGRA;
    [self resolveSymbols];
    return self;
}

- (void)resolveSymbols {
    if (_resolved) return;
    _resolved = YES;
    _surfaceCreate = (IOSurfaceCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    _dirtyFn = (CARenderServerGetDirtyFrameCountFn)dlsym(RTLD_DEFAULT, "CARenderServerGetDirtyFrameCount");
    void *render = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    _renderByValue = (CARenderServerRenderDisplayByValueFn)render;
    _renderByPtr = (CARenderServerRenderDisplayByPtrFn)render;
    _pbFromSurface = (CVPixelBufferCreateWithIOSurfaceFn)dlsym(RTLD_DEFAULT, "CVPixelBufferCreateWithIOSurface");
    _surfaceBase = (IOSurfaceGetBaseAddressFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    _surfaceBytesPerRow = (IOSurfaceGetBytesPerRowFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
    _surfaceWidth = (IOSurfaceGetWidthFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetWidth");
    _surfaceHeight = (IOSurfaceGetHeightFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetHeight");
    _surfaceLock = (IOSurfaceLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    _surfaceUnlock = (IOSurfaceUnlockFn)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");

    CFStringRef *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerElement"))) _kBytesPerElement = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceBytesPerRow"))) _kBytesPerRow = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceWidth"))) _kWidth = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceHeight"))) _kHeight = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfacePixelFormat"))) _kPixelFormat = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceAllocSize"))) _kAllocSize = *p;
    if ((p = (CFStringRef *)dlsym(RTLD_DEFAULT, "kIOSurfaceIsGlobal"))) _kIsGlobal = *p;

    if (!_kBytesPerElement) _kBytesPerElement = CFSTR("BytesPerElement");
    if (!_kBytesPerRow) _kBytesPerRow = CFSTR("BytesPerRow");
    if (!_kWidth) _kWidth = CFSTR("Width");
    if (!_kHeight) _kHeight = CFSTR("Height");
    if (!_kPixelFormat) _kPixelFormat = CFSTR("PixelFormat");
    if (!_kAllocSize) _kAllocSize = CFSTR("AllocSize");
    if (!_kIsGlobal) _kIsGlobal = CFSTR("IsGlobal");

    _available = (render != NULL && _surfaceCreate != NULL && _pbFromSurface != NULL);
    NSLog(@"[PrivateScreenCapture] available=%d render=%p format=0x%08x",
          _available, render, (unsigned)_pixelFormat);
}

- (BOOL)isAvailable {
    [self resolveSymbols];
    return _available;
}

- (NSDictionary *)surfacePropertiesWithFormat:(OSType)fmt {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    int width = (int)round(MAX(px.width, 2));
    int height = (int)round(MAX(px.height, 2));
    int bytesPerElement = 4;
    size_t bytesPerRow = (size_t)bytesPerElement * (size_t)width;
    return @{
        (__bridge id)_kIsGlobal : @YES,
        (__bridge id)_kBytesPerElement : @(bytesPerElement),
        (__bridge id)_kBytesPerRow : @(bytesPerRow),
        (__bridge id)_kWidth : @(width),
        (__bridge id)_kHeight : @(height),
        (__bridge id)_kPixelFormat : @(fmt),
        (__bridge id)_kAllocSize : @(bytesPerRow * (size_t)height),
    };
}

- (void)releaseSurface {
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
}

- (BOOL)ensureSurface {
    if (_surface) return YES;
    _surface = _surfaceCreate((__bridge CFDictionaryRef)[self surfacePropertiesWithFormat:_pixelFormat]);
    if (!_surface) {
        NSLog(@"[PrivateScreenCapture] IOSurfaceCreate failed fmt=0x%08x", (unsigned)_pixelFormat);
        return NO;
    }
    _lastDirty = -1;
    _haveDirty = NO;
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
    _surfaceResets = 0;
    _blankNotified = NO;
    _mode = PSCRenderModeByValueLCD;
    _pixelFormat = kFourCC_BGRA;
    void (^go)(void) = ^{
        [self releaseSurface];
        if (![self ensureSurface]) return;
        if (self->_link) return;
        self->_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
        [self setPreferredFPS:self->_fps];
        [self->_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    };
    if (NSThread.isMainThread) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

- (void)restartSurfaces {
    void (^go)(void) = ^{
        self->_surfaceResets += 1;
        // Alternate pixel format every reset (BGRA ↔ ARGB).
        self->_pixelFormat = (self->_pixelFormat == kFourCC_BGRA) ? kFourCC_ARGB : kFourCC_BGRA;
        self->_mode = (PSCRenderMode)(self->_surfaceResets % PSCRenderModeCount);
        [self releaseSurface];
        (void)[self ensureSurface];
        self->_blankStreak = 0;
        NSLog(@"[PrivateScreenCapture] surface reset #%ld fmt=0x%08x mode=%ld",
              (long)self->_surfaceResets, (unsigned)self->_pixelFormat, (long)self->_mode);
    };
    if (NSThread.isMainThread) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

- (void)stop {
    void (^stop)(void) = ^{
        [self->_link invalidate];
        self->_link = nil;
        self->_handler = nil;
        [self releaseSurface];
    };
    if (NSThread.isMainThread) stop();
    else dispatch_sync(dispatch_get_main_queue(), stop);
}

- (void)renderIntoSurface {
    CFStringRef display = (_mode == PSCRenderModeByValueMain || _mode == PSCRenderModeByPtrMain)
        ? CFSTR("Main") : CFSTR("LCD");
    BOOL byPtr = (_mode == PSCRenderModeByPtrLCD || _mode == PSCRenderModeByPtrMain);
    if (_surfaceLock) _surfaceLock(_surface, 0, NULL);
    if (byPtr) {
        kern_return_t err = 0;
        _renderByPtr(&err, display, _surface, 0, 0);
    } else {
        _renderByValue(0, display, _surface, 0, 0);
    }
    if (_surfaceUnlock) _surfaceUnlock(_surface, 0, NULL);
}

- (BOOL)bufferLooksReal:(CVPixelBufferRef)pb {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    BOOL ok = NO;
    if (base && h > 8 && w > 8 && stride >= 4) {
        uint32_t samples = 0, nonzero = 0, distinct = 0;
        uint32_t seen[8] = {0};
        size_t seenN = 0;
        size_t stepY = MAX((size_t)1, h / 40);
        size_t stepX = MAX((size_t)4, (w / 40) * 4);
        for (size_t y = 0; y < h; y += stepY) {
            uint8_t *row = (uint8_t *)base + y * stride;
            for (size_t x = 0; x + 3 < stride && (x / 4) < w; x += stepX) {
                uint32_t px;
                memcpy(&px, row + x, 4);
                samples++;
                if ((px & 0x00FFFFFF) != 0) nonzero++;
                BOOL found = NO;
                for (size_t i = 0; i < seenN; i++) {
                    if (seen[i] == px) { found = YES; break; }
                }
                if (!found && seenN < 8) seen[seenN++] = px;
                distinct = (uint32_t)seenN;
            }
        }
        ok = samples > 0 && nonzero * 10 > samples && distinct >= 3;
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return ok;
}

/// Detached BGRA copy so the shared IOSurface can be rendered again immediately (commercial pool pattern).
- (CVPixelBufferRef)copyDetachedBGRA:(CVPixelBufferRef)src {
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (int)w, (int)h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(dst);
        return NULL;
    }
    uint8_t *sBase = (uint8_t *)CVPixelBufferGetBaseAddress(src);
    uint8_t *dBase = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
    size_t sStride = CVPixelBufferGetBytesPerRow(src);
    size_t dStride = CVPixelBufferGetBytesPerRow(dst);
    size_t rowBytes = MIN(sStride, dStride);
    if (sBase && dBase) {
        for (size_t y = 0; y < h; y++) {
            memcpy(dBase + y * dStride, sBase + y * sStride, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

- (void)onTick:(CADisplayLink *)link {
    if (!_handler || !_renderByValue || !_surface) return;

    // Skip unchanged frames only AFTER we have real pixels — otherwise dirty-stall
    // freezes blank detection / ABI rotation and we fall to snapshot forever.
    if (_dirtyFn && _blankStreak == 0 && _haveDirty) {
        CFIndex dirty = _dirtyFn(NULL);
        if (dirty == _lastDirty) return;
        _lastDirty = dirty;
    } else if (_dirtyFn) {
        _lastDirty = _dirtyFn(NULL);
        _haveDirty = YES;
    }

    [self renderIntoSurface];

    CVPixelBufferRef wrapped = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    if (_pbFromSurface(kCFAllocatorDefault, _surface, (__bridge CFDictionaryRef)attrs, &wrapped) != kCVReturnSuccess || !wrapped) {
        return;
    }

    if (![self bufferLooksReal:wrapped]) {
        _blankStreak++;
        CVPixelBufferRelease(wrapped);
        // Rotate render ABI / display name while still blank.
        if (_blankStreak > 0 && (_blankStreak % 8) == 0) {
            _mode = (PSCRenderMode)((_mode + 1) % PSCRenderModeCount);
        }
        // Recreate IOSurface a few times (format flip) before declaring failure.
        if (_blankStreak == 20 || _blankStreak == 40 || _blankStreak == 60) {
            [self restartSurfaces];
        }
        if (_blankStreak >= 90 && !_blankNotified) {
            _blankNotified = YES;
            NSLog(@"[PrivateScreenCapture] blank after resets — notify fallback");
            if (_blankHandler) _blankHandler();
        }
        return;
    }

    if (_blankStreak > 0) {
        NSLog(@"[PrivateScreenCapture] got real frames mode=%ld fmt=0x%08x",
              (long)_mode, (unsigned)_pixelFormat);
    }
    _blankStreak = 0;

    CVPixelBufferRef detached = [self copyDetachedBGRA:wrapped];
    CVPixelBufferRelease(wrapped);
    if (!detached) return;

    uint64_t ptsUs = (uint64_t)llround(link.timestamp * 1e6);
    if (ptsUs == 0) ptsUs = (uint64_t)llround(CACurrentMediaTime() * 1e6);
    _handler(detached, ptsUs);
    CVPixelBufferRelease(detached);
}

- (void)dealloc {
    [self stop];
}

@end

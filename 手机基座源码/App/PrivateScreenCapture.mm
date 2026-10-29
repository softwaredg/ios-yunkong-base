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

/// Sample BGRA for non-black content. Empty CARender surfaces encode as traffic with no picture.
- (BOOL)pixelBufferHasContent:(CVPixelBufferRef)pb {
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    BOOL ok = NO;
    if (base && h > 0 && w > 0 && stride >= 4) {
        size_t stepY = MAX((size_t)1, h / 24);
        size_t stepX = MAX((size_t)16, (w * 4) / 32);
        uint32_t nonzero = 0;
        uint32_t samples = 0;
        for (size_t y = 0; y < h; y += stepY) {
            uint8_t *row = (uint8_t *)base + y * stride;
            for (size_t x = 0; x + 3 < stride && x / 4 < w; x += stepX) {
                // BGRA — ignore alpha; any RGB channel lit counts.
                if (row[x] | row[x + 1] | row[x + 2]) nonzero++;
                samples++;
            }
        }
        // Real UI has many lit samples; pure black / uncleared surface ≈ 0.
        ok = samples > 0 && nonzero * 50 > samples; // >2% lit
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

    // Direct render into destination. Optionally also try accelerator path.
    [self renderInto:_dst];
    if (_src && _accel && _accelTransfer) {
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

#import "PrivateScreenCapture.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>

typedef void *IOSurfaceAcceleratorRef;
typedef CFIndex (*CARenderServerGetDirtyFrameCountFn)(void *);
typedef void (*CARenderServerRenderDisplayFn)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);
typedef IOReturn (*IOSurfaceAcceleratorCreateFn)(CFAllocatorRef, void *, IOSurfaceAcceleratorRef *);
typedef IOReturn (*IOSurfaceAcceleratorTransferSurfaceFn)(IOSurfaceAcceleratorRef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *, void *, void *);
typedef CFRunLoopSourceRef (*IOSurfaceAcceleratorGetRunLoopSourceFn)(IOSurfaceAcceleratorRef);

@implementation PrivateScreenCapture {
    CADisplayLink *_link;
    IOSurfaceRef _dst;
    IOSurfaceRef _src;
    IOSurfaceAcceleratorRef _accel;
    NSDictionary *_props;
    void (^_handler)(CVPixelBufferRef, uint64_t);
    CFIndex _lastDirty;
    NSInteger _fps;
    CARenderServerGetDirtyFrameCountFn _dirtyFn;
    CARenderServerRenderDisplayFn _renderFn;
    IOSurfaceAcceleratorCreateFn _accelCreate;
    IOSurfaceAcceleratorTransferSurfaceFn _accelTransfer;
    IOSurfaceAcceleratorGetRunLoopSourceFn _accelSource;
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
    _fps = 20;
    _lastDirty = -1;
    [self resolveSymbols];
    return self;
}

- (void)resolveSymbols {
    if (_resolved) return;
    _resolved = YES;
    _dirtyFn = (CARenderServerGetDirtyFrameCountFn)dlsym(RTLD_DEFAULT, "CARenderServerGetDirtyFrameCount");
    _renderFn = (CARenderServerRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    _accelCreate = (IOSurfaceAcceleratorCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorCreate");
    _accelTransfer = (IOSurfaceAcceleratorTransferSurfaceFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorTransferSurface");
    _accelSource = (IOSurfaceAcceleratorGetRunLoopSourceFn)dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorGetRunLoopSource");
    _available = (_renderFn != NULL);
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
    size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)bytesPerElement * (size_t)width);
    return @{
        (id)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (id)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (id)kIOSurfaceWidth : @(width),
        (id)kIOSurfaceHeight : @(height),
        (id)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
        (id)kIOSurfaceAllocSize : @(bytesPerRow * (size_t)height),
    };
}

- (BOOL)ensureSurfaces {
    if (_dst) return YES;
    _props = [self surfaceProperties];
    _dst = IOSurfaceCreate((__bridge CFDictionaryRef)_props);
    _src = IOSurfaceCreate((__bridge CFDictionaryRef)_props);
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

    if (_dirtyFn) {
        CFIndex dirty = _dirtyFn(NULL);
        if (dirty == _lastDirty) return;
        _lastDirty = dirty;
    }

    IOSurfaceRef renderTarget = (_src && _accel && _accelTransfer) ? _src : _dst;
    _renderFn(0, CFSTR("LCD"), renderTarget, 0, 0);
    if (renderTarget == _src && _src && _dst && _accel && _accelTransfer) {
        _accelTransfer(_accel, _src, _dst, NULL, NULL, NULL, NULL);
    }

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, _dst, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return;
    }
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

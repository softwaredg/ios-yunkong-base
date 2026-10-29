#import "BackgroundKeepAlive.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

@implementation BackgroundKeepAlive {
    id _assertion;
    NSString *_detail;
}

+ (instancetype)shared {
    static BackgroundKeepAlive *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[BackgroundKeepAlive alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) _detail = @"idle";
    return self;
}

- (BOOL)isActive { return _assertion != nil; }
- (NSString *)detail { return _detail ?: @"idle"; }

- (void)loadPrivateFrameworks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/BackboardServices.framework/BackboardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    });
}

- (BOOL)tryBKSProcessAssertion {
    Class cls = NSClassFromString(@"BKSProcessAssertion");
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(@"initWithPID:flags:reason:name:withHandler:");
    if (![cls instancesRespondToSelector:sel]) return NO;

    id obj = [cls alloc];
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = obj;

    int pid = getpid();
    // PreventSuspend|PreventThrottleDownCPU|PreventThrottleDownUI|WantsForegroundResourcePriority
    NSUInteger flags = 0x0F;
    NSUInteger reason = 1; // Extension / continuous-ish; 1000 also used by some tipas
    NSString *name = @"tvh4-keepalive";
    void (^handler)(BOOL) = ^(BOOL acquired) {
        NSLog(@"[KeepAlive] BKS acquired=%d", acquired);
    };
    [inv setArgument:&pid atIndex:2];
    [inv setArgument:&flags atIndex:3];
    [inv setArgument:&reason atIndex:4];
    [inv setArgument:&name atIndex:5];
    [inv setArgument:&handler atIndex:6];
    [inv invoke];

    __unsafe_unretained id result = nil;
    [inv getReturnValue:&result];
    if (!result) {
        // Retry with reason 1000 (BKSProcessAssertionReasonFinishTask / continuous variants).
        reason = 1000;
        [inv setArgument:&reason atIndex:4];
        [inv invoke];
        [inv getReturnValue:&result];
    }
    if (!result) return NO;
    _assertion = result;
    _detail = @"BKSProcessAssertion";
    NSLog(@"[KeepAlive] holding %@", _detail);
    return YES;
}

- (BOOL)tryRBSAssertion {
    Class assertionCls = NSClassFromString(@"RBSAssertion");
    Class targetCls = NSClassFromString(@"RBSTarget");
    Class attrCls = NSClassFromString(@"RBSDomainAttribute");
    if (!assertionCls || !targetCls || !attrCls) return NO;

    SEL targetSel = NSSelectorFromString(@"currentProcess");
    id target = nil;
    if ([targetCls respondsToSelector:targetSel]) {
        target = ((id (*)(Class, SEL))objc_msgSend)(targetCls, targetSel);
    }
    if (!target) {
        SEL pidSel = NSSelectorFromString(@"targetWithPid:");
        if ([targetCls respondsToSelector:pidSel]) {
            target = ((id (*)(Class, SEL, pid_t))objc_msgSend)(targetCls, pidSel, getpid());
        }
    }
    if (!target) return NO;

    SEL attrSel = NSSelectorFromString(@"attributeWithDomain:name:sourceEnvironment:");
    if (![attrCls respondsToSelector:attrSel]) return NO;

    // Domain/name pairs seen in FOSS tipa / jailbreak keep-alive paths.
    NSArray<NSArray<NSString *> *> *pairs = @[
        @[ @"com.apple.frontboard.visibility", @"ForegroundApplication" ],
        @[ @"com.apple.frontboard.visibility", @"ForegroundUI" ],
        @[ @"com.apple.boardservices", @"suspend-prevention" ],
        @[ @"com.apple.runningboard", @"continuous" ],
    ];

    SEL initSel = NSSelectorFromString(@"initWithExplanation:target:attributes:");
    if (![assertionCls instancesRespondToSelector:initSel]) return NO;
    SEL acquireSel = NSSelectorFromString(@"acquireWithError:");

    for (NSArray<NSString *> *pair in pairs) {
        id attr = ((id (*)(Class, SEL, id, id, id))objc_msgSend)(
            attrCls, attrSel, pair[0], pair[1], nil);
        if (!attr) continue;
        id assertion = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            [assertionCls alloc], initSel, @"tvh4-keepalive", target, @[ attr ]);
        if (!assertion) continue;
        BOOL ok = YES;
        if ([assertion respondsToSelector:acquireSel]) {
            NSError *err = nil;
            ok = ((BOOL (*)(id, SEL, id *))objc_msgSend)(assertion, acquireSel, &err);
            if (!ok) {
                NSLog(@"[KeepAlive] RBS %@/%@ err=%@", pair[0], pair[1], err);
                continue;
            }
        }
        _assertion = assertion;
        _detail = [NSString stringWithFormat:@"RBS %@/%@", pair[0], pair[1]];
        NSLog(@"[KeepAlive] holding %@", _detail);
        return YES;
    }
    return NO;
}

- (void)start {
    if (_assertion) return;
    [self loadPrivateFrameworks];
    if ([self tryBKSProcessAssertion]) return;
    if ([self tryRBSAssertion]) return;
    _detail = @"none";
    NSLog(@"[KeepAlive] no private assertion available");
}

@end

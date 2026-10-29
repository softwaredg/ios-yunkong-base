#import "HelperLauncher.h"
#import <spawn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <unistd.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>

extern char **environ;

@implementation HelperLauncher

+ (BOOL)isHelperProcess {
    for (NSString *a in NSProcessInfo.processInfo.arguments) {
        if ([a isEqualToString:@"--helper"]) return YES;
    }
    return NO;
}

+ (BOOL)isHelperPortOpen {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(11019);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    BOOL ok = NO;
    if (rc == 0) {
        ok = YES;
    } else if (errno == EINPROGRESS) {
        fd_set w; FD_ZERO(&w); FD_SET(fd, &w);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 200 * 1000 };
        if (select(fd + 1, NULL, &w, NULL, &tv) > 0) {
            int err = 0; socklen_t len = sizeof(err);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
            ok = (err == 0);
        }
    }
    close(fd);
    return ok;
}

/// Kill other IOSYunKongBase processes (stale --helper after tipa reinstall).
+ (void)killOtherBundleProcesses {
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return;
    }
    int n = (int)(len / sizeof(struct kinfo_proc));
    pid_t me = getpid();
    // p_comm is 16 bytes max; PRODUCT_NAME IOSYunKongBase fits.
    for (int i = 0; i < n; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p <= 1 || p == me) continue;
        if (strncmp(procs[i].kp_proc.p_comm, "IOSYunKongBase", sizeof(procs[i].kp_proc.p_comm)) != 0) {
            continue;
        }
        NSLog(@"[HelperLauncher] SIGKILL stale pid=%d", (int)p);
        kill(p, SIGKILL);
    }
    free(procs);
}

+ (NSString *)httpGetInfoVersion {
    // Minimal GET /api/info → appVersion (for mismatch detection).
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(11019);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return nil;
    }
    const char *req = "GET /api/info HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    send(fd, req, strlen(req), 0);
    NSMutableData *data = [NSMutableData data];
    char buf[1024];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
        if (data.length > 65536) break;
    }
    close(fd);
    NSString *all = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRange body = [all rangeOfString:@"\r\n\r\n"];
    if (body.location == NSNotFound) return nil;
    NSString *json = [all substringFromIndex:body.location + 4];
    NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!jd) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id ver = obj[@"appVersion"];
    return [ver isKindOfClass:[NSString class]] ? ver : nil;
}

+ (BOOL)spawnHelperWithPersona:(BOOL)usePersona {
    NSString *exec = NSBundle.mainBundle.executablePath;
    if (exec.length == 0) return NO;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    short flags = POSIX_SPAWN_SETPGROUP;
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setpgroup(&attr, 0);

    if (usePersona) {
        typedef int (*SetPersonaFn)(posix_spawnattr_t *, uid_t, uint32_t);
        typedef int (*SetPersonaUidFn)(posix_spawnattr_t *, uid_t);
        typedef int (*SetPersonaGidFn)(posix_spawnattr_t *, gid_t);
        SetPersonaFn setPersona = (SetPersonaFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        SetPersonaUidFn setUid = (SetPersonaUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        SetPersonaGidFn setGid = (SetPersonaGidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        if (setPersona) {
            (void)setPersona(&attr, 99, 1);
            if (setUid) (void)setUid(&attr, 0);
            if (setGid) (void)setGid(&attr, 0);
        }
    }

    const char *path = exec.fileSystemRepresentation;
    char *argv[] = { (char *)path, "--helper", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        NSLog(@"[HelperLauncher] spawn persona=%d rc=%d errno=%d", usePersona, rc, errno);
        return NO;
    }
    NSLog(@"[HelperLauncher] spawned helper pid=%d persona=%d", (int)pid, usePersona);
    return YES;
}

+ (BOOL)ensureHelperRunning {
    if ([self isHelperProcess]) return YES;

    NSString *mine = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    if ([self isHelperPortOpen]) {
        NSString *running = [self httpGetInfoVersion] ?: @"";
        if (mine.length && running.length && [mine isEqualToString:running]) {
            return YES;
        }
        NSLog(@"[HelperLauncher] version mismatch mine=%@ running=%@ — kill stale", mine, running);
        [self killOtherBundleProcesses];
        // Also try SIGTERM via port-holder: wait for port to drop.
        for (int i = 0; i < 30; i++) {
            usleep(50 * 1000);
            if (![self isHelperPortOpen]) break;
            if (i == 10 || i == 20) [self killOtherBundleProcesses];
        }
    }

    if (![self spawnHelperWithPersona:YES] && ![self spawnHelperWithPersona:NO]) {
        return NO;
    }
    for (int i = 0; i < 50; i++) {
        usleep(50 * 1000);
        if ([self isHelperPortOpen]) {
            NSString *running = [self httpGetInfoVersion] ?: @"";
            if (!mine.length || !running.length || [mine isEqualToString:running]) return YES;
        }
    }
    NSLog(@"[HelperLauncher] :11019 not open / still wrong version after spawn");
    return [self isHelperPortOpen];
}

@end

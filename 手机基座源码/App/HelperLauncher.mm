#import "HelperLauncher.h"
#import <spawn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
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
    if ([self isHelperPortOpen]) return YES;

    if (![self spawnHelperWithPersona:YES] && ![self spawnHelperWithPersona:NO]) {
        return NO;
    }
    for (int i = 0; i < 50; i++) {
        usleep(50 * 1000);
        if ([self isHelperPortOpen]) return YES;
    }
    NSLog(@"[HelperLauncher] :11019 not open after spawn");
    return NO;
}

@end

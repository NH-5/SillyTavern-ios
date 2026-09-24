#import "NodeRuntime.h"
#import <NodeMobile/NodeMobile.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@implementation NodeRuntime {
    BOOL _started;
    NSString *_failureMessage;
}

+ (instancetype)sharedRuntime {
    static NodeRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ runtime = [[NodeRuntime alloc] init]; });
    return runtime;
}

- (BOOL)started {
    @synchronized (self) { return _started; }
}

- (NSString *)failureMessage {
    @synchronized (self) { return _failureMessage; }
}

- (void)setFailure:(NSString *)message {
    @synchronized (self) { _failureMessage = [message copy]; }
}

- (void)start {
    @synchronized (self) {
        if (_started) return;
        _started = YES;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            [self runServer];
        }
    });
}

- (void)runServer {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *serverRoot = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"STServer"];
    NSString *serverFile = [serverRoot stringByAppendingPathComponent:@"server.js"];
    NSString *frontendFile = [serverRoot stringByAppendingPathComponent:@"public/lib.ios.js"];
    if (![files fileExistsAtPath:serverFile] || ![files fileExistsAtPath:frontendFile]) {
        [self setFailure:@"应用缺少服务端资源。请先运行 ios/prepare-bundle.sh 并重新构建。"];
        return;
    }

    NSURL *supportURL = [files URLForDirectory:NSApplicationSupportDirectory
                                      inDomain:NSUserDomainMask
                             appropriateForURL:nil
                                        create:YES
                                         error:nil];
    if (!supportURL) {
        [self setFailure:@"无法访问应用数据目录。"];
        return;
    }
    NSString *support = [[supportURL URLByAppendingPathComponent:@"SillyTavern" isDirectory:YES] path];
    NSString *data = [support stringByAppendingPathComponent:@"data"];
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/SillyTavernNode"];
    NSError *error = nil;
    for (NSString *directory in @[support, data, cache]) {
        if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self setFailure:[NSString stringWithFormat:@"无法创建数据目录：%@", error.localizedDescription]];
            return;
        }
    }

    NSString *config = [support stringByAppendingPathComponent:@"config.yaml"];
    setenv("SILLYTAVERN_IOS", "1", 1);
    setenv("NODE_COMPILE_CACHE", cache.UTF8String, 1);
    setenv("NODE_COMPILE_CACHE_PORTABLE", "1", 1);
    setenv("NODE_OPTIONS", "--max-old-space-size-percentage=35", 1);
    if (chdir(serverRoot.UTF8String) != 0) {
        [self setFailure:@"无法打开服务端资源目录。"];
        return;
    }

    NSArray<NSString *> *arguments = @[
        @"node", serverFile,
        @"--configPath", config,
        @"--dataRoot", data,
        @"--port", @"8000",
        @"--listen", @"false",
        @"--enableIPv6", @"false",
        @"--browserLaunchEnabled", @"false",
    ];

    // libuv expects argv strings to occupy contiguous writable memory.
    NSUInteger byteCount = 0;
    for (NSString *argument in arguments) byteCount += strlen(argument.UTF8String) + 1;
    char *buffer = (char *)calloc(byteCount, 1);
    char **argv = (char **)calloc(arguments.count + 1, sizeof(char *));
    if (!buffer || !argv) {
        free(buffer);
        free(argv);
        [self setFailure:@"内存不足，无法启动服务。"];
        return;
    }
    char *cursor = buffer;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        const char *value = arguments[index].UTF8String;
        size_t length = strlen(value) + 1;
        memcpy(cursor, value, length);
        argv[index] = cursor;
        cursor += length;
    }

    int exitCode = node_start((int)arguments.count, argv);
    free(argv);
    free(buffer);
    [self setFailure:[NSString stringWithFormat:@"本机服务已停止（代码 %d）。请查看 Xcode 控制台日志。", exitCode]];
}

@end

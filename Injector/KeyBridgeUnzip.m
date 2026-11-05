// 在守护进程内解压 ZIP（外部 unzip 看到的 / 是 jbroot，路径对不上），只挑 *.dict.yaml。

#import <Foundation/Foundation.h>
#include "unzip.h"
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL KBIsSafeName(const char *name) {
    if (!name || !*name) return NO;
    if (*name == '/') return NO;
    if (strstr(name, "..")) return NO;
    for (const char *p = name; *p; p++) {
        if ((unsigned char)*p < 0x20) return NO;
    }
    return YES;
}

static BOOL KBMakeParents(NSString *path) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL];
}

NSUInteger KBExtractDictionaryZip(NSString *zipPath, NSString *destination, void (^log)(NSString *)) {
    unzFile zip = unzOpen(zipPath.UTF8String);
    if (!zip) {
        log(@"cannot open zip");
        return 0;
    }
    NSUInteger written = 0;
    int status = unzGoToFirstFile(zip);
    while (status == UNZ_OK) {
        char name[1024] = {0};
        unz_file_info info;
        if (unzGetCurrentFileInfo(zip, &info, name, sizeof(name), NULL, 0, NULL, 0) == UNZ_OK) {
            size_t length = strlen(name);
            if (length > 10 && strcmp(name + length - 10, ".dict.yaml") == 0 && KBIsSafeName(name)) {
                if (unzOpenCurrentFile(zip) == UNZ_OK) {
                    NSString *target = [destination stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
                    if (KBMakeParents(target)) {
                        int fd = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                        if (fd >= 0) {
                            char buffer[65536];
                            int read = 0;
                            BOOL ok = YES;
                            while ((read = unzReadCurrentFile(zip, buffer, sizeof(buffer))) > 0) {
                                ssize_t offset = 0;
                                while (offset < read) {
                                    ssize_t wrote = write(fd, buffer + offset, (size_t)(read - offset));
                                    if (wrote <= 0) { ok = NO; break; }
                                    offset += wrote;
                                }
                                if (!ok) break;
                            }
                            close(fd);
                            if (ok && read == 0) written++;
                            else log([NSString stringWithFormat:@"write failed: %s", name]);
                        }
                    }
                    unzCloseCurrentFile(zip);
                }
            }
        }
        status = unzGoToNextFile(zip);
    }
    unzClose(zip);
    log([NSString stringWithFormat:@"extracted %lu dict files", (unsigned long)written]);
    return written;
}

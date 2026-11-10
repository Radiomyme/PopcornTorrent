//
//  PTGatedFileResponse.mm
//  PopcornTorrent
//

#import "PTGatedFileResponse.h"
#import "PTStreamController.h"
#import <GCDWebServerErrorResponse.h>
#import <GCDWebServerFunctions.h>

static NSString * const PTGatedFileResponseErrorDomain = @"com.popcorntimetv.popcorntorrent.http";
static int64_t const PTGatedFileResponseChunk = 512 * 1024;

@implementation PTGatedFileResponse {
    std::shared_ptr<ptbounded::StreamController> _controller;
    int64_t _offset;
    int64_t _end;
    int64_t _reader;
}

+ (GCDWebServerResponse *)responseForRequest:(GCDWebServerRequest *)request
                                  controller:(std::shared_ptr<ptbounded::StreamController>)controller
                                    fileName:(NSString *)fileName {
    int64_t const fileSize = controller ? controller->fileSize() : 0;
    if (fileSize <= 0) {
        return [GCDWebServerErrorResponse responseWithStatusCode:503];
    }

    int64_t start = 0;
    int64_t end = fileSize;
    BOOL const ranged = request.hasByteRange;
    if (ranged) {
        NSRange const range = request.byteRange;
        if (range.location != NSUIntegerMax) {
            start = (int64_t)range.location;
            end = range.length == NSUIntegerMax ? fileSize : MIN(fileSize, start + (int64_t)range.length);
        } else {
            start = MAX(0, fileSize - (int64_t)range.length);
        }
    }
    if (start >= fileSize || end <= start) {
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:416];
        [response setValue:[NSString stringWithFormat:@"bytes */%lld", fileSize] forAdditionalHeader:@"Content-Range"];
        return response;
    }
    if (controller->isOffsetFreed(start)) {
        // Deleted in bounded mode: fail now instead of making the player wait.
        return [GCDWebServerErrorResponse responseWithStatusCode:410];
    }

    PTGatedFileResponse *response = [[PTGatedFileResponse alloc] init];
    response->_controller = controller;
    response->_offset = start;
    response->_end = end;
    response.contentType = GCDWebServerGetMimeTypeForExtension(fileName.pathExtension, nil);
    response.contentLength = (NSUInteger)(end - start);
    if (ranged) {
        response.statusCode = 206;
        [response setValue:[NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end - 1, fileSize] forAdditionalHeader:@"Content-Range"];
    }
    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
    return response;
}

- (BOOL)open:(NSError **)error {
    _reader = _controller->openReader(_offset);
    return YES;
}

- (void)asyncReadDataWithCompletion:(GCDWebServerBodyReaderCompletionBlock)block {
    if (_offset >= _end) {
        block([NSData data], nil);
        return;
    }
    int64_t const length = MIN(_end - _offset, PTGatedFileResponseChunk);
    PTGatedFileResponse *strongSelf = self;
    GCDWebServerBodyReaderCompletionBlock completion = [block copy];
    _controller->readAsync(_reader, _offset, length, [strongSelf, completion](NSData *data, int result) {
        if (result != ptbounded::ReadOK || data == nil) {
            NSError *error = [NSError errorWithDomain:PTGatedFileResponseErrorDomain code:result userInfo:nil];
            completion(nil, error);
            return;
        }
        strongSelf->_offset += (int64_t)data.length;
        completion(data, nil);
    });
}

- (void)close {
    if (_reader > 0) _controller->closeReader(_reader);
    _reader = 0;
}

- (void)dealloc {
    if (_reader > 0 && _controller) _controller->closeReader(_reader);
}

@end

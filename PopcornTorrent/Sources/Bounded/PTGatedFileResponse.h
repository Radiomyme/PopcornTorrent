//
//  PTGatedFileResponse.h
//  PopcornTorrent
//
//  HTTP response that serves the selected file only from pieces that are on
//  disk: it waits for missing pieces (moving the download window to them) and
//  fails fast on pieces deleted in bounded mode, so zeros are never served.
//  Several responses can run at the same time.
//

#import <GCDWebServer.h>
#import <GCDWebServerResponse.h>
#import <GCDWebServerRequest.h>

#include <memory>

namespace ptbounded {
class StreamController;
}

NS_ASSUME_NONNULL_BEGIN

@interface PTGatedFileResponse : GCDWebServerResponse

/// A 200/206 gated response for the request's range, or an error response:
/// 416 for a range outside the file, 410 when the range starts in deleted data,
/// 503 before the file is known.
+ (GCDWebServerResponse *)responseForRequest:(GCDWebServerRequest *)request
                                  controller:(std::shared_ptr<ptbounded::StreamController>)controller
                                    fileName:(NSString *)fileName;

@end

NS_ASSUME_NONNULL_END

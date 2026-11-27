//
//  HttpManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"
#import "HttpRequest.h"
#import "StreamConfiguration.h"

@interface HttpManager : NSObject <NSURLSessionDelegate>

- (id) initWithHost:(NSString*) host uniqueId:(NSString*) uniqueId serverCert:(NSData*) serverCert;
- (void) setServerCert:(NSData*) serverCert;
- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert;
// Apollo one-time-PIN pairing: pin + passphrase come from Apollo's web UI
- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert otpPin:(NSString*)otpPin passphrase:(NSString*)passphrase;
- (NSURLRequest*) newUnpairRequest;
- (NSURLRequest*) newChallengeRequest:(NSData*)challenge;
- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp;
- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret;
- (NSURLRequest*) newPairChallenge;
- (NSURLRequest*) newAppListRequest;
- (NSURLRequest*) newServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest;
- (NSURLRequest*) newLaunchRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newResumeRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newQuitAppRequest;
- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString*)appId;
- (void) executeRequestSynchronously:(HttpRequest*)request;

// Apollo clipboard sync (plain text only)
- (NSURLRequest*) newGetClipboardRequest;
- (NSURLRequest*) newSendClipboardRequest:(NSString*)text;

// Runs a request whose response isn't XML. Returns the body, or nil on a
// transport error; *statusCode receives the HTTP status.
- (NSData*) executeRawRequestSynchronously:(NSURLRequest*)request statusCode:(NSInteger*)statusCode;

@end



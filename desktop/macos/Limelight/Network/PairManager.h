//
//  PairManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpManager.h"

@protocol PairCallback <NSObject>

- (void) startPairing:(NSString*)PIN;
- (void) pairSuccessful:(NSData*)serverCert;
- (void) pairFailed:(NSString*)message;
- (void) alreadyPaired;

@end

@interface PairManager : NSOperation
- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert callback:(id<PairCallback>)callback;
// Apollo OTP pairing: uses the PIN + passphrase generated in Apollo's web UI instead of showing a PIN
- (id) initWithManager:(HttpManager*)httpManager clientCert:(NSData*)clientCert otpPin:(NSString*)otpPin passphrase:(NSString*)passphrase callback:(id<PairCallback>)callback;
@end

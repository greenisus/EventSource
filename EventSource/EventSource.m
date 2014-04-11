//
//  EventSource.m
//  EventSource
//
//  Created by Neil on 25/07/2013.
//  Copyright (c) 2013 Neil Cowburn. All rights reserved.
//

#import "EventSource.h"

#define ES_RECONNECT_TIMEOUT 1.0

@interface EventSource () <NSURLConnectionDelegate, NSURLConnectionDataDelegate> {
    NSURL *eventURL;
    NSURLConnection *eventSource;
    NSMutableDictionary *listeners;
    BOOL wasClosed;
}

- (void)open;

@end

@implementation EventSource

+ (id)eventSourceWithURL:(NSURL *)URL
{
    return [[EventSource alloc] initWithURL:URL];
}

- (id)initWithURL:(NSURL *)URL
{
    if (self = [super init]) {
        listeners = [NSMutableDictionary dictionary];
        eventURL = URL;
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ES_RECONNECT_TIMEOUT * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self open];
        });
    }
    return self;
}

- (void)addEventListener:(NSString *)eventName handler:(EventSourceEventHandler)handler
{
    if (listeners[eventName] == nil) {
        [listeners setObject:[NSMutableArray array] forKey:eventName];
    }
    
    [listeners[eventName] addObject:handler];
}

- (void)onMessage:(EventSourceEventHandler)handler
{
    [self addEventListener:MessageEvent handler:handler];
}

- (void)onError:(EventSourceEventHandler)handler
{
    [self addEventListener:ErrorEvent handler:handler];
}

- (void)onOpen:(EventSourceEventHandler)handler
{
    [self addEventListener:OpenEvent handler:handler];
}

- (void)open
{
    wasClosed = NO;
    NSURLRequest *request = [NSURLRequest requestWithURL:eventURL];
    eventSource = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];
}

- (void)close
{
    wasClosed = YES;
    [eventSource cancel];
}

// ---------------------------------------------------------------------------------------------------------------------

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        // Opened
        Event *e = [Event new];
        e.readyState = kEventStateOpen;
        
        NSArray *openHandlers = listeners[OpenEvent];
        for (EventSourceEventHandler handler in openHandlers) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(e);
            });
        }
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = error;
    
    NSArray *errorHandlers = listeners[ErrorEvent];
    for (EventSourceEventHandler handler in errorHandlers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(e);
        });
    }
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ES_RECONNECT_TIMEOUT * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self open];
    });
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    __block NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if ([eventString hasSuffix:@"\n\n"]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            
            eventString = [eventString stringByReplacingOccurrencesOfString:@"\n\n" withString:@"\n"];
            
            NSMutableArray *components = [[eventString componentsSeparatedByString:@"\n"] mutableCopy];
            
            Event *e = [Event new];
            e.readyState = kEventStateOpen;
            
            BOOL dataIsSet = NO;
            
            for (NSString *component in components) {
                
                if ([component length] == 0) {
                    continue;
                }
                
                NSInteger index = [component rangeOfString:@": "].location;
                NSString *key = [component substringToIndex:index];
                NSString *value = [component substringFromIndex:index + 2];
                
                if ([key isEqualToString:@"id"]) {
                    e.id = value;
                } else if ([key isEqualToString:@"event"]) {
                    e.event = value;
                } else if ([key isEqualToString:@"data"]) {
                    e.data = value;
                    dataIsSet = YES;
                }
                
                // if everything is set, we're done building the event
                if (![e.id isEqualToString:@""] && ![e.event isEqualToString:@""] && dataIsSet) {
                    
                    if (![e.data isEqualToString:@""]) {
                        
                        NSArray *messageHandlers = listeners[MessageEvent];
                        for (EventSourceEventHandler handler in messageHandlers) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                handler(e);
                            });
                        }
                        
                        if (e.event != nil) {
                            NSArray *namedEventhandlers = listeners[e.event];
                            for (EventSourceEventHandler handler in namedEventhandlers) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    handler(e);
                                });
                            }
                        }
                        
                    }
                    
                    e = [Event new];
                    e.readyState = kEventStateOpen;
                    dataIsSet = NO;
                    
                }
                
                
            }
            
        });
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    if (wasClosed) {
        return;
    }
    
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = [NSError errorWithDomain:@""
                                  code:e.readyState
                              userInfo:@{ NSLocalizedDescriptionKey: @"Connection with the event source was closed." }];
    
    NSArray *errorHandlers = listeners[ErrorEvent];
    for (EventSourceEventHandler handler in errorHandlers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(e);
        });
    }
    
    [self open];
}

@end

// ---------------------------------------------------------------------------------------------------------------------

@implementation Event

- (NSString *)description
{
    NSString *state = nil;
    switch (self.readyState) {
        case kEventStateConnecting:
            state = @"CONNECTING";
            break;
        case kEventStateOpen:
            state = @"OPEN";
            break;
        case kEventStateClosed:
            state = @"CLOSED";
            break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>",
            [self class],
            state,
            self.id,
            self.event,
            self.data];
}

@end

NSString *const MessageEvent = @"message";
NSString *const ErrorEvent = @"error";
NSString *const OpenEvent = @"open";

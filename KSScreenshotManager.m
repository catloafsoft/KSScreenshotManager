/*
 * KSScreenshotManager.m
 *
 * Copyright (c) 2013 Kent Sutherland
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 * Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#if CREATING_SCREENSHOTS

#import "KSScreenshotManager.h"
#import "KSScreenshotAction.h"

@interface KSScreenshotManager ()
@property(nonatomic, strong) NSMutableArray *screenshotActions;
@end

@implementation KSScreenshotManager

- (instancetype)init
{
    if ( (self = [super init]) ) {
        NSArray *arguments = [[NSProcessInfo processInfo] arguments];
        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        
        // Prefer taking the last launch argument. This allows us to specify an output path when running with WaxSim.
        if (env[@"SCREENSHOTS_PATH"]) {
            NSString *savePath = [env[@"SCREENSHOTS_PATH"] stringByExpandingTildeInPath];
            [self setScreenshotsURL:[NSURL fileURLWithPath:savePath]];
        } else if ([arguments count] > 1) {
            NSString *savePath = [[arguments lastObject] stringByExpandingTildeInPath];
            [self setScreenshotsURL:[NSURL fileURLWithPath:savePath]];
        } else {
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
            [self setScreenshotsURL:[NSURL fileURLWithPath:documentsPath]];
        }
        
        // Create status file in the path
        NSURL *fileURL = [[self screenshotsURL] URLByAppendingPathComponent:@".screenshots.tmp"];
        NSError *error;
        if ([arguments.description writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&error] == NO) {
            NSLog(@"Failed to create %@ status file.", fileURL);
        }
        
        _exitOnComplete = YES;
        _loggingEnabled = YES;
    }
    return self;
}

- (void)takeScreenshots
{
    [self setupScreenshotActions];
    
    if ([self.screenshotActions count] == 0) {
        [NSException raise:NSInternalInconsistencyException format:@"No screenshot actions have been defined. Unable to take screenshots."];
    }
    
    [self takeNextScreenshot];
}

- (void)takeNextScreenshot
{
    if ([[self screenshotActions] count] > 0) {
        KSScreenshotAction *nextAction = self.screenshotActions[0];
        
        if (_loggingEnabled) {
            NSLog(@"Taking screenshot: %@", nextAction.name);
        }
        
        if (nextAction.actionBlock) {
            nextAction.actionBlock();
        }
        
        if (!nextAction.asynchronous) {
            //synchronous actions can run immediately
            //asynchronous actions need to call actionIsReady manually
            [self actionIsReady];
        }
    } else {
        NSURL *fileURL = [[self screenshotsURL] URLByAppendingPathComponent:@".screenshots.tmp"];
        NSError *error;
        if ([[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error] == NO) {
            NSLog(@"Failed to remove status file at %@", fileURL);
        }
        
        if ([self doesExitOnComplete])
            exit(0);
    }
}

- (void)actionIsReady
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false); //spin the run loop to give the UI a chance to catch up
    
    KSScreenshotAction *nextAction = self.screenshotActions[0];
    
    [self saveScreenshot:nextAction.name includeStatusBar:nextAction.includeStatusBar];
    
    if (nextAction.cleanupBlock) {
        nextAction.cleanupBlock();
    }
    
    [self.screenshotActions removeObjectAtIndex:0];
    
    [self takeNextScreenshot];
}

- (void)setupScreenshotActions
{
    [NSException raise:NSInternalInconsistencyException format:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)];
}

- (void)addScreenshotAction:(KSScreenshotAction *)screenshotAction
{
    if (!_screenshotActions) {
        [self setScreenshotActions:[NSMutableArray array]];
    }
    
    [screenshotAction setManager:self];
    
    [[self screenshotActions] addObject:screenshotAction];
}

- (void)saveScreenshot:(NSString *)name includeStatusBar:(BOOL)includeStatusBar
{
    //Get image with status bar cropped out
    BOOL isRetina = [[UIScreen mainScreen] scale] != 1.0f;
    CGFloat StatusBarHeight = [[UIScreen mainScreen] scale] * 20;
    
    UIGraphicsBeginImageContextWithOptions([[UIScreen mainScreen] bounds].size, YES, 0);
    [[[UIScreen mainScreen] snapshotViewAfterScreenUpdates:YES] drawViewHierarchyInRect:[[UIScreen mainScreen] bounds] afterScreenUpdates:YES];
    
    CGImageRef CGImage = [UIGraphicsGetImageFromCurrentImageContext() CGImage];
    
    UIGraphicsEndImageContext();
    
    // remove alpha since the new itunes connect doesn't like it
    // http://stackoverflow.com/questions/21416358/remove-alpha-channel-from-uiimage
    // http://stackoverflow.com/questions/9920836/color-distortion-in-cgimagecreate
    CFDataRef theData = CGDataProviderCopyData(CGImageGetDataProvider(CGImage));
    UInt8 *pixelData = (UInt8 *)CFDataGetBytePtr(theData);
    CGContextRef bitmapContext = CGBitmapContextCreate(pixelData,
                                                       CGImageGetWidth(CGImage),
                                                       CGImageGetHeight(CGImage),
                                                       CGImageGetBitsPerComponent(CGImage),
                                                       CGImageGetBytesPerRow(CGImage),
                                                       CGImageGetColorSpace(CGImage),
                                                       kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
                                                       );
    CGImage = CGBitmapContextCreateImage(bitmapContext);
    CGContextRelease(bitmapContext);
    CFRelease(theData);

    if (!includeStatusBar) {
        CGRect imageRect = CGRectMake(0, StatusBarHeight, CGImageGetWidth(CGImage), CGImageGetHeight(CGImage) - StatusBarHeight);
        
        CGImage = (__bridge CGImageRef)CFBridgingRelease(CGImageCreateWithImageInRect(CGImage, imageRect));
    }
    
    UIImage *image = [UIImage imageWithCGImage:CGImage];
    NSString *devicePrefix;
    NSString *screenDensity = isRetina ? [NSString stringWithFormat:@"@%.0fx", [[UIScreen mainScreen] scale]] : @"";
    CGFloat screenHeight;

    if ([[UIScreen mainScreen] respondsToSelector:@selector(coordinateSpace)]) {
        // Always refer to screens by the vertical height, even if the screenshot is landscape
        screenHeight = CGRectGetHeight([[[UIScreen mainScreen] coordinateSpace] convertRect:[[UIScreen mainScreen] bounds] toCoordinateSpace:[[UIScreen mainScreen] fixedCoordinateSpace]]);
    } else {
        screenHeight = CGRectGetHeight([[UIScreen mainScreen] bounds]);
    }

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        devicePrefix = [NSString stringWithFormat:@"iphone%.0f%@", screenHeight, screenDensity];
    } else {
        devicePrefix = [NSString stringWithFormat:@"ipad%.0f%@", screenHeight, screenDensity];
    }
    
    NSData *data = UIImagePNGRepresentation(image);
    NSString *file = [NSString stringWithFormat:@"%@-%@-%@.png", devicePrefix, [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode], name];
    NSURL *fileURL = [[self screenshotsURL] URLByAppendingPathComponent:file];
    NSError *error;
    
    // Create the screenshot directory if it doesn't exist already
    if (![[NSFileManager defaultManager] createDirectoryAtURL:[self screenshotsURL] withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (_loggingEnabled) {
            NSLog(@"Failed to create screenshots directory: %@", error);
        }
    }
    
    if (_loggingEnabled) {
        NSLog(@"Saving screenshot: %@", [fileURL path]);
    }
    
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
        if (_loggingEnabled) {
            NSLog(@"Failed to write screenshot at %@: %@", fileURL, error);
        }
    }
}

@end

#endif

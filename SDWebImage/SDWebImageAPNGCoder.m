/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageAPNGCoder.h"
#import <ImageIO/ImageIO.h>
#import "NSData+ImageContentType.h"
#import "UIImage+WebCache.h"
#import "NSImage+Compatibility.h"
#import "SDWebImageCoderHelper.h"
#import "SDAnimatedImageRep.h"

// iOS 8 Image/IO framework binary does not contains these APNG contants, so we define them. Thanks Apple :)
#if (__IPHONE_OS_VERSION_MIN_REQUIRED && __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_9_0)
const CFStringRef kCGImagePropertyAPNGLoopCount = (__bridge CFStringRef)@"LoopCount";
const CFStringRef kCGImagePropertyAPNGDelayTime = (__bridge CFStringRef)@"DelayTime";
const CFStringRef kCGImagePropertyAPNGUnclampedDelayTime = (__bridge CFStringRef)@"UnclampedDelayTime";
#endif

@interface SDAPNGCoderFrame : NSObject

@property (nonatomic, assign) NSUInteger index; // Frame index (zero based)
@property (nonatomic, assign) NSTimeInterval duration; // Frame duration in seconds

@end

@implementation SDAPNGCoderFrame
@end

@implementation SDWebImageAPNGCoder {
    size_t _width, _height;
#if SD_UIKIT || SD_WATCH
    UIImageOrientation _orientation;
#endif
    CGImageSourceRef _imageSource;
    NSData *_imageData;
    CGFloat _scale;
    NSUInteger _loopCount;
    NSUInteger _frameCount;
    NSArray<SDAPNGCoderFrame *> *_frames;
    BOOL _finished;
}

- (void)dealloc
{
    if (_imageSource) {
        CFRelease(_imageSource);
        _imageSource = NULL;
    }
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification
{
    if (_imageSource) {
        for (size_t i = 0; i < _frameCount; i++) {
            CGImageSourceRemoveCacheAtIndex(_imageSource, i);
        }
    }
}

+ (instancetype)sharedCoder {
    static SDWebImageAPNGCoder *coder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coder = [[SDWebImageAPNGCoder alloc] init];
    });
    return coder;
}

#pragma mark - Decode
- (BOOL)canDecodeFromData:(nullable NSData *)data {
    return ([NSData sd_imageFormatForImageData:data] == SDImageFormatPNG);
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(nullable SDWebImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    CGFloat scale = 1;
    if ([options valueForKey:SDWebImageCoderDecodeScaleFactor]) {
        scale = [[options valueForKey:SDWebImageCoderDecodeScaleFactor] doubleValue];
        if (scale < 1) {
            scale = 1;
        }
    }
    
#if SD_MAC
    SDAnimatedImageRep *imageRep = [[SDAnimatedImageRep alloc] initWithData:data];
    NSSize size = NSMakeSize(imageRep.pixelsWide / scale, imageRep.pixelsHigh / scale);
    imageRep.size = size;
    NSImage *animatedImage = [[NSImage alloc] initWithSize:size];
    [animatedImage addRepresentation:imageRep];
    return animatedImage;
#else
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return nil;
    }
    size_t count = CGImageSourceGetCount(source);
    UIImage *animatedImage;
    
    BOOL decodeFirstFrame = [options[SDWebImageCoderDecodeFirstFrameOnly] boolValue];
    if (decodeFirstFrame || count <= 1) {
        animatedImage = [[UIImage alloc] initWithData:data scale:scale];
    } else {
        NSMutableArray<SDWebImageFrame *> *frames = [NSMutableArray array];
        
        for (size_t i = 0; i < count; i++) {
            CGImageRef imageRef = CGImageSourceCreateImageAtIndex(source, i, NULL);
            if (!imageRef) {
                continue;
            }
            
            float duration = [self sd_frameDurationAtIndex:i source:source];
            UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(imageRef);
            
            SDWebImageFrame *frame = [SDWebImageFrame frameWithImage:image duration:duration];
            [frames addObject:frame];
        }
        
        NSUInteger loopCount = [self sd_imageLoopCountWithSource:source];
        
        animatedImage = [SDWebImageCoderHelper animatedImageWithFrames:frames];
        animatedImage.sd_imageLoopCount = loopCount;
    }
    
    CFRelease(source);
    
    return animatedImage;
#endif
}

- (NSUInteger)sd_imageLoopCountWithSource:(CGImageSourceRef)source {
    NSUInteger loopCount = 0;
    NSDictionary *imageProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyProperties(source, nil);
    NSDictionary *pngProperties = [imageProperties valueForKey:(__bridge_transfer NSString *)kCGImagePropertyPNGDictionary];
    if (pngProperties) {
        NSNumber *apngLoopCount = [pngProperties valueForKey:(__bridge_transfer NSString *)kCGImagePropertyAPNGLoopCount];
        if (apngLoopCount != nil) {
            loopCount = apngLoopCount.unsignedIntegerValue;
        }
    }
    return loopCount;
}

- (float)sd_frameDurationAtIndex:(NSUInteger)index source:(CGImageSourceRef)source {
    float frameDuration = 0.1f;
    CFDictionaryRef cfFrameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil);
    NSDictionary *frameProperties = (__bridge NSDictionary *)cfFrameProperties;
    NSDictionary *pngProperties = frameProperties[(NSString *)kCGImagePropertyPNGDictionary];
    
    NSNumber *delayTimeUnclampedProp = pngProperties[(__bridge_transfer NSString *)kCGImagePropertyAPNGUnclampedDelayTime];
    if (delayTimeUnclampedProp != nil) {
        frameDuration = [delayTimeUnclampedProp floatValue];
    } else {
        NSNumber *delayTimeProp = pngProperties[(__bridge_transfer NSString *)kCGImagePropertyAPNGDelayTime];
        if (delayTimeProp != nil) {
            frameDuration = [delayTimeProp floatValue];
        }
    }
    
    if (frameDuration < 0.011f) {
        frameDuration = 0.100f;
    }
    
    CFRelease(cfFrameProperties);
    return frameDuration;
}

#pragma mark - Encode
- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    return (format == SDImageFormatPNG);
}

- (NSData *)encodedDataWithImage:(UIImage *)image format:(SDImageFormat)format options:(nullable SDWebImageCoderOptions *)options {
    if (!image) {
        return nil;
    }
    
    if (format != SDImageFormatPNG) {
        return nil;
    }
    
    NSMutableData *imageData = [NSMutableData data];
    CFStringRef imageUTType = [NSData sd_UTTypeFromSDImageFormat:SDImageFormatPNG];
    NSArray<SDWebImageFrame *> *frames = [SDWebImageCoderHelper framesFromAnimatedImage:image];
    
    // Create an image destination. APNG does not support EXIF image orientation
    CGImageDestinationRef imageDestination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData, imageUTType, frames.count, NULL);
    if (!imageDestination) {
        // Handle failure.
        return nil;
    }
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    double compressionQuality = 1;
    if ([options valueForKey:SDWebImageCoderEncodeCompressionQuality]) {
        compressionQuality = [[options valueForKey:SDWebImageCoderEncodeCompressionQuality] doubleValue];
    }
    [properties setValue:@(compressionQuality) forKey:(__bridge_transfer NSString *)kCGImageDestinationLossyCompressionQuality];
    
    BOOL encodeFirstFrame = [options[SDWebImageCoderEncodeFirstFrameOnly] boolValue];
    if (encodeFirstFrame || frames.count == 0) {
        // for static single PNG images
        CGImageDestinationAddImage(imageDestination, image.CGImage, (__bridge CFDictionaryRef)properties);
    } else {
        // for animated APNG images
        NSUInteger loopCount = image.sd_imageLoopCount;
        NSDictionary *pngProperties = @{(__bridge_transfer NSString *)kCGImagePropertyAPNGLoopCount : @(loopCount)};
        [properties setValue:pngProperties forKey:(__bridge_transfer NSString *)kCGImagePropertyPNGDictionary];
        CGImageDestinationSetProperties(imageDestination, (__bridge CFDictionaryRef)properties);
        
        for (size_t i = 0; i < frames.count; i++) {
            SDWebImageFrame *frame = frames[i];
            float frameDuration = frame.duration;
            CGImageRef frameImageRef = frame.image.CGImage;
            NSDictionary *frameProperties = @{(__bridge_transfer NSString *)kCGImagePropertyPNGDictionary : @{(__bridge_transfer NSString *)kCGImagePropertyAPNGDelayTime : @(frameDuration)}};
            CGImageDestinationAddImage(imageDestination, frameImageRef, (__bridge CFDictionaryRef)frameProperties);
        }
    }
    // Finalize the destination.
    if (CGImageDestinationFinalize(imageDestination) == NO) {
        // Handle failure.
        imageData = nil;
    }
    
    CFRelease(imageDestination);
    
    return [imageData copy];
}

#pragma mark - Progressive Decode

- (BOOL)canIncrementalDecodeFromData:(NSData *)data {
    return ([NSData sd_imageFormatForImageData:data] == SDImageFormatPNG);
}

- (instancetype)initIncrementalWithOptions:(nullable SDWebImageCoderOptions *)options {
    self = [super init];
    if (self) {
        _imageSource = CGImageSourceCreateIncremental((__bridge CFDictionaryRef)@{(__bridge_transfer NSString *)kCGImageSourceShouldCache : @(YES)});
#if SD_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

- (void)updateIncrementalData:(NSData *)data finished:(BOOL)finished {
    if (_finished) {
        return;
    }
    _imageData = data;
    _finished = finished;
    
    // The following code is from http://www.cocoaintheshell.com/2011/05/progressive-images-download-imageio/
    // Thanks to the author @Nyx0uf
    
    // Update the data source, we must pass ALL the data, not just the new bytes
    CGImageSourceUpdateData(_imageSource, (__bridge CFDataRef)data, finished);
    
    if (_width + _height == 0) {
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(_imageSource, 0, NULL);
        if (properties) {
            CFTypeRef val = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
            if (val) CFNumberGetValue(val, kCFNumberLongType, &_height);
            val = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
            if (val) CFNumberGetValue(val, kCFNumberLongType, &_width);
            CFRelease(properties);
        }
    }
    
    // For animated image progressive decoding because the frame count and duration may be changed.
    [self scanAndCheckFramesValidWithImageSource:_imageSource];
}

- (UIImage *)incrementalDecodedImageWithOptions:(SDWebImageCoderOptions *)options {
    UIImage *image;
    
    if (_width + _height > 0) {
        // Create the image
        CGImageRef partialImageRef = CGImageSourceCreateImageAtIndex(_imageSource, 0, NULL);
        
        if (partialImageRef) {
            CGFloat scale = 1;
            if ([options valueForKey:SDWebImageCoderDecodeScaleFactor]) {
                scale = [[options valueForKey:SDWebImageCoderDecodeScaleFactor] doubleValue];
                if (scale < 1) {
                    scale = 1;
                }
            }
#if SD_UIKIT || SD_WATCH
            image = [[UIImage alloc] initWithCGImage:partialImageRef scale:scale orientation:UIImageOrientationUp];
#else
            image = [[UIImage alloc] initWithCGImage:partialImageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#endif
            CGImageRelease(partialImageRef);
        }
    }
    
    return image;
}

#pragma mark - SDWebImageAnimatedCoder
- (nullable instancetype)initWithAnimatedImageData:(nullable NSData *)data options:(nullable SDWebImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    self = [super init];
    if (self) {
        // use Image/IO cache because it's already keep a balance between CPU & memory
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge_transfer NSString *)kCGImageSourceShouldCache : @(YES)});
        if (!imageSource) {
            return nil;
        }
        BOOL framesValid = [self scanAndCheckFramesValidWithImageSource:imageSource];
        if (!framesValid) {
            CFRelease(imageSource);
            return nil;
        }
        CGFloat scale = 1;
        if ([options valueForKey:SDWebImageCoderDecodeScaleFactor]) {
            scale = [[options valueForKey:SDWebImageCoderDecodeScaleFactor] doubleValue];
            if (scale < 1) {
                scale = 1;
            }
        }
        _scale = scale;
        _imageSource = imageSource;
        _imageData = data;
#if SD_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

- (BOOL)scanAndCheckFramesValidWithImageSource:(CGImageSourceRef)imageSource
{
    if (!imageSource) {
        return NO;
    }
    NSUInteger frameCount = CGImageSourceGetCount(imageSource);
    NSUInteger loopCount = [self sd_imageLoopCountWithSource:imageSource];
    NSMutableArray<SDAPNGCoderFrame *> *frames = [NSMutableArray array];
    
    for (size_t i = 0; i < frameCount; i++) {
        SDAPNGCoderFrame *frame = [[SDAPNGCoderFrame alloc] init];
        frame.index = i;
        frame.duration = [self sd_frameDurationAtIndex:i source:imageSource];
        [frames addObject:frame];
    }
    
    _frameCount = frameCount;
    _loopCount = loopCount;
    _frames = [frames copy];
    
    return YES;
}

- (NSData *)animatedImageData
{
    return _imageData;
}

- (NSUInteger)animatedImageLoopCount
{
    return _loopCount;
}

- (NSUInteger)animatedImageFrameCount
{
    return _frameCount;
}

- (NSTimeInterval)animatedImageDurationAtIndex:(NSUInteger)index
{
    if (index >= _frameCount) {
        return 0;
    }
    return _frames[index].duration;
}

- (UIImage *)animatedImageFrameAtIndex:(NSUInteger)index
{
    CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_imageSource, index, NULL);
    if (!imageRef) {
        return nil;
    }
    // Image/IO create CGImage does not decompressed, so we do this because this is called background queue, this can avoid main queue block when rendering(especially when one more imageViews use the same image instance)
    CGImageRef newImageRef = [SDWebImageCoderHelper CGImageCreateDecoded:imageRef];
    if (!newImageRef) {
        newImageRef = imageRef;
    } else {
        CGImageRelease(imageRef);
    }
#if SD_MAC
    UIImage *image = [[UIImage alloc] initWithCGImage:newImageRef scale:_scale orientation:kCGImagePropertyOrientationUp];
#else
    UIImage *image = [UIImage imageWithCGImage:newImageRef scale:_scale orientation:UIImageOrientationUp];
#endif
    CGImageRelease(newImageRef);
    return image;
}

@end
//
//  WarpedTextView.m
//  WarpedText
//
//  Created by Matt Bridges on 10/19/12.
//  Copyright (c) 2012 Matt Bridges. All rights reserved.
//

#import "WarpedTextView.h"
#import <CoreText/CoreText.h>

typedef enum {
    WTCurveTypeQuadratic,
    WTCurveTypeCubic
} WTCurveType;

typedef struct {
    WTCurveType curveType;
    CGFloat A;
    CGFloat B;
    CGFloat C;
    CGFloat D;
    CGFloat E;
    CGFloat F;
    CGFloat G;
    CGFloat H;
} WTCurveCoefficients;

typedef struct {
    WTCurveCoefficients coeffs;
    CGFloat *arcLengths;
    int numSamples;
    CGMutablePathRef warpedPath;
} WTContext;

@implementation WarpedTextView

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code
    }
    return self;
}

void WTDrawPathInContext(CGContextRef context, CGPathRef path);

CGPoint WTEvalCurve(WTCurveCoefficients coeffs, CGFloat t)
{
    CGFloat x = coeffs.A * t * t * t + coeffs.B * t * t + coeffs.C * t + coeffs.D;
    CGFloat y = coeffs.E * t * t * t + coeffs.F * t * t + coeffs.G * t + coeffs.H;
    return CGPointMake(x, y);
}

CGPoint WTEvalQuadCurve(WTCurveCoefficients coeffs, CGFloat t)
{
    CGFloat x = coeffs.A * t * t + coeffs.B * t + coeffs.C;
    CGFloat y = coeffs.D * t * t + coeffs.E * t + coeffs.F;
    return CGPointMake(x, y);
}

CGFloat WTDistance(CGPoint p1, CGPoint p2)
{
    CGFloat dx = p2.x - p1.x;
    CGFloat dy = p2.y - p1.y;
    return sqrt(dx * dx + dy * dy);
}


CGPoint* WTSampleCurve(WTCurveCoefficients coeffs, int numSamples)
{
    CGPoint *samples = malloc(sizeof(CGPoint) * numSamples);
    
    for (int i = 0; i < numSamples; i++) {
        CGPoint p;
        CGFloat t = i / (CGFloat)(numSamples - 1);
        if (coeffs.curveType == WTCurveTypeCubic) {
            p = WTEvalCurve(coeffs, t);
        } else if (coeffs.curveType == WTCurveTypeQuadratic) {
            p = WTEvalQuadCurve(coeffs, t);
        }
        samples[i] = p;
    }
    
    return samples;
}

CGFloat* WTMeasureCurve(WTCurveCoefficients coeffs, int numSamples)
{
    CGPoint *points = WTSampleCurve(coeffs, numSamples);
    CGFloat *lengths = malloc(sizeof(CGFloat) * (numSamples));
    CGFloat sum = 0.0;
    CGPoint prevPoint = points[0];
    lengths[0] = 0.0;
    for (int i = 1; i < numSamples; i++) {
        CGFloat dist = WTDistance(points[i], prevPoint);
        sum += dist;
        lengths[i] = sum;
        prevPoint = points[i];
    }
    
    free(points);
    return lengths;
}

CGFloat TForU(CGFloat u, CGFloat *arcLengths, int numSamples)
{
    CGFloat targetArcLength = u * arcLengths[numSamples - 1];
    int i;
    for (i = numSamples - 1; i > 0; i--) {
        if (arcLengths[i] < targetArcLength)
            break;
    }
    
    if (arcLengths[i] == targetArcLength) {
        return i / (CGFloat)(numSamples - 1);
    } else {
        CGFloat lengthBefore = arcLengths[i];
        CGFloat lengthAfter = arcLengths[i + 1];
        CGFloat segmentLength = lengthAfter - lengthBefore;
        
        CGFloat segmentFraction = (targetArcLength - lengthBefore) / segmentLength;
        return (i + segmentFraction) / (CGFloat)(numSamples - 1);
    }
}

CGPoint WTTransformPointToCurve(CGPoint pt, WTCurveCoefficients coeffs, CGFloat *arcLengths, int numSamples)
{
    CGFloat textX = pt.x;
    CGFloat textY = pt.y;
    
    // Normalize the x coord into value between 0 and 1.
    CGFloat u = textX / arcLengths[numSamples - 1];
    CGFloat t = TForU(u, arcLengths, numSamples);
    
    // Calculate the spline point at t
    CGPoint s = WTEvalCurve(coeffs, t);
    
    // Calculate the tangent vector at (s.x, s.y)
    CGFloat tx = 3 * coeffs.A * t * t + 2 * coeffs.B * t + coeffs.C;
    CGFloat ty = 3 * coeffs.E * t * t + 2 * coeffs.F * t + coeffs.G;
    
    // Find the perpendicular vector
    CGFloat px = ty;
    CGFloat py = -tx;
    
    // Normalize the perpendicular vector
    CGFloat magnitude = sqrt(px * px + py * py);
    px = px / magnitude;
    py = py / magnitude;
    
    // Multiply the perpendicular vector by height in text space.
    px *= textY;
    py *= textY;
    
    return CGPointMake(px + s.x, py + s.y);
}

CGPoint WTTransformPointToQuadCurve(CGPoint pt, WTCurveCoefficients coeffs, CGFloat *arcLengths, int numSamples)
{
    CGFloat textX = pt.x;
    CGFloat textY = pt.y;
    
    // Normalize the x coord into value between 0 and 1.
    CGFloat u = textX / arcLengths[numSamples - 1];
    CGFloat t = TForU(u, arcLengths, numSamples);
    
    // Calculate the spline point at t
    CGPoint s = WTEvalQuadCurve(coeffs, t);
    
    // Calculate the tangent vector at (s.x, s.y)
    CGFloat tx = 2 * coeffs.A * t + coeffs.B;
    CGFloat ty = 2 * coeffs.E * t + coeffs.F;
    
    // Find the perpendicular vector
    CGFloat px = ty;
    CGFloat py = -tx;
    
    // Normalize the perpendicular vector
    CGFloat magnitude = sqrt(px * px + py * py);
    px = px / magnitude;
    py = py / magnitude;
    
    // Multiply the perpendicular vector by height in text space.
    px *= textY;
    py *= textY;
    
    return CGPointMake(px + s.x, py + s.y);
}


void _warpPathToCurveApplierFunc(void *info, const CGPathElement *element)
{
    WTContext *ctx = (WTContext *)info;
    
    CGPoint p1, p2, p3;
    
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            p1 = WTTransformPointToCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathMoveToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddLineToPoint:
            p1 = WTTransformPointToCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddLineToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddQuadCurveToPoint:
            p1 = WTTransformPointToCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p2 = WTTransformPointToCurve(element->points[1], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddQuadCurveToPoint(ctx->warpedPath, NULL, p1.x, p1.y, p2.x, p2.y);
            break;
        case kCGPathElementAddCurveToPoint:
            p1 = WTTransformPointToCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p2 = WTTransformPointToCurve(element->points[1], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p3 = WTTransformPointToCurve(element->points[2], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddCurveToPoint(ctx->warpedPath, NULL, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
            break;
        case kCGPathElementCloseSubpath:
            CGPathCloseSubpath(ctx->warpedPath);
            break;
        default:
            break;
    }
}

void _warpPathToQuadCurveApplierFunc(void *info, const CGPathElement *element)
{
    WTContext *ctx = (WTContext *)info;
    
    CGPoint p1, p2, p3;
    
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            p1 = WTTransformPointToQuadCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathMoveToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddLineToPoint:
            p1 = WTTransformPointToQuadCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddLineToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddQuadCurveToPoint:
            p1 = WTTransformPointToQuadCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p2 = WTTransformPointToQuadCurve(element->points[1], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddQuadCurveToPoint(ctx->warpedPath, NULL, p1.x, p1.y, p2.x, p2.y);
            break;
        case kCGPathElementAddCurveToPoint:
            p1 = WTTransformPointToQuadCurve(element->points[0], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p2 = WTTransformPointToQuadCurve(element->points[1], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            p3 = WTTransformPointToQuadCurve(element->points[2], ctx->coeffs, ctx->arcLengths, ctx->numSamples);
            CGPathAddCurveToPoint(ctx->warpedPath, NULL, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
            break;
        case kCGPathElementCloseSubpath:
            CGPathCloseSubpath(ctx->warpedPath);
            break;
        default:
            break;
    }
}

- (void)drawRect:(CGRect)rect
{
    [super drawRect:rect];
    
    CGContextRef context = UIGraphicsGetCurrentContext();
	
    // Get an attributed string to draw.
    CTFontRef fontRef = CTFontCreateWithName((CFStringRef)@"Futura", 18.0f, NULL);
    NSAttributedString *attString = [self attributedStringForNSString:@"The quick brown fox" withFont:fontRef];
    
    // Get a path to draw along.
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, 0, 0);
    CGPathAddCurveToPoint(path, NULL, 250, -100, 50, 100, 320, 0);
    
    // Get a path representing the text
    CGPathRef letters = [self pathForAttributedString:attString];
    WTCurveCoefficients coeffs = getCoefficientsForCurve(0, 0, 250, -100, 50, 100, 320, 0);
    
    // Calculate vertical offset to center.
    CGFloat ascent = CTFontGetAscent(fontRef);
    CGFloat descent = CTFontGetDescent(fontRef);
    CGFloat yOffset =  -(ascent - (ascent + descent) / 2);
    
    // Calculate horizontal offset to center.
    CGFloat *lengths = WTMeasureCurve(coeffs, 101);
    CGRect textBounds = CGPathGetPathBoundingBox(letters);
    CGFloat arcWidth = lengths[100];
    CGFloat textWidth = textBounds.size.width;
    CGFloat xOffset = (arcWidth - textWidth) / 2;
    
    // Center text vertically and horizontally.
    CGAffineTransform transform = CGAffineTransformMakeTranslation(xOffset, yOffset);
    CGPathRef transformedLetters = CGPathCreateCopyByTransformingPath(letters, &transform);
    
    // Warp the text.
    CGMutablePathRef warpedLetters = CGPathCreateMutable();
    WTContext *ctx = malloc(sizeof(WTContext));
    ctx->coeffs = coeffs;
    ctx->arcLengths = lengths;
    ctx->warpedPath = warpedLetters;
    ctx->numSamples = 101;
    CGPathApply(transformedLetters, (void *)ctx, _warpPathToCurveApplierFunc);
    
    // Drawing.
    CGContextConcatCTM(context, CGAffineTransformMakeTranslation(0, 200));


//    // DEBUG: Draw original text
//    CGContextSaveGState(context);
//    CGContextConcatCTM(context, CGAffineTransformMakeScale(1.0, -1.0));
//    CGContextBeginPath(context);
//    CGContextAddPath(context, letters);
//    CGContextSetRGBFillColor(context, 0.0, 0.0, 0.0, 1.0);
//    CGContextFillPath(context);
//    CGContextRestoreGState(context);
    
//    // DEBUG: Draw the original text paths
//    WTDrawPathInContext(context, letters);
    
    // Draw the path
    CGContextSetRGBStrokeColor(context, 1.0, 0.0, 0.0, 1.0);
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextStrokePath(context);
    
    
//    // DEBUG: draw the points
//    CGContextSaveGState(context);
//    CGContextSetRGBFillColor(context, 0.0, 1.0, 1.0, 1.0);
//    CGPoint *points = WTSampleCurve(coeffs, 101);
//    for (int i = 0; i < 101; i++) {
//        CGContextFillEllipseInRect(context, CGRectMake(points[i].x - 1, points[i].y - 1, 2, 2));
//    }
//    CGContextRestoreGState(context);
    
//    // DEBUG: draw equal-spaced points
//    CGContextSaveGState(context);
//    CGContextSetRGBFillColor(context, 0.0, 1.0, 0.0, 1.0);
//    for (int i = 0; i < 101; i++) {
//        CGFloat t = TForU(i / 101.0, lengths, 101);
//        CGPoint newPoint = WTEvalCurve(coeffs, t);
//        CGContextFillEllipseInRect(context, CGRectMake(newPoint.x - 1, newPoint.y - 1, 2, 2));
//    }
//    CGContextRestoreGState(context);
    
    // Stroke the letters
    CGContextBeginPath(context);
    CGContextAddPath(context, warpedLetters);
    CGContextSetRGBStrokeColor(context, 1.0, 0.0, 0.0, 3.0);
    CGContextSetLineWidth(context, 1.0);
    CGContextStrokePath(context);

    // Fill the letters;
    CGContextBeginPath(context);
    CGContextAddPath(context, warpedLetters);
    CGContextFillPath(context);
    
    free(ctx);
    free(lengths);
}

- (NSAttributedString *) attributedStringForNSString:(NSString *)string withFont:(CTFontRef)fontRef
{
	// The line break mode wraps character-by-character
	uint8_t breakMode = kCTLineBreakByCharWrapping;
	CTParagraphStyleSetting wordBreakSetting = {
		kCTParagraphStyleSpecifierLineBreakMode,
		sizeof(uint8_t),
		&breakMode
	};
	CTParagraphStyleSetting alignSettings[1] = {wordBreakSetting};
	CTParagraphStyleRef paraStyle = CTParagraphStyleCreate(alignSettings, 1);
    
	// Create the attributed string
	NSDictionary *attrDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
									(__bridge id)fontRef, (NSString *)kCTFontAttributeName,
									(__bridge id)paraStyle, (NSString *)kCTParagraphStyleAttributeName,
									nil];
	NSAttributedString *attString = [[NSAttributedString alloc] initWithString:string attributes:attrDictionary];
	CFRelease(fontRef);
	CFRelease(paraStyle);
    
    return attString;
}

- (CGPathRef) pathForAttributedString:(NSAttributedString *)attString
{
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attString); // 5-1
    
    CGMutablePathRef letters = CGPathCreateMutable();
    CFArrayRef runArray = CTLineGetGlyphRuns(line);
    
    // for each RUN
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runArray); runIndex++)
    {
        // Get FONT for this run
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runArray, runIndex);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        
        // for each GLYPH in run
        for (CFIndex runGlyphIndex = 0; runGlyphIndex < CTRunGetGlyphCount(run); runGlyphIndex++)
        {
            // get Glyph & Glyph-data
            CFRange thisGlyphRange = CFRangeMake(runGlyphIndex, 1);
            CGGlyph glyph;
            CGPoint position;
            CTRunGetGlyphs(run, thisGlyphRange, &glyph);
            CTRunGetPositions(run, thisGlyphRange, &position);
            
            // Get PATH of outline
            {
                CGPathRef letter = CTFontCreatePathForGlyph(runFont, glyph, NULL);
                CGAffineTransform t = CGAffineTransformMakeTranslation(position.x, position.y);
                CGPathAddPath(letters, &t, letter);
                CGPathRelease(letter);
            }
        }
    }
    
    CFRelease(line);
    return letters;
}

WTCurveCoefficients getCoefficientsForCurve(CGFloat x0, CGFloat y0,
                                          CGFloat x1, CGFloat y1,
                                          CGFloat x2, CGFloat y2,
                                          CGFloat x3, CGFloat y3)
{
    // Calculate coefficients.
    WTCurveCoefficients coeffs;
    coeffs.curveType = WTCurveTypeCubic;
    coeffs.A = x3 - 3 * x2 + 3 * x1 - x0;
    coeffs.B = 3 * x2 - 6 * x1 + 3 * x0;
    coeffs.C = 3 * x1 - 3 * x0;
    coeffs.D = x0;
    coeffs.E = y3 - 3 * y2 + 3 * y1 - y0;
    coeffs.F = 3 * y2 - 6 * y1 + 3 * y0;
    coeffs.G = 3 * y1 - 3 * y0;
    coeffs.H = y0;
    return coeffs;
}

WTCurveCoefficients getCoefficientsForQuadCurve(CGFloat x0, CGFloat y0,
                                                  CGFloat x1, CGFloat y1,
                                                  CGFloat x2, CGFloat y2)
{
    // Calculate coefficients.
    WTCurveCoefficients coeffs;
    coeffs.curveType = WTCurveTypeCubic;
    coeffs.A = x2 - 2 * x1 + x0;
    coeffs.B = 2 * x1 - 2 * x0;
    coeffs.C = x0;
    coeffs.D = y2 - 2 * y1 + y0;
    coeffs.E = 2 * y1 - 2 * y0;
    coeffs.F = y0;
    return coeffs;
}

void _drawPathApplierFunction(void *info, const CGPathElement *element)
{
    CGContextRef context = (CGContextRef)info;
    CGPoint *points = element->points;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            CGContextMoveToPoint(context, points[0].x, points[0].y);
            break;
        case kCGPathElementAddCurveToPoint:
            CGContextAddCurveToPoint(context, points[0].x, points[0].y, points[1].x, points[1].y, points[2].x, points[2].y);
            break;
        case kCGPathElementAddQuadCurveToPoint:
            CGContextAddQuadCurveToPoint(context, points[0].x, points[0].y, points[1].x, points[1].y);
            break;
        case kCGPathElementAddLineToPoint:
            CGContextAddLineToPoint(context, points[0].x, points[0].y);
            break;
        case kCGPathElementCloseSubpath:
            CGContextStrokePath(context);
            CGContextBeginPath(context);
            break;
        default:
            break;
    }
}

void _drawPathApplierFunction2(void *info, const CGPathElement *element)
{
    CGContextRef context = (CGContextRef)info;
    CGPoint *points = element->points;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            CGContextFillEllipseInRect(context, CGRectMake(points[0].x - 0.5, points[0].y - 0.5, 1, 1));
            break;
        case kCGPathElementAddCurveToPoint:
            CGContextFillEllipseInRect(context, CGRectMake(points[2].x - 0.5, points[2].y - 0.5, 1, 1));
            break;
        case kCGPathElementAddQuadCurveToPoint:
            CGContextFillEllipseInRect(context, CGRectMake(points[1].x - 0.5, points[1].y - 0.5, 1, 1));
            break;
        case kCGPathElementAddLineToPoint:
            CGContextFillEllipseInRect(context, CGRectMake(points[0].x - 0.5, points[0].y - 0.5, 1, 1));
            break;
        case kCGPathElementCloseSubpath:
            break;
        default:
            break;
    }
}

void WTDrawPathInContext(CGContextRef context, CGPathRef path)
{
    CGContextSaveGState(context);
    CGContextConcatCTM(context, CGAffineTransformMakeScale(1.0, -1.0));
    CGContextSetRGBFillColor(context, 0.0, 1.0, 1.0, 1.0);
    CGContextSetRGBStrokeColor(context, 1.0, 0.0, 0.0, 1.0);
    CGContextSetLineWidth(context, 0.5);
    CGContextBeginPath(context);
    CGPathApply(path, (void *)context, _drawPathApplierFunction);
    CGContextStrokePath(context);
    CGPathApply(path, (void *)context, _drawPathApplierFunction2);
    CGContextRestoreGState(context);
}


@end

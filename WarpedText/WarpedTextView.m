//
//  WarpedTextView.m
//  WarpedText
//
//  Created by Matt Bridges on 10/19/12.
//  Copyright (c) 2012 Matt Bridges. All rights reserved.
//

#import "WarpedTextView.h"
#import <CoreText/CoreText.h>

#define NUM_SUBDIVISIONS 100

typedef struct {
    CGFloat A;
    CGFloat B;
    CGFloat C;
    CGFloat D;
    CGFloat E;
    CGFloat F;
    CGFloat G;
    CGFloat H;
} CurveCoefficients;

typedef struct {
    CurveCoefficients coeffs;
    CGRect textBounds;
    CGFloat *arcLengths;
    CGMutablePathRef warpedPath;
} WarpContext;



@implementation WarpedTextView

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code
    }
    return self;
}

CGPoint evalBezier(CurveCoefficients coeffs, CGFloat t)
{
    CGFloat x = coeffs.A * t * t * t + coeffs.B * t * t + coeffs.C * t + coeffs.D;
    CGFloat y = coeffs.E * t * t * t + coeffs.F * t * t + coeffs.G * t + coeffs.H;
    return CGPointMake(x, y);
}

CGFloat distance(CGPoint p1, CGPoint p2)
{
    CGFloat dx = p2.x - p1.x;
    CGFloat dy = p2.y - p1.y;
    return sqrt(dx * dx + dy * dy);
}


CGFloat* arcLengths(CurveCoefficients coeffs)
{
    CGPoint prevPoint = evalBezier(coeffs, 0);
    int numSubdivisions = NUM_SUBDIVISIONS;
    int numPoints = numSubdivisions + 1;
    CGFloat *lengths = malloc(sizeof(CGFloat) * numPoints);
    CGFloat sum = 0;
    lengths[0] = 0.0;
    
    for (int i = 1; i < numPoints; i++)
    {
        CGPoint p = evalBezier(coeffs, i / (CGFloat)numSubdivisions);
        CGFloat dist = distance(prevPoint, p);
        sum += dist;
        lengths[i] = sum;
        prevPoint = p;
    }
    
    return lengths;
}

CGFloat TForU(CGFloat u, CGFloat *arcLengths)
{
    CGFloat targetArcLength = u * arcLengths[NUM_SUBDIVISIONS];
    int i;
    for (i = NUM_SUBDIVISIONS; i > 0; i--) {
        if (arcLengths[i] < targetArcLength)
            break;
    }
    
    if (arcLengths[i] == targetArcLength) {
        return i / (CGFloat)NUM_SUBDIVISIONS;
    } else {
        CGFloat lengthBefore = arcLengths[i];
        CGFloat lengthAfter = arcLengths[i+1];
        CGFloat segmentLength = lengthAfter - lengthBefore;
        
        CGFloat segmentFraction = (targetArcLength - lengthBefore) / segmentLength;
        return (i + segmentFraction) / (CGFloat)NUM_SUBDIVISIONS;
    }
}

CGPoint warpPoint(CGPoint pt, CurveCoefficients coeffs, CGFloat *arcLengths)
{
    CGFloat textX = pt.x;
    CGFloat textY = pt.y;
    
    // Normalize the x coord into value between 0 and 1.
    CGFloat u = textX / arcLengths[NUM_SUBDIVISIONS];
    CGFloat t = TForU(u, arcLengths);
    
    // Calculate the spline point at t
    CGPoint s = evalBezier(coeffs, t);
    
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


void _warpTextApplierFunc(void *info, const CGPathElement *element)
{
    WarpContext *ctx = (WarpContext *)info;
    
    CGPoint p1, p2, p3;
    
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            p1 = warpPoint(element->points[0], ctx->coeffs, ctx->arcLengths);
            CGPathMoveToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddLineToPoint:
            p1 = warpPoint(element->points[0], ctx->coeffs, ctx->arcLengths);
            CGPathAddLineToPoint(ctx->warpedPath, NULL, p1.x, p1.y);
            break;
        case kCGPathElementAddQuadCurveToPoint:
            p1 = warpPoint(element->points[0], ctx->coeffs, ctx->arcLengths);
            p2 = warpPoint(element->points[1], ctx->coeffs, ctx->arcLengths);
            CGPathAddQuadCurveToPoint(ctx->warpedPath, NULL, p1.x, p1.y, p2.x, p2.y);
            break;
        case kCGPathElementAddCurveToPoint:
            p1 = warpPoint(element->points[0], ctx->coeffs, ctx->arcLengths);
            p2 = warpPoint(element->points[1], ctx->coeffs, ctx->arcLengths);
            p3 = warpPoint(element->points[2], ctx->coeffs, ctx->arcLengths);
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
    CTFontRef fontRef = CTFontCreateWithName((CFStringRef)@"Futura", 16.0f, NULL);
    NSAttributedString *attString = [self attributedStringForNSString:@"The quick brown fox jumps over the dog." withFont:fontRef];
    
    // Get a path to draw along.
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, 0, 0);
    CGPathAddCurveToPoint(path, NULL, 250, -100, 50, 100, 320, 0);
    
    // Get a path representing the text
    CGPathRef letters = [self pathForAttributedString:attString];
    CurveCoefficients coeffs = getCoefficientsForCurve(0, 0, 250, -100, 50, 100, 320, 0);
    
    // Calculate vertical offset to center.
    CGFloat ascent = CTFontGetAscent(fontRef);
    CGFloat descent = CTFontGetDescent(fontRef);
    CGFloat yOffset =  -(ascent - (ascent + descent) / 2);
    
    // Calculate horizontal offset to center.
    CGFloat *lengths = arcLengths(coeffs);
    CGRect textBounds = CGPathGetPathBoundingBox(letters);
    CGFloat arcWidth = lengths[NUM_SUBDIVISIONS];
    CGFloat textWidth = textBounds.size.width;
    CGFloat xOffset = (arcWidth - textWidth) / 2;

    // Center text vertically and horizontally.
    CGAffineTransform transform = CGAffineTransformMakeTranslation(xOffset, yOffset);
    letters = CGPathCreateCopyByTransformingPath(letters, &transform);
    
    // Warp the text.
    CGMutablePathRef warpedLetters = CGPathCreateMutable();
    WarpContext *ctx = malloc(sizeof(WarpContext));
    ctx->coeffs = coeffs;
    ctx->textBounds = textBounds;
    ctx->arcLengths = lengths;
    ctx->warpedPath = warpedLetters;
    CGPathApply(letters, (void *)ctx, _warpTextApplierFunc);
    
    // Drawing.
    CGContextConcatCTM(context, CGAffineTransformMakeTranslation(0, 200));
    
    CGContextSetRGBStrokeColor(context, 1.0, 0.0, 0.0, 1.0);
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextStrokePath(context);

    CGContextBeginPath(context);
    CGContextAddPath(context, warpedLetters);
    CGContextSetRGBStrokeColor(context, 1.0, 1.0, 0.0, 1.0);
    CGContextSetLineWidth(context, 1.0);
    CGContextStrokePath(context);
    CGContextBeginPath(context);
    CGContextAddPath(context, warpedLetters);
    CGContextFillPath(context);
    
    free(ctx);
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

CurveCoefficients getCoefficientsForCurve(CGFloat x0, CGFloat y0,
                                         CGFloat x1, CGFloat y1,
                                         CGFloat x2, CGFloat y2,
                                         CGFloat x3, CGFloat y3)
{
    // Calculate coefficients
    CurveCoefficients coeffs;
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


@end

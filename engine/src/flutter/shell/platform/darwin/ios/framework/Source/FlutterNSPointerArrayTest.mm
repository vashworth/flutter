// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <XCTest/XCTest.h>
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterNSPointerArray.h"

FLUTTER_ASSERT_ARC

@interface FlutterNSPointerArrayTest : XCTestCase
@end

@implementation FlutterNSPointerArrayTest

- (void)testCompact {
  FlutterNSPointerArray* array = [FlutterNSPointerArray weakObjectsPointerArray];
  NSObject* object1 = [[NSObject alloc] init];
  @autoreleasepool {
    NSObject* object2 = [[NSObject alloc] init];
    [array addPointer:(__bridge void*)object1];
    [array addPointer:(__bridge void*)object2];
    XCTAssertEqual(array.count, 2);
  }
  // object2 is now deallocated.
  [array compact];
  XCTAssertEqual(array.count, 1);
  XCTAssertEqual([array pointerAtIndex:0], (__bridge void*)object1);
}

@end

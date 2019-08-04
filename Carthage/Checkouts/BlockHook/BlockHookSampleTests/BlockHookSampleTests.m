//
//  BlockHookSampleTests.m
//  BlockHookSample iOSTests
//
//  Created by 杨萧玉 on 2019/4/19.
//  Copyright © 2019 杨萧玉. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <BlockHook/BlockHook.h>

struct TestStruct {
    int64_t a;
    double b;
    float c;
    char d;
    int *e;
    CGRect *f;
    uint64_t g;
};

@interface BlockHookSampleTests : XCTestCase

@end

@implementation BlockHookSampleTests

struct TestStruct _testRect;

- (void)setUp {
    // Put setup code here. This method is called before the invocation of each test method in the class.
    int e = 5;
    _testRect = (struct TestStruct){1, 2.0, 3.0, 4, &e, NULL, 7};
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)foo:(void(^)(void))block
{
    if (block) {
        block();
    }
}

- (void)performBlock:(void(^)(void))block
{
    BHToken *tokenInstead = [block block_hookWithMode:BlockHookModeAfter usingBlock:^{
        NSLog(@"hook stack block succeed!");
    }];
    
    __unused BHToken *tokenDead = [block block_hookWithMode:BlockHookModeDead usingBlock:^{
        NSLog(@"stack block dead!");
    }];
    
    [self foo:block];
    [tokenInstead remove];
}

- (void)testStructReturn {
    struct TestStruct (^StructReturnBlock)(int) = ^(int x)
    {
        struct TestStruct result = _testRect;
        return result;
    };
    
    [StructReturnBlock block_hookWithMode:BlockHookModeAfter usingBlock:^(BHInvocation *invocation, int x){
        struct TestStruct ret;
        [invocation getReturnValue:&ret];
        ret.a = 100;
        [invocation setReturnValue:&ret];
        NSAssert(x == 8, @"Wrong arg!");
    }];
    
    __unused struct TestStruct result = StructReturnBlock(8);
    NSAssert(result.a == 100, @"Modify return struct failed!");
}

- (void)testStructPointerReturn {
    struct TestStruct * (^StructReturnBlock)(void) = ^()
    {
        struct TestStruct *result = &_testRect;
        return result;
    };
    
    [StructReturnBlock block_hookWithMode:BlockHookModeAfter usingBlock:^(BHInvocation *invocation){
        struct TestStruct *ret;
        [invocation getReturnValue:&ret];
        ret->a = 100;
        [invocation setReturnValue:&ret];
    }];
    
    __unused struct TestStruct *result = StructReturnBlock();
    NSAssert(result->a == 100, @"Modify return struct failed!");
}

- (void)testStructArg {
    void (^StructReturnBlock)(struct TestStruct) = ^(struct TestStruct test)
    {
        NSAssert(test.a == 100, @"Modify struct member failed!");
    };
    
    [StructReturnBlock block_hookWithMode:BlockHookModeBefore usingBlock:^(BHInvocation *invocation, struct TestStruct test){
        // Hook 改参数
        struct TestStruct arg;
        [invocation getArgument:&arg atIndex:1];
        arg.a = 100;
        [invocation setArgument:&arg atIndex:1];
    }];
    StructReturnBlock(_testRect);
}

- (void)testCGRectArgAndRet {
    CGRect (^StructReturnBlock)(CGRect) = ^(CGRect test)
    {
        NSAssert(test.origin.x == 100, @"Modify struct member failed!");
        return test;
    };
    
    [StructReturnBlock block_hookWithMode:BlockHookModeBefore usingBlock:^(BHInvocation *invocation, CGRect test){
        // Hook 改参数
        CGRect arg;
        [invocation getArgument:&arg atIndex:1];
        arg.origin.x = 100;
        [invocation setArgument:&arg atIndex:1];
    }];
    StructReturnBlock((CGRect){1,2,3,4});
}

- (void)testStructPointerArg {
    void (^StructReturnBlock)(struct TestStruct *) = ^(struct TestStruct *test)
    {
        NSAssert(test->a == 100, @"Modify struct member failed!");
    };
    
    [StructReturnBlock block_hookWithMode:BlockHookModeBefore usingBlock:^(BHInvocation *invocation, struct TestStruct test){
        // Hook 改参数
        struct TestStruct *arg;
        [invocation getArgument:&arg atIndex:1];
        arg->a = 100;
        [invocation setArgument:&arg atIndex:1];
    }];
    StructReturnBlock(&_testRect);
}

- (void)testStackBlock {
    NSObject *z = NSObject.new;
    [self performBlock:^{
        NSLog(@"stack block:%@", z);
    }];
}

- (void)testProtocol {
    int(^block)(int x, int y) = ^int(int x, int y) {
        int result = x + y;
        NSLog(@"%d + %d = %d", x, y, result);
        return result;
    };
    const char *(^protocolBlock)(id<CALayerDelegate>, int(^)(int, int)) = ^(id<CALayerDelegate> delegate, int(^block)(int, int)) {
        if (block) {
            block(1, 2);
        }
        return (const char *)"test protocol";
    };
    const char *fakeResult = "lalalala";
    [protocolBlock block_hookWithMode:BlockHookModeAfter usingBlock:^(BHInvocation *invocation, id<CALayerDelegate> delegate, int(^block)(int x, int y)){
        [invocation setReturnValue:(void *)&fakeResult];
    }];
    id z = [NSObject new];
    __unused const char *result = protocolBlock(z, block);
    NSAssert(strcmp(result, fakeResult) == 0, @"Change const char * result failed!");
}

- (void)testHookBlock {
    
    NSObject *z = NSObject.new;
    int(^block)(int x, int y) = ^int(int x, int y) {
        int result = x + y;
        NSLog(@"%d + %d = %d, z is a NSObject: %@", x, y, result, z);
        return result;
    };
    
    __unused BHToken *tokenDead = [block block_hookWithMode:BlockHookModeDead usingBlock:^(BHInvocation *invocation){
        // BHInvocation is the only arg.
        NSLog(@"block dead! token:%@", invocation.token);
    }];
    
    BHToken *tokenInstead = [block block_hookWithMode:BlockHookModeInstead usingBlock:^(BHInvocation *invocation, int x, int y){
        [invocation invokeOriginalBlock];
        int ret = 0;
        [invocation getReturnValue:&ret];
        NSLog(@"let me see original result: %d", ret);
        // change the block imp and result
        ret = x * y;
        [invocation setReturnValue:&ret];
        NSLog(@"hook instead: '+' -> '*'");
    }];
    
    NSAssert([tokenInstead.mangleName isEqualToString:@"__37-[BlockHookSampleTests testHookBlock]_block_invoke"], @"Wrong mangle name!");
    
    __unused BHToken *tokenAfter = [block block_hookWithMode:BlockHookModeAfter usingBlock:^(BHInvocation *invocation, int x, int y){
        // print args and result
        int ret = 0;
        [invocation getReturnValue:&ret];
        NSLog(@"hook after block! %d * %d = %d", x, y, ret);
    }];
    
    __unused BHToken *tokenBefore = [block block_hookWithMode:BlockHookModeBefore usingBlock:^(BHInvocation *invocation){
        // BHInvocation has to be the first arg.
        NSLog(@"hook before block! invocation:%@", invocation);
    }];
    
    NSLog(@"hooked block");
    int ret = block(3, 5);
    NSAssert(ret == 15, @"hook failed!");
    NSLog(@"hooked result:%d", ret);
    // remove token.
    [tokenInstead remove];
    NSLog(@"remove tokens, original block");
    ret = block(3, 5);
    NSAssert(ret == 8, @"remove hook failed!");
    NSLog(@"original result:%d", ret);
    //        [tokenDead remove];
}

- (void)testRemoveAll {
    
    NSObject *z = NSObject.new;
    int(^block)(int x, int y) = ^int(int x, int y) {
        int result = x + y;
        NSLog(@"%d + %d = %d, z is a NSObject: %@", x, y, result, z);
        return result;
    };
    
    [block block_hookWithMode:BlockHookModeDead usingBlock:^(BHInvocation *invocation){
        // BHInvocation is the only arg.
        NSLog(@"block dead! token:%@", invocation.token);
    }];
    
    [block block_hookWithMode:BlockHookModeInstead usingBlock:^(BHInvocation *invocation, int x, int y){
        [invocation invokeOriginalBlock];
        int ret = 0;
        [invocation getReturnValue:&ret];
        NSLog(@"let me see original result: %d", ret);
        // change the block imp and result
        ret = x * y;
        [invocation setReturnValue:&ret];
        NSLog(@"hook instead: '+' -> '*'");
    }];
    
    [block block_hookWithMode:BlockHookModeAfter usingBlock:^(BHInvocation *invocation, int x, int y){
        // print args and result
        int ret = 0;
        [invocation getReturnValue:&ret];
        NSLog(@"hook after block! %d * %d = %d", x, y, ret);
    }];
    
    [block block_hookWithMode:BlockHookModeBefore usingBlock:^(BHInvocation *invocation){
        // BHInvocation has to be the first arg.
        NSLog(@"hook before block! invocation:%@", invocation);
    }];
    
    NSLog(@"hooked block");
    int ret = block(3, 5);
    NSAssert(ret == 15, @"hook failed!");
    NSLog(@"hooked result:%d", ret);
    // remove all tokens when you don't need.
    [block block_removeAllHook];
    NSLog(@"remove tokens, original block");
    ret = block(3, 5);
    NSLog(@"original result:%d", ret);
    NSAssert(ret == 8, @"remove hook failed!");
    NSAssert([block block_currentHookToken] == nil, @"remove all hook failed!");
}

- (void)testOverstepArgs
{
    NSObject *z = NSObject.new;
    int(^block)(int x, int y) = ^int(int x, int y) {
        int result = x + y;
        NSLog(@"%d + %d = %d, z is a NSObject: %@", x, y, result, z);
        return result;
    };
    
    __unused BHToken *tokenDead = [block block_hookWithMode:BlockHookModeDead usingBlock:^(BHInvocation *invocation, int a){
        // BHInvocation is the only arg.
        NSLog(@"block dead! token:%@", invocation.token);
        NSAssert(a == 0, @"Overstep args for DeadMode not pass!.");
    }];
    
    NSAssert(tokenDead != nil, @"Overstep args for DeadMode not pass!.");
    
    __unused BHToken *tokenInstead = [block block_hookWithMode:BlockHookModeInstead usingBlock:^(BHInvocation *invocation, int x, int y, int a){
        [invocation invokeOriginalBlock];
        int ret = 0;
        [invocation getReturnValue:&ret];
        NSLog(@"let me see original result: %d", ret);
        // change the block imp and result
        ret = x * y;
        [invocation setReturnValue:&ret];
        NSLog(@"hook instead: '+' -> '*'");
        NSAssert(a == 0, @"Overstep args for DeadMode not pass!.");
    }];
    
    NSAssert(tokenInstead != nil, @"Overstep args for InsteadMode not pass!.");
    
    block(1, 2);
}

- (void)testDispatchBlockCreate {
    XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"Wait for block invoke."];
    dispatch_queue_t queue = dispatch_queue_create("com.blockhook.test", DISPATCH_QUEUE_SERIAL);
    dispatch_block_t block = dispatch_block_create(0, ^{
        NSLog(@"I'm dispatch_block_t");
        [expectation fulfill];
    });
    
    __unused BHToken *token = [block block_hookWithMode:BlockHookModeAfter
                    usingBlock:^(BHInvocation *invocation){
                        NSLog(@"dispatch_block_t: Hook After");
                    }];
    NSAssert(token != nil, @"Hook dispatch_block_create not pass!.");
    dispatch_async(queue, block);
    [self waitForExpectations:@[expectation] timeout:30];
    dispatch_block_cancel(block);
}

- (void)testMultiModeHook {
    NSObject *z = NSObject.new;
    int(^block)(int x, int y) = ^int(int x, int y) {
        int result = x + y;
        NSLog(@"%d + %d = %d, z is a NSObject: %@", x, y, result, z);
        return result;
    };
    
    BHToken *token = [block block_hookWithMode:BlockHookModeDead|BlockHookModeBefore|BlockHookModeInstead|BlockHookModeAfter usingBlock:^(BHInvocation *invocation, int x, int y) {
        int ret = 0;
        [invocation getReturnValue:&ret];
        switch (invocation.mode) {
            case BlockHookModeBefore:
                // BHInvocation has to be the first arg.
                NSLog(@"hook before block! invocation:%@", invocation);
                break;
            case BlockHookModeInstead:
                [invocation invokeOriginalBlock];
                NSLog(@"let me see original result: %d", ret);
                // change the block imp and result
                ret = x * y;
                [invocation setReturnValue:&ret];
                NSLog(@"hook instead: '+' -> '*'");
                break;
            case BlockHookModeAfter:
                // print args and result
                NSLog(@"hook after block! %d * %d = %d", x, y, ret);
                break;
            case BlockHookModeDead:
                // BHInvocation is the only arg.
                NSLog(@"block dead! token:%@", invocation.token);
                break;
            default:
                break;
        }
    }];
    
    NSLog(@"hooked block");
    int ret = block(3, 5);
    NSAssert(ret == 15, @"hook failed!");
    NSLog(@"hooked result:%d", ret);
    // remove token.
    [token remove];
    NSLog(@"remove tokens, original block");
    ret = block(3, 5);
    NSAssert(ret == 8, @"remove hook failed!");
    NSLog(@"original result:%d", ret);
}

- (void)testSyncInterceptor {
    NSObject *ret1 = [NSObject new];
    NSObject *testArg = [NSObject new];
    NSObject *testArg1 = [NSObject new];
    
    NSObject *(^testblock)(NSObject *) = ^(NSObject *a) {
        NSAssert(a == testArg1, @"Sync Interceptor change argument failed!");
        return [NSObject new];
    };
    
    [testblock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        NSObject * __unsafe_unretained arg;
        [invocation getArgument:&arg atIndex:1];
        NSAssert(arg == testArg, @"Sync Interceptor wrong argument!");
        [invocation setArgument:(void *)&testArg1 atIndex:1];
        completion();
        [invocation setReturnValue:(void *)&ret1];
    }];
    
    NSObject *result = testblock(testArg);
    NSAssert(result == ret1, @"Sync Interceptor change return value failed!");
    NSLog(@"result:%@", result);
}

- (void)testAsyncInterceptor {
    NSObject *testArg = [NSObject new];
    NSObject *testArg1 = [NSObject new];
    XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"Wait for block invoke."];
    
    NSObject *(^testblock)(NSObject *) = ^(NSObject *a) {
        NSAssert(a == testArg1, @"Async Interceptor change argument failed!");
        return [NSObject new];
    };
    
    [testblock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSObject * __unsafe_unretained arg;
            [invocation getArgument:&arg atIndex:1];
            NSAssert(arg == testArg, @"Async Interceptor wrong argument!");
            [invocation setArgument:(void *)&testArg1 atIndex:1];
            completion();
            NSObject *ret = [NSObject new];
            [invocation setReturnValue:(void *)&ret];
            [expectation fulfill];
        });
    }];
    
    NSObject *result = testblock(testArg);
    NSLog(@"result:%@", result);
    
    [self waitForExpectations:@[expectation] timeout:30];
}

- (void)testSyncCharArgInterceptor {
    NSObject *ret1 = [NSObject new];
    char *origChar = (char *)malloc(sizeof(char) * 7);
    strcpy(origChar, "origin");
    NSObject *(^testblock)(char *) = ^(char *a) {
        NSAssert(strcmp(a, "hooked") == 0, @"Sync Char Arg Interceptor change argument failed!");
        return [NSObject new];
    };
    
    [testblock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        char *arg;
        [invocation getArgument:&arg atIndex:1];
        NSAssert(strcmp(arg, "origin") == 0, @"Sync Char Arg Interceptor wrong argument!");
        char *hooked = "hooked";
        [invocation setArgument:(void *)&hooked atIndex:1];
        completion();
        [invocation setReturnValue:(void *)&ret1];
    }];
    
    __unused NSObject *result = testblock(origChar);
    origChar[1] = '1';
    free(origChar);
    NSAssert(result == ret1, @"Sync Char Arg Interceptor change return value failed!");
}

- (void)testAsyncCharArgInterceptor {
    XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"Wait for block invoke."];
    char *origChar = (char *)malloc(sizeof(char) * 7);
    strcpy(origChar, "origin");
    NSObject *(^testblock)(char *) = ^(char *a) {
        NSAssert(strcmp(a, "hooked") == 0, @"Async Char Arg Interceptor change argument failed!");
        return [NSObject new];
    };
    
    [testblock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            char *arg;
            [invocation getArgument:&arg atIndex:1];
            NSAssert(strcmp(arg, "origin") == 0, @"Async Char Arg Interceptor wrong argument!");
            char *hooked = "hooked";
            [invocation setArgument:(void *)&hooked atIndex:1];
            completion();
            NSObject *ret = [NSObject new];
            [invocation setReturnValue:(void *)&ret];
            [expectation fulfill];
        });
    }];
    
    NSObject *result = testblock(origChar);
    origChar[1] = '1';
    free(origChar);
    NSLog(@"result:%@", result);
    
    [self waitForExpectations:@[expectation] timeout:30];
}

- (void)testSyncStructReturnInterceptor {
    
    NSObject *testArg = [NSObject new];
    NSObject *testArg1 = [NSObject new];
    
    struct TestStruct (^StructReturnBlock)(NSObject *) = ^(NSObject *a)
    {
        NSAssert(a == testArg1, @"Sync Struct Return Interceptor change argument failed!");
        struct TestStruct result = _testRect;
        return result;
    };
    
    [StructReturnBlock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        NSObject * __unsafe_unretained arg;
        [invocation getArgument:&arg atIndex:1];
        NSAssert(arg == testArg, @"Sync Interceptor wrong argument!");
        [invocation setArgument:(void *)&testArg1 atIndex:1];
        completion();
        struct TestStruct ret;
        [invocation getReturnValue:&ret];
        ret.a = 100;
        [invocation setReturnValue:&ret];
    }];
    
    __unused struct TestStruct result = StructReturnBlock(testArg);
    NSAssert(result.a == 100, @"Sync Interceptor change return value failed!");
}

- (void)testAsyncStructReturnInterceptor {
    NSObject *testArg = [NSObject new];
    NSObject *testArg1 = [NSObject new];
    XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"Wait for block invoke."];
    
    struct TestStruct (^StructReturnBlock)(NSObject *) = ^(NSObject *a)
    {
        NSAssert(a == testArg1, @"Sync Struct Return Interceptor change argument failed!");
        struct TestStruct result = _testRect;
        return result;
    };
    
    [StructReturnBlock block_interceptor:^(BHInvocation *invocation, IntercepterCompletion  _Nonnull completion) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSObject * __unsafe_unretained arg;
            [invocation getArgument:&arg atIndex:1];
            NSAssert(arg == testArg, @"Sync Interceptor wrong argument!");
            [invocation setArgument:(void *)&testArg1 atIndex:1];
            completion();
            struct TestStruct ret;
            [invocation getReturnValue:&ret];
            ret.a = 100;
            [invocation setReturnValue:&ret];
            [expectation fulfill];
        });
    }];
    
    __unused struct TestStruct result = StructReturnBlock(testArg);
    [self waitForExpectations:@[expectation] timeout:30];
}

@end

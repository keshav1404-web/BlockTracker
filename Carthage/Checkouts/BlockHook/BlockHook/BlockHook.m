//
//  BlockHook.m
//  BlockHookSample
//
//  Created by 杨萧玉 on 2018/2/27.
//  Copyright © 2018年 杨萧玉. All rights reserved.
//  Thanks to MABlockClosure : https://github.com/mikeash/MABlockClosure

#import "BlockHook.h"
#import <ffi.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/lock.h>

#if !__has_feature(objc_arc)
#error
#endif

enum {
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    BLOCK_HAS_CTOR =          (1 << 26), // helpers have C++ code
    BLOCK_IS_GLOBAL =         (1 << 28),
    BLOCK_HAS_STRET =         (1 << 29), // IFF BLOCK_HAS_SIGNATURE
    BLOCK_HAS_SIGNATURE =     (1 << 30),
};

struct _BHBlockDescriptor
{
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct _BHBlock
{
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct _BHBlockDescriptor *descriptor;
};

@interface BHDealloc : NSObject

@property (nonatomic, strong) BHToken *token;
@property (nonatomic, nullable) BHDeadBlock deadBlock;

@end

@implementation BHDealloc

- (void)dealloc
{
    if (self.deadBlock) {
        self.deadBlock(self.token);
    }
}

@end

@interface BHInvokeLock : NSObject

@property (nonatomic) dispatch_semaphore_t semaphore;
@property (nonatomic) os_unfair_lock unfair_lock OS_UNFAIR_LOCK_AVAILABILITY;
- (void)lock;
- (void)unlock;

@end

@implementation BHInvokeLock

- (instancetype)init
{
    self = [super init];
    if (self) {
        if (@available(iOS 10.0, macOS 10.12, *)) {
            _unfair_lock = OS_UNFAIR_LOCK_INIT;
        } else {
            _semaphore = dispatch_semaphore_create(1);
        }
    }
    return self;
}

- (void)lock
{
    if (@available(iOS 10.0, macOS 10.12, *)) {
        os_unfair_lock_lock(&_unfair_lock);
    } else {
        dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    }
}

- (void)unlock
{
    if (@available(iOS 10.0, macOS 10.12, *)) {
        os_unfair_lock_unlock(&_unfair_lock);
    } else {
        dispatch_semaphore_signal(self.semaphore);
    }
}

@end

@interface NSObject (BHInvokeLock)

- (BHInvokeLock *)invokeLock;

@end

@implementation NSObject (BHInvokeLock)

- (BHInvokeLock *)invokeLock
{
    BHInvokeLock *lock = objc_getAssociatedObject(self, _cmd);
    if (!lock) {
        lock = [BHInvokeLock new];
        objc_setAssociatedObject(self, _cmd, lock, OBJC_ASSOCIATION_RETAIN);
    }
    return lock;
}

@end

@interface BHToken ()
{
    ffi_cif _cif;
    void *_replacementInvoke;
    ffi_closure *_closure;
}
@property (nonatomic, readwrite) BlockHookMode mode;
@property (nonatomic) NSMutableArray *allocations;
@property (nonatomic, weak, readwrite) id block;
@property (nonatomic) NSUInteger numberOfArguments;
@property (nonatomic) id hookBlock;
@property (nonatomic, nullable, readwrite) NSString *mangleName;
@property (nonatomic) NSMethodSignature *originalBlockSignature;
@property (atomic) void *originInvoke;

/**
 if block is kind of `__NSStackBlock__` class.
 */
@property (nonatomic, getter=isStackBlock) BOOL stackBlock;
@property (nonatomic, getter=hasStret) BOOL stret;
@property (nonatomic, nullable, readwrite) BHToken *next;

- (void)invokeOriginalBlockWithArgs:(void **)args retValue:(void *)retValue;

@end

@interface BHInvocation ()

@property (nonatomic, readwrite) BHToken *token;
@property (nonatomic, readwrite) void *_Nullable *_Null_unspecified args;
@property (nonatomic, nullable, readwrite) void *retValue;

@end
@implementation BHInvocation

- (void)invokeOriginalBlock
{
    [self.token invokeOriginalBlockWithArgs:self.args retValue:self.retValue];
}

@end

@implementation BHToken

- (instancetype)initWithBlock:(id)block mode:(BlockHookMode)mode hookBlock:(id)hookBlock
{
    self = [super init];
    if (self) {
        _allocations = [[NSMutableArray alloc] init];
        _block = block;
        const char *encode = BHBlockTypeEncodeString(block);
        _numberOfArguments = [self _prepCIF:&_cif withEncodeString:encode];
        if (_numberOfArguments == -1) { // Unknown encode.
            return nil;
        }
        _originalBlockSignature = [NSMethodSignature signatureWithObjCTypes:encode];
        _closure = ffi_closure_alloc(sizeof(ffi_closure), &_replacementInvoke);
        if ([block isKindOfClass:NSClassFromString(@"__NSStackBlock")]) {
            NSLog(@"Hooking StackBlock causes a memory leak! I suggest you copy it first!");
            self.stackBlock = YES;
        }
        
        BHDealloc *bhDealloc = [BHDealloc new];
        bhDealloc.token = self;
        [self _prepClosure];
        objc_setAssociatedObject(block, _replacementInvoke, bhDealloc, OBJC_ASSOCIATION_RETAIN);
        self.mode = mode;
        self.hookBlock = hookBlock;
    }
    return self;
}

- (void)dealloc
{
    [self remove];
    if (_closure) {
        ffi_closure_free(_closure);
        _closure = NULL;
    }
}

- (BHToken *)next
{
    if (!_next) {
        BHDealloc *bhDealloc = objc_getAssociatedObject(self.block, self.originInvoke);
        _next = bhDealloc.token;
    }
    return _next;
}

- (BOOL)remove
{
    if (self.isStackBlock) {
        NSLog(@"Can't remove token for StackBlock!");
        return NO;
    }
    
    [self setBlockDeadCallback:nil];
    if (self.originInvoke) {
        if (self.block) {
            BHToken *current = [self.block block_currentHookToken];
            BHToken *last = nil;
            while (current) {
                if (current == self) {
                    if (last) { // remove middle token
                        last.originInvoke = self.originInvoke;
                        last.next = nil;
                    }
                    else { // remove head(current) token
                        BHInvokeLock *lock = [self.block invokeLock];
                        [lock lock];
                        ((__bridge struct _BHBlock *)self.block)->invoke = self.originInvoke;
                        [lock unlock];
                    }
                    break;
                }
                last = current;
                current = [current next];
            }
        }
        self.originInvoke = NULL;
        objc_setAssociatedObject(self.block, _replacementInvoke, nil, OBJC_ASSOCIATION_RETAIN);
        return YES;
    }
    return NO;
}

- (void)setHookBlock:(id)hookBlock
{
    _hookBlock = hookBlock;
    if (BlockHookModeDead == self.mode) {
        [self setBlockDeadCallback:hookBlock];
    }
}

- (void)setBlockDeadCallback:(BHDeadBlock)deadBlock
{
    if (self.isStackBlock) {
        NSLog(@"Can't set BlockDeadCallback for StackBlock!");
        return;
    }
    BHDealloc *bhDealloc = objc_getAssociatedObject(self.block, _replacementInvoke);
    bhDealloc.deadBlock = deadBlock;
}

- (NSString *)mangleName
{
    if (!_mangleName) {
        NSString *mangleName = self.next.mangleName;
        if (mangleName.length > 0) {
            _mangleName = mangleName;
        }
        else {
            Dl_info dlinfo;
            memset(&dlinfo, 0, sizeof(dlinfo));
            if (dladdr(self.originInvoke, &dlinfo))
            {
                _mangleName = [NSString stringWithUTF8String:dlinfo.dli_sname];
            }
        }
    }
    return _mangleName;
}

- (void)invokeOriginalBlockWithArgs:(void **)args retValue:(void *)retValue
{
    if (self.originInvoke) {
        ffi_call(&_cif, self.originInvoke, retValue, args);
    }
    else {
        NSLog(@"You had lost your originInvoke! Please check the order of removing tokens!");
    }
}

#pragma mark - Help Function

static const char *BHBlockTypeEncodeString(id blockObj)
{
    struct _BHBlock *block = (__bridge void *)blockObj;
    struct _BHBlockDescriptor *descriptor = block->descriptor;
    
    NSCAssert((block->flags & BLOCK_HAS_SIGNATURE) > 0, @"Block has no signature! Required ABI.2010.3.16");
    
    int index = 0;
    if (block->flags & BLOCK_HAS_COPY_DISPOSE) {
        index += 2;
    }
    
    return descriptor->rest[index];
}

static void BHFFIClosureFunc(ffi_cif *cif, void *ret, void **args, void *userdata)
{
    BHToken *token = (__bridge BHToken *)(userdata);
    void *userRet = ret;
    void **userArgs = args;
    if (token.hasStret) {
        // The first arg contains address of a pointer of returned struct.
        userRet = *((void **)args[0]);
        // Other args move backwards.
        userArgs = args + 1;
    }
    if (BlockHookModeBefore == token.mode) {
        [token invokeHookBlockWithArgs:userArgs retValue:userRet];
    }
    if (!(BlockHookModeInstead == token.mode && [token invokeHookBlockWithArgs:userArgs retValue:userRet])) {
        [token invokeOriginalBlockWithArgs:args retValue:ret];
    }
    if (BlockHookModeAfter == token.mode) {
        [token invokeHookBlockWithArgs:userArgs retValue:userRet];
    }
}

static const char *BHSizeAndAlignment(const char *str, NSUInteger *sizep, NSUInteger *alignp, long *lenp)
{
    const char *out = NSGetSizeAndAlignment(str, sizep, alignp);
    if (lenp) {
        *lenp = out - str;
    }
    while(*out == '}') {
        out++;
    }
    while(isdigit(*out)) {
        out++;
    }
    return out;
}

static int BHTypeCount(const char *str)
{
    int typeCount = 0;
    while(str && *str)
    {
        str = BHSizeAndAlignment(str, NULL, NULL, NULL);
        typeCount++;
    }
    return typeCount;
}

#pragma mark - Private Method

- (void *)_allocate:(size_t)howmuch
{
    NSMutableData *data = [NSMutableData dataWithLength:howmuch];
    [_allocations addObject: data];
    return [data mutableBytes];
}

- (ffi_type *)_ffiTypeForStructEncode:(const char *)str
{
    NSUInteger size, align;
    long length;
    BHSizeAndAlignment(str, &size, &align, &length);
    ffi_type *structType = [self _allocate:size];
    structType->type = FFI_TYPE_STRUCT;
    structType->size = size;
    structType->alignment = align;
    
    const char *temp = [[[NSString stringWithUTF8String:str] substringWithRange:NSMakeRange(0, length)] UTF8String];
    
    // cut "struct="
    while (temp && *temp && *temp != '=') {
        temp++;
    }
    ffi_type **elements = [self _typesWithEncodeString:temp + 1];
    if (!elements) {
        return nil;
    }
    structType->elements = elements;
    
    return structType;
}

- (ffi_type *)_ffiTypeForEncode:(const char *)str
{
    #define SINT(type) do { \
        if(str[0] == @encode(type)[0]) \
        { \
            if(sizeof(type) == 1) \
                return &ffi_type_sint8; \
            else if(sizeof(type) == 2) \
                return &ffi_type_sint16; \
            else if(sizeof(type) == 4) \
                return &ffi_type_sint32; \
            else if(sizeof(type) == 8) \
                return &ffi_type_sint64; \
            else \
            { \
                NSLog(@"Unknown size for type %s", #type); \
                abort(); \
            } \
        } \
    } while(0)
    
    #define UINT(type) do { \
        if(str[0] == @encode(type)[0]) \
        { \
            if(sizeof(type) == 1) \
                return &ffi_type_uint8; \
            else if(sizeof(type) == 2) \
                return &ffi_type_uint16; \
            else if(sizeof(type) == 4) \
                return &ffi_type_uint32; \
            else if(sizeof(type) == 8) \
                return &ffi_type_uint64; \
            else \
            { \
                NSLog(@"Unknown size for type %s", #type); \
                abort(); \
            } \
        } \
    } while(0)
    
    #define INT(type) do { \
        SINT(type); \
        UINT(unsigned type); \
    } while(0)
    
    #define COND(type, name) do { \
        if(str[0] == @encode(type)[0]) \
        return &ffi_type_ ## name; \
    } while(0)
    
    #define PTR(type) COND(type, pointer)
    
    SINT(_Bool);
    SINT(signed char);
    UINT(unsigned char);
    INT(short);
    INT(int);
    INT(long);
    INT(long long);
    
    PTR(id);
    PTR(Class);
    PTR(SEL);
    PTR(void *);
    PTR(char *);
    
    COND(float, float);
    COND(double, double);
    
    COND(void, void);
    
    // Ignore Method Encodings
    switch (*str) {
        case 'r':
        case 'R':
        case 'n':
        case 'N':
        case 'o':
        case 'O':
        case 'V':
            return [self _ffiTypeForEncode:str + 1];
    }
    
    // Struct Type Encodings
    if (*str == '{') {
        ffi_type *structType = [self _ffiTypeForStructEncode:str];
        return structType;
    }
    
    NSLog(@"Unknown encode string %s", str);
    return nil;
}

- (ffi_type **)_argsWithEncodeString:(const char *)str getCount:(int *)outCount
{
    // 第一个是返回值，需要排除
    return [self _typesWithEncodeString:str getCount:outCount startIndex:1];
}

- (ffi_type **)_typesWithEncodeString:(const char *)str
{
    return [self _typesWithEncodeString:str getCount:NULL startIndex:0];
}

- (ffi_type **)_typesWithEncodeString:(const char *)str getCount:(int *)outCount startIndex:(int)start
{
    int argCount = BHTypeCount(str) - start;
    ffi_type **argTypes = [self _allocate:argCount * sizeof(*argTypes)];
    
    int i = -start;
    while(str && *str)
    {
        const char *next = BHSizeAndAlignment(str, NULL, NULL, NULL);
        if (i >= 0 && i < argCount) {
            ffi_type *argType = [self _ffiTypeForEncode:str];
            if (argType) {
                argTypes[i] = argType;
            }
            else {
                if (outCount) {
                    *outCount = -1;
                }
                return nil;
            }
        }
        i++;
        str = next;
    }
    
    if (outCount) {
        *outCount = argCount;
    }
    
    return argTypes;
}

- (int)_prepCIF:(ffi_cif *)cif withEncodeString:(const char *)str
{
    int argCount;
    ffi_type **argTypes;
    ffi_type *returnType;
    struct _BHBlock *bh_block = (__bridge void *)self.block;
    if ((bh_block->flags & BLOCK_HAS_STRET)) {
        argTypes = [self _typesWithEncodeString:str getCount:&argCount startIndex:0];
        if (!argTypes) { // Error!
            return -1;
        }
        argTypes[0] = &ffi_type_pointer;
        returnType = &ffi_type_void;
        self.stret = YES;
        NSLog(@"Block has stret!");
    }
    else {
        argTypes = [self _argsWithEncodeString:str getCount:&argCount];
        if (!argTypes) { // Error!
            return -1;
        }
        returnType = [self _ffiTypeForEncode:str];
    }
    if (!returnType) { // Error!
        return -1;
    }
    ffi_status status = ffi_prep_cif(cif, FFI_DEFAULT_ABI, argCount, returnType, argTypes);
    if (status != FFI_OK) {
        NSLog(@"Got result %ld from ffi_prep_cif", (long)status);
        abort();
    }
    return argCount;
}

- (void)_prepClosure
{
    ffi_status status = ffi_prep_closure_loc(_closure, &_cif, BHFFIClosureFunc, (__bridge void *)(self), _replacementInvoke);
    if (status != FFI_OK) {
        NSLog(@"ffi_prep_closure returned %d", (int)status);
        abort();
    }
    // exchange invoke func imp
    BHInvokeLock *lock = [self.block invokeLock];
    [lock lock];
    self.originInvoke = ((__bridge struct _BHBlock *)self.block)->invoke;
    ((__bridge struct _BHBlock *)self.block)->invoke = _replacementInvoke;
    [lock unlock];
}

- (BOOL)invokeHookBlockWithArgs:(void **)args retValue:(void *)retValue
{
    if ((!self.isStackBlock && !self.block) || !self.hookBlock) {
        return NO;
    }
    NSMethodSignature *hookBlockSignature = [NSMethodSignature signatureWithObjCTypes:BHBlockTypeEncodeString(self.hookBlock)];
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:hookBlockSignature];
    
    // origin block invoke func arguments: block(self), ...
    // origin block invoke func arguments (x86 struct return): struct*, block(self), ...
    // hook block signature arguments: block(self), invocation, ...
    
    if (hookBlockSignature.numberOfArguments > self.numberOfArguments + 1) {
        NSLog(@"Block has too many arguments. Not calling %@", self);
        return NO;
    }
    
    BHInvocation *invocation = nil;
    if (hookBlockSignature.numberOfArguments > 1) {
        invocation = [BHInvocation new];
        invocation.args = args;
        invocation.retValue = retValue;
        invocation.token = self;
        [blockInvocation setArgument:(void *)&invocation atIndex:1];
    }
    
    void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < hookBlockSignature.numberOfArguments; idx++) {
        const char *type = [self.originalBlockSignature getArgumentTypeAtIndex:idx - 1];
        NSUInteger argSize;
        NSGetSizeAndAlignment(type, &argSize, NULL);
        
        if (!(argBuf = reallocf(argBuf, argSize))) {
            NSLog(@"Failed to allocate memory for block invocation.");
            return NO;
        }
        memcpy(argBuf, args[idx - 1], argSize);
        [blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    [blockInvocation invokeWithTarget:self.hookBlock];
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

@end

@implementation NSObject (BlockHook)

- (BOOL)block_checkValid
{
    BOOL valid = [self isKindOfClass:NSClassFromString(@"NSBlock")];
    if (!valid) {
        NSLog(@"Not Block!");
    }
    return valid;
}

- (BHToken *)block_hookWithMode:(BlockHookMode)mode
                     usingBlock:(id)block
{
    // __NSStackBlock__ -> __NSStackBlock -> NSBlock
    if (!block || ![self block_checkValid]) {
        return nil;
    }
    struct _BHBlock *bh_block = (__bridge void *)self;
    if (!(bh_block->flags & BLOCK_HAS_SIGNATURE)) {
        NSLog(@"Block has no signature! Required ABI.2010.3.16");
        return nil;
    }
    BHToken *token = [[BHToken alloc] initWithBlock:self mode:mode hookBlock:block];
    return token;
}

- (void)block_removeAllHook
{
    if (![self block_checkValid]) {
        return;
    }
    BHToken *token = nil;
    while ((token = [self block_currentHookToken])) {
        [token remove];
    }
}

- (BHToken *)block_currentHookToken
{
    if (![self block_checkValid]) {
        return nil;
    }
    void *invoke = [self block_currentInvokeFunction];
    BHDealloc *bhDealloc = objc_getAssociatedObject(self, invoke);
    return bhDealloc.token;
}

- (void *)block_currentInvokeFunction
{
    struct _BHBlock *bh_block = (__bridge void *)self;
    BHInvokeLock *lock = [self invokeLock];
    [lock lock];
    void *invoke = bh_block->invoke;
    [lock unlock];
    return invoke;
}

@end

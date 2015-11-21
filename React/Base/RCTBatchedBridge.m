/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

#import "RCTAssert.h"
#import "RCTBridge.h"
#import "RCTBridgeMethod.h"
#import "RCTConvert.h"
#import "RCTContextExecutor.h"
#import "RCTFrameUpdate.h"
#import "RCTJavaScriptLoader.h"
#import "RCTLog.h"
#import "RCTModuleData.h"
#import "RCTModuleMap.h"
#import "RCTPerformanceLogger.h"
#import "RCTProfile.h"
#import "RCTSourceCode.h"
#import "RCTUtils.h"


/*
  这个宏在这个文件里用来判断是否在js线程内执行.
  如果是 RCTContextExecutor来执行的 就不检查了 ??
  TODO
*/
#define RCTAssertJSThread() \
  RCTAssert(![NSStringFromClass([_javaScriptExecutor class]) isEqualToString:@"RCTContextExecutor"] || \
              [[[NSThread currentThread] name] isEqualToString:@"com.facebook.React.JavaScript"], \
            @"This method must be called on JS thread")

/*
 TODO  入队列 出队列 通知的  标记字符串 干什么用的
*/
NSString *const RCTEnqueueNotification = @"RCTEnqueueNotification";
NSString *const RCTDequeueNotification = @"RCTDequeueNotification";

/**
 * Must be kept in sync with `MessageQueue.js`.
 */
typedef NS_ENUM(NSUInteger, RCTBridgeFields) {
  RCTBridgeFieldRequestModuleIDs = 0,
  RCTBridgeFieldMethodIDs,
  RCTBridgeFieldParamss,
};

//获取所有的模块 类型
RCT_EXTERN NSArray<Class> *RCTGetModuleClasses(void);

//声明2个私有 静态方法
@interface RCTBridge ()

+ (instancetype)currentBridge;
+ (void)setCurrentBridge:(RCTBridge *)bridge;

@end


//声明 私有的bridge  实现对象. impl
@interface RCTBatchedBridge : RCTBridge

@property (nonatomic, weak) RCTBridge *parentBridge;

@end

@implementation RCTBatchedBridge
{
  BOOL _loading; 
  BOOL _valid;
  BOOL _wasBatchActive;
  // TODO js执行器. RCTJavaScriptExecutor 或者 RCTContextExecutor 类型
  //待看.
  __weak id<RCTJavaScriptExecutor> _javaScriptExecutor;
  
  //未调用的方法, 临时存放在这里. 当消息队列用.
  NSMutableArray<NSArray *> *_pendingCalls;

  //存储模块相关的信息,  下标就是模块ID
  NSMutableArray<RCTModuleData *> *_moduleDataByID;

  //模块map, 以名字为键值.
  RCTModuleMap *_modulesByName;

  //用来在每帧驱动js执行
  CADisplayLink *_jsDisplayLink;

  //监听帧事件的observers, 它们的类型是 RCTModuleData, 
  // 所以也就是 监听帧事件的 模块们
  // 每帧调用它们的didUpdateFrame,
  //传递一个 RCTFrameUpdate 
  NSMutableSet<RCTModuleData *> *_frameUpdateObservers;
}


//setup时候调用, 设置_parentBridge
//初始化
- (instancetype)initWithParentBridge:(RCTBridge *)bridge
{
  RCTAssertMainThread();
  RCTAssertParam(bridge);

  if ((self = [super initWithBundleURL:bridge.bundleURL
                        moduleProvider:bridge.moduleProvider
                         launchOptions:bridge.launchOptions])) {

    _parentBridge = bridge;

    /**
     * Set Initial State
     */
    _valid = YES;
    _loading = YES;
    _pendingCalls = [NSMutableArray new];
    _moduleDataByID = [NSMutableArray new];
    _frameUpdateObservers = [NSMutableSet new];
    _jsDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_jsThreadUpdate:)];

    //
    [RCTBridge setCurrentBridge:self];

    //产生一个通知RCTJavaScriptWillStartLoadingNotification 
    [[NSNotificationCenter defaultCenter] postNotificationName:RCTJavaScriptWillStartLoadingNotification
                                                        object:self
                                                      userInfo:@{ @"bridge": self }];
    //启动这个bridge
    [self start];
  }
  return self;
}

//
//  异步加载模块  加载模块代码 
//  injectJSONConfiguration把oc这边的模块定义创建到js那边
//  最后开始执行代码
//
- (void)start
{
  dispatch_queue_t bridgeQueue = dispatch_queue_create("com.facebook.react.RCTBridgeQueue", DISPATCH_QUEUE_CONCURRENT);

  dispatch_group_t initModulesAndLoadSource = dispatch_group_create();
  dispatch_group_enter(initModulesAndLoadSource);
  __weak RCTBatchedBridge *weakSelf = self;
  __block NSData *sourceCode;
  // 线程一.  加载代码, 需要在主线程上执行
  // 执行完后 脚本内容在sourceCode里
  [self loadSource:^(NSError *error, NSData *source) {
    if (error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopLoadingWithError:error];
      });
    } 
    sourceCode = source;
    dispatch_group_leave(initModulesAndLoadSource);
  }];
  // 线程二. 初始化本地模块
  // Synchronously initialize all native modules
  [self initModules];

  //性能监视相关 TODO
  if (RCTProfileIsProfiling()) {
    // Depends on moduleDataByID being loaded
    RCTProfileHookModules(self);
  }

  //  setupExecutor
  //  moduleConfig
  //  injectJSONConfiguration
  //
  //  全部完成后 执行
  //  executeSourceCode
  __block NSString *config;
  dispatch_group_enter(initModulesAndLoadSource);
  dispatch_async(bridgeQueue, ^{
    dispatch_group_t setupJSExecutorAndModuleConfig = dispatch_group_create();
    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      [weakSelf setupExecutor];
    });

    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      if (weakSelf.isValid) {
        RCTPerformanceLoggerStart(RCTPLNativeModulePrepareConfig);
        config = [weakSelf moduleConfig];
        RCTPerformanceLoggerEnd(RCTPLNativeModulePrepareConfig);
      }
    });

    dispatch_group_notify(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      // We're not waiting for this complete to leave the dispatch group, since
      // injectJSONConfiguration and executeSourceCode will schedule operations on the
      // same queue anyway.
      RCTPerformanceLoggerStart(RCTPLNativeModuleInjectConfig);
      [weakSelf injectJSONConfiguration:config onComplete:^(NSError *error) {
        RCTPerformanceLoggerEnd(RCTPLNativeModuleInjectConfig);
        if (error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stopLoadingWithError:error];
          });
        }
      }];
      dispatch_group_leave(initModulesAndLoadSource);
    });
  });
  //  执行sourceCode
  //
  dispatch_group_notify(initModulesAndLoadSource, dispatch_get_main_queue(), ^{
    RCTBatchedBridge *strongSelf = weakSelf;
    if (sourceCode && strongSelf.loading) {
      dispatch_async(bridgeQueue, ^{
        [weakSelf executeSourceCode:sourceCode];
      });
    }
  });
}


//
//  加载代码, 参数_onSourceLoad 是加载完毕的回调
//
- (void)loadSource:(RCTSourceLoadBlock)_onSourceLoad
{
  RCTPerformanceLoggerStart(RCTPLScriptDownload);
  NSUInteger cookie = RCTProfileBeginAsyncEvent(0, @"JavaScript download", nil);

  //先设置一个内部的代码加载完毕的回调,  拿到脚本内容后回调参数来的 _onSourceLoad 函数
  // 
  RCTSourceLoadBlock onSourceLoad = ^(NSError *error, NSData *source) {
    RCTProfileEndAsyncEvent(0, @"init,download", cookie, @"JavaScript download", nil);
    RCTPerformanceLoggerEnd(RCTPLScriptDownload);
    
     //新代码全删除了  我们这里先注释  后续也删
    // Only override the value of __DEV__ if running in debug mode, and if we
    // haven't explicitly overridden the packager dev setting in the bundleURL
    //BOOL shouldOverrideDev = RCT_DEBUG && ([self.bundleURL isFileURL] ||
    //[self.bundleURL.absoluteString rangeOfString:@"dev="].location == NSNotFound);

    // Force JS __DEV__ value to match RCT_DEBUG
    //if (shouldOverrideDev) {
    //  NSString *sourceString = [[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding];
    //  NSRange range = [sourceString rangeOfString:@"\\b__DEV__\\s*?=\\s*?(!1|!0|false|true)"
 //                                        options:NSRegularExpressionSearch];
//
  //    RCTAssert(range.location != NSNotFound, @"It looks like the implementation"
  //              "of __DEV__ has changed. Update -[RCTBatchedBridge loadSource:].");
//
      //修改__DEV__的内容
  //    NSString *valueString = [sourceString substringWithRange:range];
  //    if ([valueString rangeOfString:@"!1"].length) {
 //       valueString = [valueString stringByReplacingOccurrencesOfString:@"!1" withString:@"!0"];
 //     } else if ([valueString rangeOfString:@"false"].length) {
 //       valueString = [valueString stringByReplacingOccurrencesOfString:@"false" withString:@"true"];
 //     }
 //     source = [[sourceString stringByReplacingCharactersInRange:range withString:valueString]
 //               dataUsingEncoding:NSUTF8StringEncoding];
 //   }
    _onSourceLoad(error, source);
  };

  //  
  //  假如delegate实现了loadSourceForBridge:withBlock 就回调它, 参数是 onSourceLoad
  //  可以用来截获 如何加载代码
  //
  if ([self.delegate respondsToSelector:@selector(loadSourceForBridge:withBlock:)]) {
    //
    // 一般都是走这条路径, 看用户的appDelegate怎么写的, 一般没什么要求的话就和下面的elseif 流程代码一样
    //
    [self.delegate loadSourceForBridge:_parentBridge withBlock:onSourceLoad];
  } else if (self.bundleURL) {
    // 用我们自己的加载器 去加载代码
    [RCTJavaScriptLoader loadBundleAtURL:self.bundleURL onComplete:onSourceLoad];
  } else {
    // 这条路径 不会进来.
    // 如果没有self.bundleURL的话 简单回调相关函数.
    // 并通知RCTJavaScriptDidLoadNotification, 这个是在函数执行完毕 通知的.
    // Allow testing without a script
    dispatch_async(dispatch_get_main_queue(), ^{
      [self didFinishLoading];
      //RCTJavaScriptDidLoadNotification 这个事件会触发
      //RctRootView执行runApplication 进而执行js全局的AppRegistry.runApplication
      //但这条路径 不会进来
      [[NSNotificationCenter defaultCenter] postNotificationName:RCTJavaScriptDidLoadNotification
                                                          object:_parentBridge
                                                        userInfo:@{ @"bridge": self }];
    });
    onSourceLoad(nil, nil);
  }
}


//
//初始化模块,主线程
//
- (void)initModules
{
  RCTAssertMainThread();
  RCTPerformanceLoggerStart(RCTPLNativeModuleInit);

  // Register passed-in module instances
  NSMutableDictionary *preregisteredModules = [NSMutableDictionary new];

  //
  //如果 delegate有方法extraModulesForBridge 那就调用它
  // 得到额外的模块
  //或者 如果自己有self.moduleProvider方法  
  //  那就调用它  得到额外的方法
  //  这里都是要求它们自己已经new好了
  // 
  NSArray<id<RCTBridgeModule>> *extraModules = nil;
  if (self.delegate) {
    if ([self.delegate respondsToSelector:@selector(extraModulesForBridge:)]) {
      extraModules = [self.delegate extraModulesForBridge:_parentBridge];
    }
  } else if (self.moduleProvider) {
    extraModules = self.moduleProvider();
  }

  //把 RCTBridgeModule按类型名  放到preregisteredModules里
  for (id<RCTBridgeModule> module in extraModules) {
    preregisteredModules[RCTBridgeModuleNameForClass([module class])] = module;
  }

  //preregisteredModules  在这里已经是全部new好了的.

  // Instantiate modules
  _moduleDataByID = [NSMutableArray new];

  //预先注册的modulesByName
  NSMutableDictionary *modulesByName = [preregisteredModules mutableCopy];

  // 调用RCTGetModuleClasses拿到class, 
  // new一个 放到 modulesByName中 判断是否冲突, 如果有冲突就必须要求 第2个无法new出对象
  // 能new出对象 就报错
  //
  for (Class moduleClass in RCTGetModuleClasses()) {
    NSString *moduleName = RCTBridgeModuleNameForClass(moduleClass);

     // Check if module instance has already been registered for this name
     id<RCTBridgeModule> module = modulesByName[moduleName];

     if (module) {
       // Preregistered instances takes precedence, no questions asked
       if (!preregisteredModules[moduleName]) {
         // It's OK to have a name collision as long as the second instance is nil
         RCTAssert([moduleClass new] == nil,
                   @"Attempted to register RCTBridgeModule class %@ for the name "
                   "'%@', but name was already registered by class %@", moduleClass,
                   moduleName, [modulesByName[moduleName] class]);
       }
     } else {
       // Module name hasn't been used before, so go ahead and instantiate
       module = [moduleClass new];
     }
     if (module) {
       modulesByName[moduleName] = module;
     }
  }

  //把 模块 都放在 RCTModuleMap里
  // Store modules
  _modulesByName = [[RCTModuleMap alloc] initWithDictionary:modulesByName];

  /**
   * The executor is a bridge module, wait for it to be created and set it before
   * any other module has access to the bridge
   */
  //
  //  _javaScriptExecutor 也是作为一种模块的, 类型是executorClass
  //
  _javaScriptExecutor = _modulesByName[RCTBridgeModuleNameForClass(self.executorClass)];

  //如果这些模块有setBridge方法, 那么全部设置为自己.
  for (id<RCTBridgeModule> module in _modulesByName.allValues) {
    // Bridge must be set before moduleData is set up, as methodQueue
    // initialization requires it (View Managers get their queue by calling
    // self.bridge.uiManager.methodQueue)
    if ([module respondsToSelector:@selector(setBridge:)]) {
      module.bridge = self;
    }

    //为这些模块创建 RCTModuleData,并放到_moduleDataByID里,模块id就是_moduleDataByID的下标
    RCTModuleData *moduleData = [[RCTModuleData alloc] initWithExecutor:_javaScriptExecutor
                                                               moduleID:@(_moduleDataByID.count)
                                                               instance:module];
    [_moduleDataByID addObject:moduleData];
  }
  //产生通知 RCTDidCreateNativeModules
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTDidCreateNativeModules
                                                      object:self];
  //完成RCTPLNativeModuleInit的性能统计
  RCTPerformanceLoggerEnd(RCTPLNativeModuleInit);
}

- (void)setupExecutor
{
  [_javaScriptExecutor setUp];
}


//
//  将模块的配置串, 这个串的内容是模块的名字和它的常量属性和所有的方法
//   加起来,然后序列化
//  然后根据模块对象是否符合RCTFrameUpdateObserver的协议  
//  把它们的moduleData 加到 _frameUpdateObservers
//  并给他们设置一个pauseCallback函数(这个猜想在pause时会被调用), 内容是通知bridge更新下暂停状态.
//  (其实这个在下一帧遍历 检查时 也可以直白的设置的... 反正目前是这样实现 可能是更有道理吧)
// 
- (NSString *)moduleConfig
{
  NSMutableArray<NSArray *> *config = [NSMutableArray new];
  for (RCTModuleData *moduleData in _moduleDataByID) {
    [config addObject:moduleData.config];
    if ([moduleData.instance conformsToProtocol:@protocol(RCTFrameUpdateObserver)]) {
      [_frameUpdateObservers addObject:moduleData];
      id<RCTFrameUpdateObserver> observer = (id<RCTFrameUpdateObserver>)moduleData.instance;
      __weak typeof(self) weakSelf = self;
      __weak typeof(_javaScriptExecutor) weakJavaScriptExecutor = _javaScriptExecutor;
      observer.pauseCallback = ^{
        [weakJavaScriptExecutor executeBlockOnJavaScriptQueue:^{
          [weakSelf updateJSDisplayLinkState];
        }];
      };
    }
  }

  return RCTJSONStringify(@{
    @"remoteModuleConfig": config,
  }, NULL);
}

// 
// 如果所有模块都被暂停了.那就把
// _jsDisplayLink.paused设置为true
//
- (void)updateJSDisplayLinkState
{
  RCTAssertJSThread();

  BOOL pauseDisplayLink = YES;
  for (RCTModuleData *moduleData in _frameUpdateObservers) {
    id<RCTFrameUpdateObserver> observer = (id<RCTFrameUpdateObserver>)moduleData.instance;
    if (!observer.paused) {
      pauseDisplayLink = NO;
      break;
    }
  }
  _jsDisplayLink.paused = pauseDisplayLink;
}

//
// 调用_javaScriptExecutor的injectJSONText 执行js层  模块对象的注册工作
//   __fbBatchedBridgeConfig 
//
//
- (void)injectJSONConfiguration:(NSString *)configJSON
                     onComplete:(void (^)(NSError *))onComplete
{
  if (!self.valid) {
    return;
  }

  [_javaScriptExecutor injectJSONText:configJSON
                  asGlobalObjectNamed:@"__fbBatchedBridgeConfig"
                             callback:onComplete];
}

//
//  执行js源代码
//
- (void)executeSourceCode:(NSData *)sourceCode
{
  if (!self.valid || !_javaScriptExecutor) {
    return;
  }
  // 
  // self.modules就是 _moduleNames的访问器
  // 查看是否有RCTSourceCode 模块,如果有 设置 scriptURL,scriptData
  // 
  RCTSourceCode *sourceCodeModule = self.modules[RCTBridgeModuleNameForClass([RCTSourceCode class])];
  sourceCodeModule.scriptURL = self.bundleURL;
  sourceCodeModule.scriptData = sourceCode;

  // 加到执行队列里
  [self enqueueApplicationScript:sourceCode url:self.bundleURL onComplete:^(NSError *loadError) {
    if (!self.isValid) {
      return;
    }

    if (loadError) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self stopLoadingWithError:loadError];
      });
      return;
    }

    //开始 注册 _jsDisplayLink的调用了.
    // Register the display link to start sending js calls after everything is setup
    NSRunLoop *targetRunLoop = [_javaScriptExecutor isKindOfClass:[RCTContextExecutor class]] ? [NSRunLoop currentRunLoop] : [NSRunLoop mainRunLoop];
    [_jsDisplayLink addToRunLoop:targetRunLoop forMode:NSRunLoopCommonModes];

    // 通知执行完毕 
    // Perform the state update and notification on the main thread, so we can't run into
    // timing issues with RCTRootView
    dispatch_async(dispatch_get_main_queue(), ^{
      [self didFinishLoading];
      //
      //  一般 用户自己写的js执行  都会调用 AppRegistry:registerComponent()
      //   
      // RCTJavaScriptDidLoadNotification 这个事件会触发
      //RctRootView执行runApplication 进而执行js全局的AppRegistry.runApplication  
      [[NSNotificationCenter defaultCenter] postNotificationName:RCTJavaScriptDidLoadNotification
                                                          object:_parentBridge
                                                        userInfo:@{ @"bridge": self }];
    });
  }];
}

//
// 执行完毕后, 把之前暂缓的那些call都拿出来调用一下.
//
- (void)didFinishLoading
{
  _loading = NO;
  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    for (NSArray *call in _pendingCalls) {
      [self _actuallyInvokeAndProcessModule:call[0]
                                     method:call[1]
                                  arguments:call[2]];
    }
  }];
}

- (void)stopLoadingWithError:(NSError *)error
{
  RCTAssertMainThread();

  if (!self.isValid || !self.loading) {
    return;
  }

  _loading = NO;

  [[NSNotificationCenter defaultCenter] postNotificationName:RCTJavaScriptDidFailToLoadNotification
                                                      object:_parentBridge
                                                    userInfo:@{@"bridge": self, @"error": error}];
  RCTFatal(error);
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithBundleURL:(__unused NSURL *)bundleURL
                    moduleProvider:(__unused RCTBridgeModuleProviderBlock)block
                    launchOptions:(__unused NSDictionary *)launchOptions)



//
// 这两个bridge的关系得好好清理一下..TODO 这里是避免  RCTBridge和RCTBatchedBridge循环调用
/**
 * Prevent super from calling setUp (that'd create another batchedBridge)
 */
- (void)setUp {}
- (void)bindKeys {}

- (void)reload
{
  [_parentBridge reload];
}

- (Class)executorClass
{
  return _parentBridge.executorClass ?: [RCTContextExecutor class];
}


// 没有地方调用这个函数暂时
- (void)setExecutorClass:(Class)executorClass
{
  RCTAssertMainThread();

  _parentBridge.executorClass = executorClass;
}

- (NSURL *)bundleURL
{
  return _parentBridge.bundleURL;
}

- (void)setBundleURL:(NSURL *)bundleURL
{
  _parentBridge.bundleURL = bundleURL;
}

- (id<RCTBridgeDelegate>)delegate
{
  return _parentBridge.delegate;
}

- (BOOL)isLoading
{
  return _loading;
}

- (BOOL)isValid
{
  return _valid;
}

- (NSDictionary *)modules
{
  if (RCT_DEBUG && self.isValid && _modulesByName == nil) {
    RCTLogError(@"Bridge modules have not yet been initialized. You may be "
                "trying to access a module too early in the startup procedure.");
  }
  return _modulesByName;
}

#pragma mark - RCTInvalidating
//
// 
//  注销bridge, 
//  对外bridge对象 reload 和 析构时候调用  impl的invalidate
//
- (void)invalidate
{
  if (!self.valid) {
    return;
  }

  RCTAssertMainThread();

  _loading = NO;
  _valid = NO;
  if ([RCTBridge currentBridge] == self) {
    [RCTBridge setCurrentBridge:nil];
  }

  //依次调用模块的invalidate()
  // Invalidate modules
  dispatch_group_t group = dispatch_group_create();
  for (RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.instance == _javaScriptExecutor) {
      continue;
    }

    if ([moduleData.instance respondsToSelector:@selector(invalidate)]) {
      [moduleData dispatchBlock:^{
        [(id<RCTInvalidating>)moduleData.instance invalidate];
      } dispatchGroup:group];
    }
    moduleData.queue = nil;
  }

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
      [_jsDisplayLink invalidate];
      _jsDisplayLink = nil;

      [_javaScriptExecutor invalidate];
      _javaScriptExecutor = nil;

      if (RCTProfileIsProfiling()) {
        RCTProfileUnhookModules(self);
      }
      _moduleDataByID = nil;
      _modulesByName = nil;
      _frameUpdateObservers = nil;

    }];
  });
}

//
// RCTLog.logIfNoNativeHook
//
- (void)logMessage:(NSString *)message level:(NSString *)level
{
  if (RCT_DEBUG) {
    [_javaScriptExecutor executeJSCall:@"RCTLog"
                                method:@"logIfNoNativeHook"
                             arguments:@[level, message]
                              callback:^(__unused id json, __unused NSError *error) {}];
  }
}

#pragma mark - RCTBridge methods


//
//  基本都是通过这个函数来调用的. 也有直接调用 _invokeAndProcessModule的
//
// 执行JS调用  实际是通过 _invokeAndProcessModule来执行 BatchedBridge模块的callFunctionReturnFlushedQueue
//
/**
 * Public. Can be invoked from any thread.
 */
- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
  NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];

  [self _invokeAndProcessModule:@"BatchedBridge"
                         method:@"callFunctionReturnFlushedQueue"
                      arguments:@[ids[0], ids[1], args ?: @[]]];
}

/**
 * Private hack to support `setTimeout(fn, 0)`
 */
- (void)_immediatelyCallTimer:(NSNumber *)timer
{
  RCTAssertJSThread();

  dispatch_block_t block = ^{
    [self _actuallyInvokeAndProcessModule:@"BatchedBridge"
                                   method:@"callFunctionReturnFlushedQueue"
                                arguments:@[@"JSTimersExecution", @"callTimers", @[@[timer]]]];
  };
  //TODO
  //executeAsyncBlockOnJavaScriptQueue executeBlockOnJavaScriptQueue 区别
  //
  if ([_javaScriptExecutor respondsToSelector:@selector(executeAsyncBlockOnJavaScriptQueue:)]) {
    [_javaScriptExecutor executeAsyncBlockOnJavaScriptQueue:block];
  } else {
    [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
  }
}

//
//  这个函数 似乎 就启动时候 执行一次?
//
//  交给_javaScriptExecutor的executeApplicationScript执行 脚本代码
//  执行完后 
//  再调用 _javaScriptExecutor的executeJSCall执行 js代码的 BatchedBridge.flushedQueue
//  然后调用 handleBuffer() 来执行oc模块的方法
//  然后回调 调用者的callback
//
- (void)enqueueApplicationScript:(NSData *)script
                             url:(NSURL *)url
                      onComplete:(RCTJavaScriptCompleteBlock)onComplete
{
  RCTAssert(onComplete != nil, @"onComplete block passed in should be non-nil");

  RCTProfileBeginFlowEvent();

  [_javaScriptExecutor executeApplicationScript:script sourceURL:url onComplete:^(NSError *scriptLoadError) {
    RCTProfileEndFlowEvent();
    RCTAssertJSThread();

    if (scriptLoadError) {
      onComplete(scriptLoadError);
      return;
    }

    RCT_PROFILE_BEGIN_EVENT(0, @"FetchApplicationScriptCallbacks", nil);
    [_javaScriptExecutor executeJSCall:@"BatchedBridge"
                                method:@"flushedQueue"
                             arguments:@[]
                              callback:^(id json, NSError *error)
     {
       RCT_PROFILE_END_EVENT(0, @"js_call,init", @{
         @"json": RCTNullIfNil(json),
         @"error": RCTNullIfNil(error),
       });

       [self handleBuffer:json batchEnded:YES];

       onComplete(error);
     }];
  }];
}

#pragma mark - Payload Generation

/**
 * Called by enqueueJSCall from any thread, or from _immediatelyCallTimer,
 * on the JS thread, but only in non-batched mode.
 */
 //
 // 交给_javaScriptExecutor放在js执行线程上 执行 _actuallyInvokeAndProcessModule
 //  如果还在加载期 则放到 _pendingCalls里.
 //
- (void)_invokeAndProcessModule:(NSString *)module method:(NSString *)method arguments:(NSArray *)args
{
  /**
   * AnyThread
   */

  RCTProfileBeginFlowEvent();

  __weak RCTBatchedBridge *weakSelf = self;
  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    RCTProfileEndFlowEvent();

    RCTBatchedBridge *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.valid) {
      return;
    }

    if (strongSelf.loading) {
      [strongSelf->_pendingCalls addObject:@[module, method, args]];
    } else {
      [strongSelf _actuallyInvokeAndProcessModule:module method:method arguments:args];
    }
  }];
}
//  TODO js线程 和 主线程的分工设计 还需要好好整理下
//  实际就是执行_javaScriptExecutor的executeJSCall,
//
- (void)_actuallyInvokeAndProcessModule:(NSString *)module
                                 method:(NSString *)method
                              arguments:(NSArray *)args
{
  RCTAssertJSThread();

  [[NSNotificationCenter defaultCenter] postNotificationName:RCTEnqueueNotification object:nil userInfo:nil];

  RCTJavaScriptCallback processResponse = ^(id json, NSError *error) {
    if (error) {
      RCTFatal(error);
    }

    if (!self.isValid) {
      return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RCTDequeueNotification object:nil userInfo:nil];
    [self handleBuffer:json batchEnded:YES];
  };

  [_javaScriptExecutor executeJSCall:module
                              method:method
                           arguments:args
                            callback:processResponse];
}

#pragma mark - Payload Processing

//
// FixME 这个函数干啥的啊.
//
//
- (void)handleBuffer:(id)buffer batchEnded:(BOOL)batchEnded
{
  RCTAssertJSThread();

  if (buffer != nil && buffer != (id)kCFNull) {
    _wasBatchActive = YES;
    [self handleBuffer:buffer];
  }

  if (batchEnded) {
    if (_wasBatchActive) {
      [self batchDidComplete];
    }

    _wasBatchActive = NO;
  }
}

//
//RCTConvert是用来转换json和本地对象的
//
//
- (void)handleBuffer:(NSArray<NSArray *> *)buffer
{
  NSArray<NSArray *> *requestsArray = [RCTConvert NSArrayArray:buffer];
  // ???  这个数组  0, 1, 2 分别是模块Id, 方法id ,参数串 
  if (RCT_DEBUG && requestsArray.count <= RCTBridgeFieldParamss) {
    RCTLogError(@"Buffer should contain at least %tu sub-arrays. Only found %tu",
                RCTBridgeFieldParamss + 1, requestsArray.count);
    return;
  }

  NSArray<NSNumber *> *moduleIDs = requestsArray[RCTBridgeFieldRequestModuleIDs];
  NSArray<NSNumber *> *methodIDs = requestsArray[RCTBridgeFieldMethodIDs];
  NSArray<NSArray *> *paramsArrays = requestsArray[RCTBridgeFieldParamss];

  if (RCT_DEBUG && (moduleIDs.count != methodIDs.count || moduleIDs.count != paramsArrays.count)) {
    RCTLogError(@"Invalid data message - all must be length: %zd", moduleIDs.count);
    return;
  }

  NSMapTable *buckets = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                                  valueOptions:NSPointerFunctionsStrongMemory
                                                      capacity:_moduleDataByID.count];

  [moduleIDs enumerateObjectsUsingBlock:^(NSNumber *moduleID, NSUInteger i, __unused BOOL *stop) {
    RCTModuleData *moduleData = _moduleDataByID[moduleID.integerValue];
    if (RCT_DEBUG) {
      // verify that class has been registered
      (void)_modulesByName[moduleData.name];
    }
    //
    //moduleData.queue 返回 methodQueue设置的queue 一般就是主线程
    // 没设置的话, com.facebook.React.模块名
    //
    dispatch_queue_t queue = moduleData.queue;
    //buckets每个模块的queue为键, 值为该queue的模块id组成的set 
    // buckets 是 queue => set{}
    NSMutableOrderedSet<NSNumber *> *set = [buckets objectForKey:queue];
    if (!set) {
      set = [NSMutableOrderedSet new];
      [buckets setObject:set forKey:queue];
    }
    [set addObject:@(i)];
  }];

  // 然后遍历这些queue,  执行 _handleRequestNumber 传递这些参数
  //    用 autoreleasepool 是因为? 怕产生太多了
  // 
  //  如果就是RCTJSThread  用_javaScriptExecutor的executeBlockOnJavaScriptQueue执行
  //  否则 dispatch_async(queue  执行
  //
  for (dispatch_queue_t queue in buckets) {
    RCTProfileBeginFlowEvent();

    dispatch_block_t block = ^{
      RCTProfileEndFlowEvent();

#if RCT_DEV
      NSString *_threadName = RCTCurrentThreadName();
      RCT_PROFILE_BEGIN_EVENT(0, _threadName, nil);
#endif

      NSOrderedSet *calls = [buckets objectForKey:queue];
      @autoreleasepool {
        for (NSNumber *indexObj in calls) {
          NSUInteger index = indexObj.unsignedIntegerValue;
          [self _handleRequestNumber:index
                            moduleID:[moduleIDs[index] integerValue]
                            methodID:[methodIDs[index] integerValue]
                              params:paramsArrays[index]];
        }
      }

      RCT_PROFILE_END_EVENT(0, @"objc_call,dispatch_async", @{
        @"calls": @(calls.count),
      });
    };

    if (queue == RCTJSThread) {
      [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
    } else if (queue) {
      dispatch_async(queue, block);
    }
  }
}

//
//
//
- (void)batchDidComplete
{
  // TODO: batchDidComplete is only used by RCTUIManager - can we eliminate this special case?
  for (RCTModuleData *moduleData in _moduleDataByID) {
    if ([moduleData.instance respondsToSelector:@selector(batchDidComplete)]) {
      [moduleData dispatchBlock:^{
        [moduleData.instance batchDidComplete];
      }];
    }
  }
}
//  
//  执行js  回调我们oc的方法
// 执行 RCTBridgeMethod的invokeWithBridge
//
- (BOOL)_handleRequestNumber:(NSUInteger)i
                    moduleID:(NSUInteger)moduleID
                    methodID:(NSUInteger)methodID
                      params:(NSArray *)params
{
  if (!self.isValid) {
    return NO;
  }

  if (RCT_DEBUG && ![params isKindOfClass:[NSArray class]]) {
    RCTLogError(@"Invalid module/method/params tuple for request #%zd", i);
    return NO;
  }

  RCTModuleData *moduleData = _moduleDataByID[moduleID];
  if (RCT_DEBUG && !moduleData) {
    RCTLogError(@"No module found for id '%zd'", moduleID);
    return NO;
  }

  id<RCTBridgeMethod> method = moduleData.methods[methodID];
  if (RCT_DEBUG && !method) {
    RCTLogError(@"Unknown methodID: %zd for module: %zd (%@)", methodID, moduleID, moduleData.name);
    return NO;
  }

  RCT_PROFILE_BEGIN_EVENT(0, [NSString stringWithFormat:@"[%@ %@]", moduleData.name, method.JSMethodName], nil);

  @try {
    [method invokeWithBridge:self module:moduleData.instance arguments:params];
  }
  @catch (NSException *exception) {
    // Pass on JS exceptions
    if ([exception.name isEqualToString:RCTFatalExceptionName]) {
      @throw exception;
    }

    NSString *message = [NSString stringWithFormat:
                         @"Exception thrown while invoking %@ on target %@ with params %@: %@",
                         method.JSMethodName, moduleData.name, params, exception];
    RCTFatal(RCTErrorWithMessage(message));
  }

  if (RCTProfileIsProfiling()) {
    NSMutableDictionary *args = [method.profileArgs mutableCopy];
    args[@"method"] = method.JSMethodName;
    args[@"args"] = RCTJSONStringify(RCTNullIfNil(params), NULL);
    RCT_PROFILE_END_EVENT(0, @"objc_call", args);
  }

  return YES;
}

//
// 每帧注册的回调, 调用模块的didUpdateFrame
//
- (void)_jsThreadUpdate:(CADisplayLink *)displayLink
{
  RCTAssertJSThread();
  RCT_PROFILE_BEGIN_EVENT(0, @"DispatchFrameUpdate", nil);

  RCTFrameUpdate *frameUpdate = [[RCTFrameUpdate alloc] initWithDisplayLink:displayLink];
  for (RCTModuleData *moduleData in _frameUpdateObservers) {
    id<RCTFrameUpdateObserver> observer = (id<RCTFrameUpdateObserver>)moduleData.instance;
    if (!observer.paused) {
      RCT_IF_DEV(NSString *name = [NSString stringWithFormat:@"[%@ didUpdateFrame:%f]", observer, displayLink.timestamp];)
      RCTProfileBeginFlowEvent();

      [moduleData dispatchBlock:^{
        RCTProfileEndFlowEvent();
        RCT_PROFILE_BEGIN_EVENT(0, name, nil);
        [observer didUpdateFrame:frameUpdate];
        RCT_PROFILE_END_EVENT(0, @"objc_call,fps", nil);
      }];
    }
  }

  [self updateJSDisplayLinkState];


  RCTProfileImmediateEvent(0, @"JS Thread Tick", 'g');

  RCT_PROFILE_END_EVENT(0, @"objc_call", nil);
}

- (void)startProfiling
{
  RCTAssertMainThread();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    RCTProfileInit(self);
  }];
}

- (void)stopProfiling:(void (^)(NSData *))callback
{
  RCTAssertMainThread();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    RCTProfileEnd(self, ^(NSString *log) {
      NSData *logData = [log dataUsingEncoding:NSUTF8StringEncoding];
      callback(logData);
    });
  }];
}

@end

/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

//
//  这样写 目的是为了 支持A,B也可以是宏. TODO 找出例子 理解一下.
//
#define _CONCAT(A, B) A##B
#define CONCAT(A, B) _CONCAT(A, B)

#define SYMBOL_NAME(S) CONCAT(__USER_LABEL_PREFIX__, S)

// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:build_runner/build_runner.dart';
import 'package:build/build.dart';

class RunnerAssetWriterSpy extends AssetWriterSpy implements RunnerAssetWriter {
  final RunnerAssetWriter _delegate;

  final _assetsDeleted = new Set<AssetId>();
  Iterable<AssetId> get assetsDeleted => _assetsDeleted;

  RunnerAssetWriterSpy(this._delegate) : super(_delegate);

  @override
  Future delete(AssetId id) {
    _assetsDeleted.add(id);
    return _delegate.delete(id);
  }
}

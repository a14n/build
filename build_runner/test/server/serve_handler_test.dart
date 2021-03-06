// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:build/build.dart';
import 'package:build_runner/build_runner.dart';
import 'package:build_runner/src/asset_graph/graph.dart';
import 'package:build_runner/src/generate/build_result.dart';
import 'package:build_runner/src/generate/performance_tracker.dart';
import 'package:build_runner/src/generate/watch_impl.dart';
import 'package:build_runner/src/server/server.dart';

import '../common/common.dart';
import '../common/package_graphs.dart';

void main() {
  ServeHandler serveHandler;
  InMemoryRunnerAssetReader reader;
  MockWatchImpl watchImpl;

  setUp(() async {
    reader = new InMemoryRunnerAssetReader();
    final packageGraph = buildPackageGraph({rootPackage('a'): []});
    watchImpl = new MockWatchImpl(reader, packageGraph);
    serveHandler = await createServeHandler(watchImpl);
    watchImpl.addFutureResult(
        new Future.value(new BuildResult(BuildStatus.success, [])));
  });

  test('can get handlers for a subdirectory', () async {
    reader.cacheStringAsset(makeAssetId('a|web/index.html'), 'content');
    var response = await serveHandler.handlerFor('web')(
        new Request('GET', Uri.parse('http://server.com/index.html')));
    expect(await response.readAsString(), 'content');
  });

  test('caching with etags works', () async {
    reader.cacheStringAsset(makeAssetId('a|web/index.html'), 'content');
    var handler = serveHandler.handlerFor('web');
    var requestUri = Uri.parse('http://server.com/index.html');
    var firstResponse = await handler(new Request('GET', requestUri));
    var etag = firstResponse.headers[HttpHeaders.ETAG];
    expect(etag, isNotNull);
    expect(firstResponse.statusCode, HttpStatus.OK);
    expect(await firstResponse.readAsString(), 'content');

    var cachedResponse = await handler(new Request('GET', requestUri,
        headers: {HttpHeaders.IF_NONE_MATCH: etag}));
    expect(cachedResponse.statusCode, HttpStatus.NOT_MODIFIED);
    expect(await cachedResponse.readAsString(), isEmpty);
  });

  test('throws if you pass a non-root directory', () {
    expect(() => serveHandler.handlerFor('web/sub'), throwsArgumentError);
  });

  test('serves an error page if there were build errors', () async {
    var fakeException = 'Really bad error omg!';
    var fakeStackTrace = 'My cool stack trace!';
    watchImpl.addFutureResult(new Future.value(new BuildResult(
        BuildStatus.failure, [],
        exception: fakeException,
        stackTrace: new StackTrace.fromString(fakeStackTrace))));
    await new Future.value();
    var response = await serveHandler.handlerFor('web')(
        new Request('GET', Uri.parse('http://server.com/index.html')));

    expect(response.statusCode, HttpStatus.INTERNAL_SERVER_ERROR);
    expect(
        await response.readAsString(),
        allOf(contains('Really&nbsp;bad&nbsp;error&nbsp;omg!'),
            contains('My&nbsp;cool&nbsp;stack&nbsp;trace!')));
  });

  test('logs requests if you ask it to', () async {
    reader.cacheStringAsset(makeAssetId('a|web/index.html'), 'content');
    expect(
        Logger.root.onRecord,
        emitsThrough(predicate<LogRecord>((record) =>
            record.message.contains('index.html') &&
            record.level == Level.INFO)));
    await serveHandler.handlerFor('web', logRequests: true)(
        new Request('GET', Uri.parse('http://server.com/index.html')));

    var fakeException = 'Really bad error omg!';
    var fakeStackTrace = 'My cool stack trace!';
    watchImpl.addFutureResult(new Future.value(new BuildResult(
        BuildStatus.failure, [],
        exception: fakeException,
        stackTrace: new StackTrace.fromString(fakeStackTrace))));

    expect(
        Logger.root.onRecord,
        emitsThrough(predicate<LogRecord>((record) =>
            record.message.contains('index.html') &&
            record.level == Level.WARNING)));
    await serveHandler.handlerFor('web', logRequests: true)(
        new Request('GET', Uri.parse('http://server.com/index.html')));
  });

  group(r'/$perf', () {
    test('serves some sort of page if enabled', () async {
      var tracker = new BuildPerformanceTracker()..start();
      var actionTracker = tracker.startBuilderAction(
          makeAssetId('a|web/a.txt'), new TestBuilder());
      actionTracker.track(() {}, 'SomeLabel');
      tracker.stop();
      actionTracker.stop();
      watchImpl.addFutureResult(new Future.value(
          new BuildResult(BuildStatus.success, [], performance: tracker)));
      await new Future.value();
      var response = await serveHandler.handlerFor('web')(
          new Request('GET', Uri.parse(r'http://server.com/$perf')));

      expect(response.statusCode, HttpStatus.OK);
      expect(await response.readAsString(),
          allOf(contains('TestBuilder:a|web/a.txt'), contains('SomeLabel')));
    });

    test('serves an error page if not enabled', () async {
      watchImpl.addFutureResult(new Future.value(new BuildResult(
          BuildStatus.success, [],
          performance: new BuildPerformanceTracker.noOp())));
      await new Future.value();
      var response = await serveHandler.handlerFor('web')(
          new Request('GET', Uri.parse(r'http://server.com/$perf')));

      expect(response.statusCode, HttpStatus.OK);
      expect(await response.readAsString(), contains('--track-performance'));
    });
  });
}

class MockWatchImpl implements WatchImpl {
  @override
  final AssetGraph assetGraph = null;

  Future<BuildResult> _currentBuild;
  @override
  Future<BuildResult> get currentBuild => _currentBuild;
  @override
  set currentBuild(newValue) => throw new UnsupportedError('unsupported!');

  final _futureBuildResultsController =
      new StreamController<Future<BuildResult>>();
  final _buildResultsController = new StreamController<BuildResult>();

  @override
  get buildResults => _buildResultsController.stream;
  @override
  set buildResults(_) => throw new UnsupportedError('unsupported!');

  @override
  final PackageGraph packageGraph;

  @override
  final Future<AssetReader> reader;

  void addFutureResult(Future<BuildResult> result) {
    _futureBuildResultsController.add(result);
  }

  MockWatchImpl(AssetReader reader, this.packageGraph)
      : this.reader = new Future.value(reader) {
    _futureBuildResultsController.stream.listen((futureBuildResult) {
      if (_currentBuild != null) {
        _currentBuild = _currentBuild.then((_) => futureBuildResult);
      } else {
        _currentBuild = futureBuildResult;
      }

      _currentBuild.then((result) {
        _buildResultsController.add(result);
        _currentBuild = null;
      });
    });
  }
}

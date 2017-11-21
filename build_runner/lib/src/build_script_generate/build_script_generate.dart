// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;

import 'package:build_config/build_config.dart';
import 'package:build_runner/build_runner.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:logging/logging.dart';

import '../logging/logging.dart';
import '../util/constants.dart';
import 'types.dart' as types;

const scriptLocation = '$entryPointDir/build.dart';

Future<Null> ensureBuildScript() async {
  var log = new Logger('ensureBuildScript');
  var scriptFile = new io.File(scriptLocation);
  // TODO - how can we invalidate this?
  //if (scriptFile.existsSync()) return;
  scriptFile.createSync(recursive: true);
  await logTimedAsync(log, 'Generating build script',
      () async => scriptFile.writeAsString(await _generateBuildScript()));
}

Future<String> _generateBuildScript() async {
  var packageGraph = new PackageGraph.forThisPackage();
  var builderDefinitions =
      (await Future.wait(packageGraph.orderedPackages.map(_packageBuildConfig)))
          .expand((c) => c.builderDefinitions.values)
          .where((c) => c.autoApply);
  final library = new File(
      (b) => b.body.addAll([_findBuildActions(builderDefinitions), _main()]));
  final emitter = new DartEmitter(new Allocator.simplePrefixing());
  return new DartFormatter().format('${library.accept(emitter)}');
}

Method _findBuildActions(Iterable<BuilderDefinition> builderDefinitions) =>
    new Method((b) => b
      ..name = '_buildActions'
      ..requiredParameters.add(new Parameter((b) => b
        ..name = 'packageGraph'
        ..type = types.packageGraph))
      ..returns = types.buildActions
      ..body = new Block((b) => b
        ..statements.addAll([
          // TODO - Pass actual arguments
          literalList([], new TypeReference((b) => b..symbol = 'String'))
              .assignVar('args')
              .statement,
          _findBuilders(builderDefinitions).assignVar('builders').statement,
          refer('createBuildActions', 'package:build_runner/build_runner.dart')
              .call([refer('packageGraph'), refer('builders')],
                  {'args': refer('args')})
              .returned
              .statement,
        ])));

Method _main() => new Method((b) => b
  ..name = 'main'
  ..modifier = MethodModifier.async
  ..body = new Block((b) => b
    ..statements.addAll([
      refer('_buildActions')
          .call([types.packageGraph.newInstanceNamed('forThisPackage', [])])
          .assignVar('actions')
          .statement,
      refer('watch', 'package:build_runner/build_runner.dart')
          .call([refer('actions')], {'writeToCache': literalTrue})
          .awaited
          .assignVar('handler')
          .statement,
      refer('serve', 'package:shelf/shelf_io.dart')
          .call([
            refer('handler')
                .property('handlerFor')
                .call([literalString('web')]),
            literalString('localhost'),
            literal(8000)
          ])
          .awaited
          .assignVar('server')
          .statement,
      refer('handler')
          .property('buildResults')
          .property('drain')
          .call([])
          .awaited
          .statement,
      refer('server').property('close').call([]).awaited.statement
    ])));

Future<BuildConfig> _packageBuildConfig(PackageNode package) async =>
    BuildConfig.fromPackageDir(
        await Pubspec.fromPackageDir(package.path), package.path);

/// Returns a [LiteralListExpression] with `BuilderApplication` instances
/// created using `apply`.
Expression _findBuilders(Iterable<BuilderDefinition> builderDefinitions) =>
    literalList(builderDefinitions.map(_applyBuilder).toList());

Expression _applyBuilder(BuilderDefinition definition) =>
    refer('apply', 'package:build_runner/build_runner.dart').call([
      literalString(definition.package),
      literalString(definition.name),
      literalList(definition.builderFactories
          .map((f) => refer(f, definition.import))
          .toList()),
      refer('toDependentsOf', 'package:build_runner/build_runner.dart')
          .call([literalString(definition.package)])
    ]);
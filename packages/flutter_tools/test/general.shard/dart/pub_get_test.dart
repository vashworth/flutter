// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart' show ProcessException;
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/convert.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/project.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/fakes.dart';
import '../../src/package_config.dart';

void main() {
  setUpAll(() {
    Cache.flutterRoot = '';
  });

  testWithoutContext('Throws a tool exit if pub cannot be run', () async {
    final processManager = FakeProcessManager.empty();
    final logger = BufferLogger.test();
    final fileSystem = MemoryFileSystem.test();
    processManager.excludedExecutables.add('bin/cache/dart-sdk/bin/dart');

    fileSystem.file('pubspec.yaml').createSync();

    final pub = Pub.test(
      fileSystem: fileSystem,
      logger: logger,
      processManager: processManager,
      platform: FakePlatform(),
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
    );

    await expectLater(
      () => pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      ),
      throwsToolExit(
        message: 'Your Flutter SDK download may be corrupt or missing permissions to run',
      ),
    );
  });

  group('shouldSkipThirdPartyGenerator', () {
    testWithoutContext('does not skip pub get the parameter is false', () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('version').writeAsStringSync('b');
      fileSystem.file('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
  {
    "configVersion": 2,
    "packages": [],
    "generated": "2021-07-08T10:02:49.155589Z",
    "generator": "third-party",
    "generatorVersion": "2.14.0-276.0.dev"
  }
  ''');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
        shouldSkipThirdPartyGenerator: false,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    });

    testWithoutContext(
      'does not skip pub get if package_config.json has "generator": "pub"',
      () async {
        final processManager = FakeProcessManager.list(<FakeCommand>[
          const FakeCommand(
            command: <String>[
              'bin/cache/dart-sdk/bin/dart',
              'pub',
              '--suppress-analytics',
              '--directory',
              '.',
              'get',
              '--example',
            ],
          ),
        ]);
        final logger = BufferLogger.test();
        final fileSystem = MemoryFileSystem.test();

        fileSystem.file('pubspec.yaml').createSync();
        fileSystem.file('pubspec.lock').createSync();
        fileSystem.file('.dart_tool/package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
  {
    "configVersion": 2,
    "packages": [],
    "generated": "2021-07-08T10:02:49.155589Z",
    "generator": "pub",
    "generatorVersion": "2.14.0-276.0.dev"
  }
  ''');
        fileSystem.file('.dart_tool/version').writeAsStringSync('a');
        fileSystem.file('version').writeAsStringSync('b');

        final pub = Pub.test(
          fileSystem: fileSystem,
          logger: logger,
          processManager: processManager,
          platform: FakePlatform(),
          botDetector: const FakeBotDetector(false),
          stdio: FakeStdio(),
        );

        await pub.get(
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          context: PubContext.pubGet,
          checkUpToDate: true,
        );

        expect(processManager, hasNoRemainingExpectations);
        expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
      },
    );

    testWithoutContext(
      'does not skip pub get if package_config.json has "generator": "pub"',
      () async {
        final processManager = FakeProcessManager.list(<FakeCommand>[
          const FakeCommand(
            command: <String>[
              'bin/cache/dart-sdk/bin/dart',
              'pub',
              '--suppress-analytics',
              '--directory',
              '.',
              'get',
              '--example',
            ],
          ),
        ]);
        final logger = BufferLogger.test();
        final fileSystem = MemoryFileSystem.test();

        fileSystem.file('pubspec.yaml').createSync();
        fileSystem.file('pubspec.lock').createSync();
        fileSystem.file('.dart_tool/package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
  {
    "configVersion": 2,
    "packages": [],
    "generated": "2021-07-08T10:02:49.155589Z",
    "generator": "pub",
    "generatorVersion": "2.14.0-276.0.dev"
  }
  ''');
        fileSystem.file('.dart_tool/version').writeAsStringSync('a');
        fileSystem.file('version').writeAsStringSync('b');

        final pub = Pub.test(
          fileSystem: fileSystem,
          logger: logger,
          processManager: processManager,
          platform: FakePlatform(),
          botDetector: const FakeBotDetector(false),
          stdio: FakeStdio(),
        );

        await pub.get(
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          context: PubContext.pubGet,
          checkUpToDate: true,
        );

        expect(processManager, hasNoRemainingExpectations);
        expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
      },
    );

    testWithoutContext('skips pub get if the package config "generator" is '
        'different than "pub"', () async {
      final processManager = FakeProcessManager.empty();
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"generator": "third-party"}');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(logger.traceText, contains('Skipping pub get: generated by third-party.'));
    });
  });

  testWithoutContext('checkUpToDate skips pub get if the package config is newer than the pubspec '
      'and the current framework version is the same as the last version', () async {
    final processManager = FakeProcessManager.empty();
    final logger = BufferLogger.test();
    final fileSystem = MemoryFileSystem.test();

    fileSystem.file('pubspec.yaml').createSync();
    fileSystem.file('pubspec.lock').createSync();
    fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
    fileSystem.file('.dart_tool/version').writeAsStringSync('a');
    fileSystem.file('version').writeAsStringSync('a');

    final pub = Pub.test(
      fileSystem: fileSystem,
      logger: logger,
      processManager: processManager,
      platform: FakePlatform(),
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
    );

    await pub.get(
      project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
      context: PubContext.pubGet,
      checkUpToDate: true,
    );

    expect(logger.traceText, contains('Skipping pub get: version match.'));
  });

  testWithoutContext(
    'checkUpToDate does not skip pub get if the package config is newer than the pubspec '
    'but the current framework version is not the same as the last version',
    () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
      fileSystem.file('.dart_tool/version').writeAsStringSync('a');
      fileSystem.file('version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext(
    'checkUpToDate does not skip pub get if the package config is newer than the pubspec '
    'but the current framework version does not exist yet',
    () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
      fileSystem.file('version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext(
    'checkUpToDate does not skip pub get if the package config does not exist',
    () async {
      final fileSystem = MemoryFileSystem.test();
      final processManager = FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
          onRun: (_) {
            fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
          },
        ),
      ]);
      final logger = BufferLogger.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext(
    'checkUpToDate does not skip pub get if the pubspec.lock does not exist',
    () async {
      final fileSystem = MemoryFileSystem.test();
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('version').writeAsStringSync('b');
      fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
      fileSystem.file('.dart_tool/version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext(
    'checkUpToDate does not skip pub get if the package config is older that the pubspec',
    () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock').createSync();
      fileSystem.file('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..setLastModifiedSync(DateTime(1991));
      fileSystem.file('version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext(
    'checkUpToDate does not skip pub get if the pubspec.lock is older that the pubspec',
    () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
        ),
      ]);
      final logger = BufferLogger.test();
      final fileSystem = MemoryFileSystem.test();

      fileSystem.file('pubspec.yaml').createSync();
      fileSystem.file('pubspec.lock')
        ..createSync()
        ..setLastModifiedSync(DateTime(1991));
      fileSystem.file('.dart_tool/package_config.json').createSync(recursive: true);
      fileSystem.file('version').writeAsStringSync('b');
      fileSystem.file('.dart_tool/version').writeAsStringSync('b');

      final pub = Pub.test(
        fileSystem: fileSystem,
        logger: logger,
        processManager: processManager,
        platform: FakePlatform(),
        botDetector: const FakeBotDetector(false),
        stdio: FakeStdio(),
      );

      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.pubGet,
        checkUpToDate: true,
      );

      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('.dart_tool/version').readAsStringSync(), 'b');
    },
  );

  testWithoutContext('pub get 66 shows message from pub', () async {
    final logger = BufferLogger.test();
    final FileSystem fileSystem = MemoryFileSystem.test();

    final processManager = FakeProcessManager.list(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        exitCode: 66,
        stderr: 'err1\nerr2\nerr3\n',
        stdout: 'out1\nout2\nout3\n',
        environment: <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
        },
      ),
    ]);
    final mockStdio = FakeStdio();
    final pub = Pub.test(
      platform: FakePlatform(),
      fileSystem: fileSystem,
      logger: logger,
      botDetector: const FakeBotDetector(false),
      stdio: mockStdio,
      processManager: processManager,
    );
    const toolExitMessage = '''
pub get failed
command: "bin/cache/dart-sdk/bin/dart pub --suppress-analytics --directory . get --example"
pub env: {
  "FLUTTER_ROOT": "",
  "PUB_ENVIRONMENT": "flutter_cli:flutter_tests",
}
exit code: 66
''';
    await expectLater(
      () => pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
      ),
      throwsA(
        isA<ToolExit>().having(
          (ToolExit error) => error.message,
          'message',
          contains('Failed to update packages'),
        ),
      ),
    );
    expect(logger.statusText, isEmpty);
    expect(logger.traceText, contains(toolExitMessage));
    expect(mockStdio.stdout.writes.map(utf8.decode), <String>['out1\nout2\nout3\n']);
    expect(mockStdio.stderr.writes.map(utf8.decode), <String>['err1\nerr2\nerr3\n']);
    expect(processManager, hasNoRemainingExpectations);
  });

  testWithoutContext(
    'pub get with failing exit code even with OutputMode == failuresOnly',
    () async {
      final logger = BufferLogger.test();
      final FileSystem fileSystem = MemoryFileSystem.test();

      final processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'bin/cache/dart-sdk/bin/dart',
            'pub',
            '--suppress-analytics',
            '--directory',
            '.',
            'get',
            '--example',
          ],
          exitCode: 1,
          stderr: '===pub get failed stderr here===',
          stdout: 'out1\nout2\nout3\n',
          environment: <String, String>{
            'FLUTTER_ROOT': '',
            'PUB_ENVIRONMENT': 'flutter_cli:update_packages',
          },
        ),
      ]);

      // Intentionally not using pub.test to simulate a real environment, but
      // we are using non-inherited I/O to avoid printing to the console.
      final pub = Pub(
        platform: FakePlatform(),
        fileSystem: fileSystem,
        logger: logger,
        botDetector: const FakeBotDetector(false),
        processManager: processManager,
      );

      await expectLater(
        () => pub.get(
          project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
          context: PubContext.updatePackages,
          outputMode: PubOutputMode.failuresOnly,
        ),
        throwsToolExit(message: 'Failed to update packages'),
      );
      expect(logger.statusText, isEmpty);
      expect(logger.errorText, contains('===pub get failed stderr here==='));
      expect(
        logger.warningText,
        contains('git remote set-url upstream'),
        reason: 'When update-packages fails, it is often because of missing an upstream remote.',
      );
      expect(processManager, hasNoRemainingExpectations);
    },
  );

  testWithoutContext('pub get shows working directory on process exception', () async {
    final logger = BufferLogger.test();
    final FileSystem fileSystem = MemoryFileSystem.test();

    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: const <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        onRun: (_) {
          throw const ProcessException(
            'bin/cache/dart-sdk/bin/dart',
            <String>['pub', '--suppress-analytics', '--directory', '.', 'get', '--example'],
            'message',
            1,
          );
        },
        exitCode: 66,
        stderr: 'err1\nerr2\nerr3\n',
        stdout: 'out1\nout2\nout3\n',
        environment: const <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
        },
      ),
    ]);

    final pub = Pub.test(
      platform: FakePlatform(),
      fileSystem: fileSystem,
      logger: logger,
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
      processManager: processManager,
    );
    await expectLater(
      () => pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
      ),
      throwsA(
        isA<ProcessException>()
            .having(
              (ProcessException error) => error.message,
              'message',
              contains('Working directory: "/" (exists)'),
            )
            .having(
              (ProcessException error) => error.message,
              'message',
              contains('"PUB_ENVIRONMENT": "flutter_cli:flutter_tests"'),
            ),
      ),
    );
    expect(logger.statusText, isEmpty);
    expect(logger.errorText, isEmpty);
    expect(processManager, hasNoRemainingExpectations);
  });

  testWithoutContext('pub get does not inherit logger.verbose', () async {
    final logger = BufferLogger.test(verbose: true);
    final FileSystem fileSystem = MemoryFileSystem.test();
    fileSystem.currentDirectory.childFile('version').createSync();

    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: const <String>[
          'bin/cache/dart-sdk/bin/dart',
          // Note: Omitted --verbose.
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        onRun: (_) =>
            writePackageConfigFiles(directory: fileSystem.currentDirectory, mainLibName: 'my_app'),
      ),
    ]);

    final pub = Pub.test(
      platform: FakePlatform(),
      fileSystem: fileSystem,
      logger: logger,
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
      processManager: processManager,
    );

    await expectLater(
      pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
        outputMode: PubOutputMode.failuresOnly,
      ),
      completes,
    );
  });

  // Regression test for https://github.com/flutter/flutter/issues/116627
  testWithoutContext('pub get suppresses progress output', () async {
    final logger = BufferLogger.test();
    final FileSystem fileSystem = MemoryFileSystem.test();

    final processManager = FakeProcessManager.list(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        stderr: 'err1\nerr2\nerr3\n',
        stdout: 'out1\nout2\nout3\n',
        environment: <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
        },
      ),
    ]);

    final mockStdio = FakeStdio();
    final pub = Pub.test(
      platform: FakePlatform(),
      fileSystem: fileSystem,
      logger: logger,
      processManager: processManager,
      botDetector: const FakeBotDetector(false),
      stdio: mockStdio,
    );

    try {
      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
        outputMode: PubOutputMode.failuresOnly,
      );
    } on ToolExit {
      // Ignore.
    }

    expect(mockStdio.stdout.writes.map(utf8.decode), isNot(<String>['out1\nout2\nout3\n']));
    expect(processManager, hasNoRemainingExpectations);
  });

  testWithoutContext('pub cache in flutter root is ignored', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final processManager = FakeProcessManager.list(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        exitCode: 69,
        environment: <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
        },
        stdout: "FakeCommand's env successfully matched",
      ),
    ]);

    final mockStdio = FakeStdio();
    final pub = Pub.test(
      platform: FakePlatform(),
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      processManager: processManager,
      botDetector: const FakeBotDetector(false),
      stdio: mockStdio,
    );

    try {
      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
      );
    } on ToolExit {
      // Ignore.
    }

    expect(mockStdio.stdout.writes.map(utf8.decode), <String>[
      "FakeCommand's env successfully matched",
    ]);
    expect(processManager, hasNoRemainingExpectations);
  });

  testWithoutContext('Preloaded packages are added to the pub cache', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Directory preloadCache = fileSystem.currentDirectory.childDirectory('.pub-preload-cache');
    preloadCache.childFile('a.tar.gz').createSync(recursive: true);
    preloadCache.childFile('b.tar.gz').createSync();
    fileSystem.currentDirectory.childFile('version').createSync();

    final processManager = FakeProcessManager.list(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          'cache',
          'preload',
          '.pub-preload-cache/a.tar.gz',
          '.pub-preload-cache/b.tar.gz',
        ],
      ),
      FakeCommand(
        command: const <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        environment: const <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
        },
        onRun: (_) =>
            writePackageConfigFiles(directory: fileSystem.currentDirectory, mainLibName: 'my_app'),
      ),
    ]);

    final Platform platform = FakePlatform(environment: <String, String>{'HOME': '/global'});
    final logger = BufferLogger.test();
    final pub = Pub.test(
      platform: platform,
      fileSystem: fileSystem,
      logger: logger,
      processManager: processManager,
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
    );

    await pub.get(
      project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
      context: PubContext.flutterTests,
    );

    expect(processManager, hasNoRemainingExpectations);
    expect(preloadCache.existsSync(), false);
  });

  testWithoutContext('pub cache in environment is used', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    fileSystem.directory('custom/pub-cache/path').createSync(recursive: true);
    final processManager = FakeProcessManager.list(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        exitCode: 69,
        environment: <String, String>{
          'FLUTTER_ROOT': '',
          'PUB_ENVIRONMENT': 'flutter_cli:flutter_tests',
          'PUB_CACHE': 'custom/pub-cache/path',
        },
        stdout: "FakeCommand's env successfully matched",
      ),
    ]);

    final mockStdio = FakeStdio();
    final pub = Pub.test(
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      processManager: processManager,
      botDetector: const FakeBotDetector(false),
      stdio: mockStdio,
      platform: FakePlatform(
        environment: const <String, String>{'PUB_CACHE': 'custom/pub-cache/path'},
      ),
    );

    try {
      await pub.get(
        project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
        context: PubContext.flutterTests,
      );
    } on ToolExit {
      // Ignore.
    }

    expect(mockStdio.stdout.writes.map(utf8.decode), <String>[
      "FakeCommand's env successfully matched",
    ]);
    expect(processManager, hasNoRemainingExpectations);
  });

  testUsingContext('can use generate: true within a workspace', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final pub = Pub.test(
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      processManager: FakeProcessManager.any(),
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
      platform: FakePlatform(
        environment: const <String, String>{'PUB_CACHE': 'custom/pub-cache/path'},
      ),
    );

    final Directory pkg = fileSystem.directory('workspace_pkg')..createSync(recursive: true);
    fileSystem.file('version').createSync();
    pkg.childFile('pubspec.yaml')
      ..createSync()
      ..writeAsStringSync('''
      flutter:
        generate: true
      ''');
    fileSystem.file('.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
      {"configVersion": 2,"packages": [
        {
          "name": "flutter_tools",
          "rootUri": "../",
          "packageUri": "lib/",
          "languageVersion": "2.7"
        }
      ],"generated":"some-time"}
''');

    await expectLater(
      pub.get(project: FlutterProject.fromDirectoryTest(pkg), context: PubContext.flutterTests),
      completes,
    );
  });

  testWithoutContext('Pub error handling', () async {
    final logger = BufferLogger.test();
    final fileSystem = MemoryFileSystem.test();
    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: const <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        onRun: (_) {
          fileSystem.file('.dart_tool/package_config.json').setLastModifiedSync(DateTime(2002));
        },
      ),
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
      ),
      FakeCommand(
        command: const <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
        onRun: (_) {
          fileSystem.file('pubspec.yaml').setLastModifiedSync(DateTime(2002));
        },
      ),
      const FakeCommand(
        command: <String>[
          'bin/cache/dart-sdk/bin/dart',
          'pub',
          '--suppress-analytics',
          '--directory',
          '.',
          'get',
          '--example',
        ],
      ),
    ]);
    final pub = Pub.test(
      fileSystem: fileSystem,
      logger: logger,
      processManager: processManager,
      platform: FakePlatform(environment: <String, String>{}),
      botDetector: const FakeBotDetector(false),
      stdio: FakeStdio(),
    );

    fileSystem.file('version').createSync();
    // the good scenario: package_config.json is old, pub updates the file.
    fileSystem.file('.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..setLastModifiedSync(DateTime(2000));
    fileSystem.file('pubspec.yaml')
      ..createSync()
      ..setLastModifiedSync(DateTime(2001));
    await pub.get(
      project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
      context: PubContext.flutterTests,
    ); // pub sets date of package_config.json to 2002

    expect(logger.errorText, isEmpty);
    expect(
      fileSystem.file('pubspec.yaml').lastModifiedSync(),
      DateTime(2001),
    ); // because nothing should touch it
    logger.clear();

    // bad scenario 1: pub doesn't update file; doesn't matter, because we do instead
    fileSystem.file('.dart_tool/package_config.json').setLastModifiedSync(DateTime(2000));
    fileSystem.file('pubspec.yaml').setLastModifiedSync(DateTime(2001));
    await pub.get(
      project: FlutterProject.fromDirectoryTest(fileSystem.currentDirectory),
      context: PubContext.flutterTests,
    ); // pub does nothing

    expect(logger.statusText, isEmpty);
    expect(logger.errorText, isEmpty);
    expect(
      fileSystem.file('pubspec.yaml').lastModifiedSync(),
      DateTime(2001),
    ); // because nothing should touch it
    logger.clear();
  });
}

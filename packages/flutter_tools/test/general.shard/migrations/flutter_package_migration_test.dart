// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/ios/xcodeproj.dart';
import 'package:flutter_tools/src/migrations/flutter_package_migration.dart';

import 'package:flutter_tools/src/project.dart';
import 'package:test/fake.dart';

import '../../src/common.dart';
import '../../src/fake_process_manager.dart';

void main() {
  group('Flutter Package Migration', () {

    testWithoutContext('fails if Xcode project not found', () {
      final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
      final BufferLogger testLogger = BufferLogger.test();
      final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
      final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
      final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
        project,
        SupportedPlatform.ios,
        xcodeProjectInterpreter: xcodeProjectInterpreter,
        logger: testLogger,
        fileSystem: memoryFileSystem,
        processManager: FakeProcessManager.any(),
      );
      expect(() => iosProjectMigration.migrate(), throwsToolExit(message: 'Failed to convert your project to use Swift Package Manager.'));
      expect(testLogger.traceText, isEmpty);
      expect(testLogger.statusText, isEmpty);
      expect(testLogger.errorText, contains('An error occured when migrating your project to Swift Package Manager: Exception: Xcode project not found.'));
    });

    testWithoutContext('migrate FlutterOutputs.xcfilelist for macOS', () {
      // TODO: SPM
    });

    group('migrate gitignore', () {
      testWithoutContext('skipped if no files to update', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: FakeProcessManager.any(),
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText.contains('Adding FlutterPackage to app_name/.gitignore'), isFalse);
        expect(testLogger.traceText.contains('Adding FlutterPackage to app_name/ios/.gitignore'), isFalse);
      });

      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        project.parent.directory.childFile('.gitignore').writeAsStringSync('Flutter/Packages/FlutterPackage');
        project.hostAppRoot.childFile('.gitignore').writeAsStringSync('Flutter/Packages/FlutterPackage');

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: FakeProcessManager.any(),
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText.contains('Adding FlutterPackage to app_name/.gitignore'), isFalse);
        expect(testLogger.traceText.contains('Adding FlutterPackage to app_name/ios/.gitignore'), isFalse);
      });

      testWithoutContext('successfully updates', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);

        project.parent.directory.childFile('.gitignore').writeAsStringSync('''
**/Pods/
**/Flutter/ephemeral/
''');
        project.hostAppRoot.childFile('.gitignore').writeAsStringSync('''
**/Flutter/ephemeral/
''');

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: FakeProcessManager.any(),
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('Adding FlutterPackage to app_name/.gitignore'));
        expect(project.parent.directory.childFile('.gitignore').readAsStringSync(), '''
**/Pods/
Flutter/Packages/FlutterPackage
**/Flutter/ephemeral/
''');
        expect(testLogger.traceText, contains('Adding FlutterPackage to app_name/ios/.gitignore'));
        expect(project.hostAppRoot.childFile('.gitignore').readAsStringSync(), '''
**/Flutter/ephemeral/

Flutter/Packages/FlutterPackage
''');
      });
    });

    group('fails if parsing project.pbxproj', () {
      testWithoutContext('fails plutil command', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          exitCode: 1,
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );
        expect(() => iosProjectMigration.migrate(), throwsToolExit(message: 'Failed to convert your project to use Swift Package Manager.'));
        expect(testLogger.errorText, contains('An error occured when migrating your project to Swift Package Manager: Exception: Failed to parse project settings.'));
      });

      testWithoutContext('returns unexpected JSON', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: '[]',
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );
        expect(() => iosProjectMigration.migrate(), throwsToolExit(message: 'Failed to convert your project to use Swift Package Manager.'));
        expect(testLogger.errorText, contains('An error occured when migrating your project to Swift Package Manager: Exception: project.pbxproj returned unexpected JSON response'));
      });

      testWithoutContext('returns non-JSON', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: 'this is not json',
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );
        expect(() => iosProjectMigration.migrate(), throwsToolExit(message: 'Failed to convert your project to use Swift Package Manager.'));
        expect(testLogger.errorText, contains('An error occured when migrating your project to Swift Package Manager: Exception: project.pbxproj returned non-JSON response'));
      });
    });

    testWithoutContext('skip if all settings migrated', () {
      // TODO: SPM
    });

    testWithoutContext('throw if settings not updated correctly', () {
      // TODO: SPM
    });

    testWithoutContext('throw if settings fail to compile', () {
      // TODO: SPM
    });

    testWithoutContext('restore project settings from backup on failure', () {
      // TODO: SPM
    });

    group('migrate PBXBuildFile', () {
      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXBuildFile already migrated. Skipping...'));
      });

      testWithoutContext('fails if missing PBXBuildFile section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(<String>[]),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXBuildFile section'));
      });

      testWithoutContext('successfully added', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_buildFileSectionIndex] = unmigratedBuildFileSection;
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_buildFileSectionIndex] = unmigratedBuildFileSectionAsJson;

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();
        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });
    });

    group('migrate PBXFileReference', () {
      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXFileReference already migrated. Skipping...'));
      });

      testWithoutContext('fails if missing PBXFileReference section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_fileReferenceSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_fileReferenceSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXFileReference section'));
      });

      testWithoutContext('successfully added', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_fileReferenceSectionIndex] = unmigratedFileReferenceSection;
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_fileReferenceSectionIndex] = unmigratedFileReferenceSectionAsJson;

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();
        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });
    });

    group('migrate PBXFrameworksBuildPhase', () {
      group('for iOS', () {
        // TODO: SPM
      });

      group('for macOS', () {
        // TODO: SPM
      });
      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXFrameworksBuildPhase already migrated. Skipping...'));
      });

      testWithoutContext('fails if missing PBXFrameworksBuildPhase section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_frameworksBuildPhaseSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_frameworksBuildPhaseSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXFrameworksBuildPhase section'));
      });

      testWithoutContext('fails if missing Runner target subsection following PBXFrameworksBuildPhase begin header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = '''
/* Begin PBXFrameworksBuildPhase section */
/* End PBXFrameworksBuildPhase section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_frameworksBuildPhaseSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXFrameworksBuildPhase for Runner target'));
      });

      testWithoutContext('fails if missing Runner target subsection before PBXFrameworksBuildPhase end header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = '''
/* Begin PBXFrameworksBuildPhase section */
/* End PBXFrameworksBuildPhase section */
/* Begin NonExistant section */
		97C146EB1CF9000F007C117D /* Frameworks */ = {
		};
/* End NonExistant section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_frameworksBuildPhaseSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXFrameworksBuildPhase for Runner target'));
      });

      testWithoutContext('fails if missing Runner target in parsed settings', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_frameworksBuildPhaseSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(<String>[
            migratedBuildFileSectionAsJson,
            migratedFileReferenceSectionAsJson,
          ]),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find parsed PBXFrameworksBuildPhase for Runner target'));
      });

      testWithoutContext('successfully added when files field is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSection(missingFiles: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSectionAsJson(missingFiles: true);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_frameworksBuildPhaseSectionIndex] = migratedFrameworksBuildPhaseSection(missingFiles: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

      testWithoutContext('successfully added when files field is empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSectionAsJson();

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when files field is not empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSection(withCocoapods: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_frameworksBuildPhaseSectionIndex] = unmigratedFrameworksBuildPhaseSectionAsJson(withCocoapods: true);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_frameworksBuildPhaseSectionIndex] = migratedFrameworksBuildPhaseSection(withCocoapods: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });
    });

    group('migrate PBXGroup', () {
      group('for iOS', () {
        // TODO: SPM
      });

      group('for macOS', () {
        // TODO: SPM
      });
      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXGroup already migrated. Skipping...'));
      });

      testWithoutContext('fails if missing PBXGroup section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_groupSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_groupSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXGroup section'));
      });

      testWithoutContext('fails if missing Flutter group subsection following PBXGroup begin header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_groupSectionIndex] = '''
/* Begin PBXGroup section */
/* End PBXGroup section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_groupSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find Flutter PBXGroup'));
      });

      testWithoutContext('fails if missing Flutter group subsection before PBXGroup end header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_groupSectionIndex] = '''
/* Begin PBXGroup section */
/* End PBXGroup section */
/* Begin NonExistant section */
		9740EEB11CF90186004384FC /* Flutter */ = {
		};
/* End NonExistant section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_groupSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find Flutter PBXGroup'));
      });

      testWithoutContext('successfully added when Packages group is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_groupSectionIndex] = unmigratedGroupSection(packagesGroupExists: false);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_groupSectionIndex] = unmigratedGroupSectionAsJson(packagesGroupExists: false);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_groupSectionIndex] = migratedGroupSection(packagesGroupExists: false);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

      testWithoutContext('successfully added when Packages group already exists', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_groupSectionIndex] = unmigratedGroupSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_groupSectionIndex] = unmigratedGroupSectionAsJson();

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

    });

    group('migrate PBXNativeTarget', () {
      group('for iOS', () {
        // TODO: SPM
      });

      group('for macOS', () {
        // TODO: SPM
      });
      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXNativeTarget already migrated. Skipping...'));
      });

      testWithoutContext('fails if missing PBXNativeTarget section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_nativeTargetSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_nativeTargetSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXNativeTarget section'));
      });

      testWithoutContext('fails if missing Runner target subsection following PBXNativeTarget begin header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = '''
/* Begin PBXNativeTarget section */
/* End PBXNativeTarget section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_nativeTargetSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXNativeTarget for Runner target'));
      });

      testWithoutContext('fails if missing Runner target subsection before PBXNativeTarget end header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = '''
/* Begin PBXNativeTarget section */
/* End PBXNativeTarget section */
/* Begin NonExistant section */
		97C146ED1CF9000F007C117D /* Runner */ = {
		};
/* End NonExistant section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_nativeTargetSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXNativeTarget for Runner target'));
      });

      testWithoutContext('fails if missing Runner target in parsed settings', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_nativeTargetSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find parsed PBXNativeTarget for Runner target'));
      });

      testWithoutContext('successfully added when packageProductDependencies field is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSection(missingPackageProductDependencies: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSectionAsJson(missingPackageProductDependencies: true);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_nativeTargetSectionIndex] = migratedNativeTargetSection(missingPackageProductDependencies: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

      testWithoutContext('successfully added when packageProductDependencies field is empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSectionAsJson();

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when packageProductDependencies field is not empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSection(withOtherDependency: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_nativeTargetSectionIndex] = unmigratedNativeTargetSectionAsJson();

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_nativeTargetSectionIndex] = migratedNativeTargetSection(withOtherDependency: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

    });

    group('migrate PBXProject', () {
      group('for iOS', () {
        // TODO: SPM
      });

      group('for macOS', () {
        // TODO: SPM
      });
      testWithoutContext('skipped if not Xcode 15', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter(
          xcodeVersion: Version(14, 0, 0),
        );
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_buildFileSectionIndex);
        settingsAsJsonBeforeMigration[_projectSectionIndex] = unmigratedProjectSectionAsJson();

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXProject already migrated or not needed. Skipping...'));
      });

      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('PBXProject already migrated or not needed. Skipping...'));
      });

      testWithoutContext('fails if missing PBXProject section', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_projectSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_projectSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXProject section'));
      });

      testWithoutContext('fails if missing Runner project subsection following PBXProject begin header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = '''
/* Begin PBXProject section */
/* End PBXProject section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_projectSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXProject for Runner'));
      });

      testWithoutContext('fails if missing Runner project subsection before PBXProject end header', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = '''
/* Begin PBXProject section */
/* End PBXProject section */
/* Begin NonExistant section */
		97C146E61CF9000F007C117D /* Project object */ = {
		};
/* End NonExistant section */
''';
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_projectSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find PBXProject for Runner'));
      });

      testWithoutContext('fails if missing Runner project in parsed settings', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = unmigratedProjectSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_projectSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find parsed PBXProject for Runner target'));
      });

      testWithoutContext('successfully added when packageReferences field is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = unmigratedProjectSection(missingPackageReferences: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_projectSectionIndex] = unmigratedProjectSectionAsJson(missingPackageReferences: true);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_projectSectionIndex] = migratedProjectSection(missingPackageReferences: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

      testWithoutContext('successfully added when packageReferences field is empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = unmigratedProjectSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_projectSectionIndex] = unmigratedProjectSectionAsJson();

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when packageReferences field is not empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_projectSectionIndex] = unmigratedProjectSection(withOtherReference: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration[_projectSectionIndex] = unmigratedProjectSectionAsJson();

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_projectSectionIndex] = migratedProjectSection(withOtherReference: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

    });

    group('migrate XCLocalSwiftPackageReference', () {
      testWithoutContext('skipped if not Xcode 15', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter(
          xcodeVersion: Version(14, 0, 0),
        );
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_buildFileSectionIndex);
        settingsAsJsonBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('XCLocalSwiftPackageReference already migrated or not needed. Skipping...'));
      });

      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('XCLocalSwiftPackageReference already migrated or not needed. Skipping...'));
      });

      testWithoutContext('fails if unable to find section to append it after', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find any sections'));
      });

      testWithoutContext('successfully added when section is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);

        final List<String> expectedSettings = <String>[...settingsBeforeMigration];
        expectedSettings.add(migratedLocalSwiftPackageReferenceSection());

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });

      testWithoutContext('successfully added when section is empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_localSwiftPackageReferenceSectionIndex] = unmigratedLocalSwiftPackageReferenceSection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when section is not empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_localSwiftPackageReferenceSectionIndex] = unmigratedLocalSwiftPackageReferenceSection(withOtherReference: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_localSwiftPackageReferenceSectionIndex);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_localSwiftPackageReferenceSectionIndex] = migratedLocalSwiftPackageReferenceSection(withOtherReference: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });
    });

    group('migrate XCSwiftPackageProductDependency', () {

      testWithoutContext('skipped if already updated', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(allSectionsMigrated));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_buildFileSectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.traceText, contains('XCSwiftPackageProductDependency already migrated. Skipping...'));
      });

      testWithoutContext('fails if unable to find section to append it after', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommand(FakeCommand(
          command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
          stdout: _plutilOutput(settingsAsJsonBeforeMigration),
        ));

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        expect(() => iosProjectMigration.migrate(), throwsToolExit());
        expect(testLogger.errorText, contains('Unable to find any sections'));
      });

      testWithoutContext('successfully added when section is missing', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when section is empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_swiftPackageProductDependencySectionIndex] = unmigratedSwiftPackageProductDependencySection();
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(allSectionsMigrated),
        );
      });

      testWithoutContext('successfully added when section is not empty', () {
        final MemoryFileSystem memoryFileSystem = MemoryFileSystem();
        final BufferLogger testLogger = BufferLogger.test();
        final FakeIosProject project = FakeIosProject(fileSystem: memoryFileSystem);
        final FakeXcodeProjectInterpreter xcodeProjectInterpreter = FakeXcodeProjectInterpreter();
        final FakeProcessManager processManager = FakeProcessManager.list(<FakeCommand>[]);

        project.parent.directory.createSync(recursive: true);
        project.hostAppRoot.createSync(recursive: true);
        project.xcodeProjectInfoFile.createSync(recursive: true);
        memoryFileSystem.file('/usr/bin/plutil').createSync(recursive: true);

        final List<String> settingsBeforeMigration = <String>[...allSectionsMigrated];
        settingsBeforeMigration[_swiftPackageProductDependencySectionIndex] = unmigratedSwiftPackageProductDependencySection(withOtherDependency: true);
        project.xcodeProjectInfoFile.writeAsStringSync(_projectSettings(settingsBeforeMigration));

        final List<String> settingsAsJsonBeforeMigration = <String>[...allSectionsMigratedAsJson];
        settingsAsJsonBeforeMigration.removeAt(_swiftPackageProductDependencySectionIndex);

        final List<String> expectedSettings = <String>[...allSectionsMigrated];
        expectedSettings[_swiftPackageProductDependencySectionIndex] = migratedSwiftPackageProductDependencySection(withOtherDependency: true);

        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(settingsAsJsonBeforeMigration),
          ),
          FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'json', '-r', '-o', '-', project.xcodeProjectInfoFile.path],
            stdout: _plutilOutput(allSectionsMigratedAsJson),
          ),
        ]);

        final FlutterPackageMigration iosProjectMigration = FlutterPackageMigration(
          project,
          SupportedPlatform.ios,
          xcodeProjectInterpreter: xcodeProjectInterpreter,
          logger: testLogger,
          fileSystem: memoryFileSystem,
          processManager: processManager,
        );

        iosProjectMigration.migrate();

        expect(processManager.hasRemainingExpectations, isFalse);
        expect(testLogger.errorText, isEmpty);
        expect(
          project.xcodeProjectInfoFile.readAsStringSync(),
          _projectSettings(expectedSettings),
        );
      });
    });
  });
}

const int _buildFileSectionIndex = 0;
const int _fileReferenceSectionIndex = 1;
const int _frameworksBuildPhaseSectionIndex = 2;
const int _groupSectionIndex = 3;
const int _nativeTargetSectionIndex = 4;
const int _projectSectionIndex = 5;
const int _localSwiftPackageReferenceSectionIndex = 6;
const int _swiftPackageProductDependencySectionIndex = 7;

List<String> allSectionsMigrated = <String>[
  migratedBuildFileSection,
  migratedFileReferenceSection,
  migratedFrameworksBuildPhaseSection(),
  migratedGroupSection(),
  migratedNativeTargetSection(),
  migratedProjectSection(),
  migratedLocalSwiftPackageReferenceSection(),
  migratedSwiftPackageProductDependencySection(),
];

List<String> allSectionsMigratedAsJson = <String>[
  migratedBuildFileSectionAsJson,
  migratedFileReferenceSectionAsJson,
  migratedFrameworksBuildPhaseSectionAsJson,
  migratedGroupSectionAsJson,
  migratedNativeTargetSectionAsJson,
  migratedProjectSectionAsJson,
  migratedLocalSwiftPackageReferenceSectionAsJson,
  migratedSwiftPackageProductDependencySectionAsJson,
];

String _plutilOutput(List<String> objects) {
  return '''
{
  "archiveVersion" : "1",
  "classes" : {

  },
  "objects" : {
${objects.join(',\n')}
  }
}
''';
}

String _projectSettings(List<String> objects) {
  return '''
${objects.join('\n')}
''';
}

// PBXBuildFile
const String unmigratedBuildFileSection = '''
/* Begin PBXBuildFile section */
		74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 74858FAE1ED2DC5600515810 /* AppDelegate.swift */; };
		97C146FC1CF9000F007C117D /* Main.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = 97C146FA1CF9000F007C117D /* Main.storyboard */; };
/* End PBXBuildFile section */
''';
const String migratedBuildFileSection = '''
/* Begin PBXBuildFile section */
		74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 74858FAE1ED2DC5600515810 /* AppDelegate.swift */; };
		97C146FC1CF9000F007C117D /* Main.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = 97C146FA1CF9000F007C117D /* Main.storyboard */; };
		78A318202AECB46A00862997 /* FlutterPackage in Frameworks */ = {isa = PBXBuildFile; productRef = 78A3181F2AECB46A00862997 /* FlutterPackage */; };
/* End PBXBuildFile section */
''';
const String unmigratedBuildFileSectionAsJson = '''
    "97C146FC1CF9000F007C117D" : {
      "fileRef" : "97C146FA1CF9000F007C117D",
      "isa" : "PBXBuildFile"
    },
    "74858FAF1ED2DC5600515810" : {
      "fileRef" : "74858FAE1ED2DC5600515810",
      "isa" : "PBXBuildFile"
    }''';
const String migratedBuildFileSectionAsJson = '''
    "78A318202AECB46A00862997" : {
      "isa" : "PBXBuildFile",
      "productRef" : "78A3181F2AECB46A00862997"
    },
    "97C146FC1CF9000F007C117D" : {
      "fileRef" : "97C146FA1CF9000F007C117D",
      "isa" : "PBXBuildFile"
    },
    "74858FAF1ED2DC5600515810" : {
      "fileRef" : "74858FAE1ED2DC5600515810",
      "isa" : "PBXBuildFile"
    }''';

// PBXFileReference
const String unmigratedFileReferenceSection = '''
/* Begin PBXFileReference section */
		74858FAE1ED2DC5600515810 /* AppDelegate.swift */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
		7AFA3C8E1D35360C0083082E /* Release.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Release.xcconfig; path = Flutter/Release.xcconfig; sourceTree = "<group>"; };
/* End PBXFileReference section */
''';
const String migratedFileReferenceSection = '''
/* Begin PBXFileReference section */
		74858FAE1ED2DC5600515810 /* AppDelegate.swift */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
		7AFA3C8E1D35360C0083082E /* Release.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Release.xcconfig; path = Flutter/Release.xcconfig; sourceTree = "<group>"; };
		78A3181E2AECB45400862997 /* FlutterPackage */ = {isa = PBXFileReference; lastKnownFileType = wrapper; name = FlutterPackage; path = Flutter/Packages/FlutterPackage; sourceTree = "<group>"; };
/* End PBXFileReference section */
''';
const String migratedFileReferenceSectionAsJson = '''
    "7AFA3C8E1D35360C0083082E" : {
      "isa" : "PBXFileReference",
      "lastKnownFileType" : "text.xcconfig",
      "name" : "Release.xcconfig",
      "path" : "Flutter/Release.xcconfig",
      "sourceTree" : "<group>"
    },
    "78A3181E2AECB45400862997" : {
      "isa" : "PBXFileReference",
      "lastKnownFileType" : "wrapper",
      "name" : "FlutterPackage",
      "path" : "Flutter/Packages/FlutterPackage",
      "sourceTree" : "<group>"
    },
    "74858FAE1ED2DC5600515810" : {
      "fileEncoding" : "4",
      "isa" : "PBXFileReference",
      "lastKnownFileType" : "sourcecode.swift",
      "path" : "AppDelegate.swift",
      "sourceTree" : "<group>"
    }''';
const String unmigratedFileReferenceSectionAsJson = '''
    "7AFA3C8E1D35360C0083082E" : {
      "isa" : "PBXFileReference",
      "lastKnownFileType" : "text.xcconfig",
      "name" : "Release.xcconfig",
      "path" : "Flutter/Release.xcconfig",
      "sourceTree" : "<group>"
    },
    "74858FAE1ED2DC5600515810" : {
      "fileEncoding" : "4",
      "isa" : "PBXFileReference",
      "lastKnownFileType" : "sourcecode.swift",
      "path" : "AppDelegate.swift",
      "sourceTree" : "<group>"
    }''';

// PBXFrameworksBuildPhase
String unmigratedFrameworksBuildPhaseSection({bool withCocoapods = false, bool missingFiles = false}) {
  return <String>[
    '/* Begin PBXFrameworksBuildPhase section */',
    '		97C146EB1CF9000F007C117D /* Frameworks */ = {',
    '			isa = PBXFrameworksBuildPhase;',
    '			buildActionMask = 2147483647;',
    if (!missingFiles)
      ...<String>[
        '			files = (',
        if (withCocoapods)
          '				FD5BB45FB410D26C457F3823 /* Pods_Runner.framework in Frameworks */,',
        '			);',
      ],
    '			runOnlyForDeploymentPostprocessing = 0;',
    '		};',
    '/* End PBXFrameworksBuildPhase section */',
  ].join('\n');
}
String migratedFrameworksBuildPhaseSection({bool withCocoapods = false, bool missingFiles = false}) {
  final List<String> filesField = <String>[
    '			files = (',
    '				78A318202AECB46A00862997 /* FlutterPackage in Frameworks */,',
    if (withCocoapods)
      '				FD5BB45FB410D26C457F3823 /* Pods_Runner.framework in Frameworks */,',
    '			);',
  ];
  return <String>[
    '/* Begin PBXFrameworksBuildPhase section */',
    '		97C146EB1CF9000F007C117D /* Frameworks */ = {',
    if (missingFiles)
      ...filesField,
    '			isa = PBXFrameworksBuildPhase;',
    '			buildActionMask = 2147483647;',
    if (!missingFiles)
      ...filesField,
    '			runOnlyForDeploymentPostprocessing = 0;',
    '		};',
    '/* End PBXFrameworksBuildPhase section */',
  ].join('\n');
}
String unmigratedFrameworksBuildPhaseSectionAsJson({bool withCocoapods = false, bool missingFiles = false}) {
  return <String>[
    '    "97C146EB1CF9000F007C117D" : {',
    '      "buildActionMask" : "2147483647",',
    if (!missingFiles)
      ...<String>[
        '      "files" : [',
        if (withCocoapods)
          '        "FD5BB45FB410D26C457F3823"',
        '      ],',
      ],
    '      "isa" : "PBXFrameworksBuildPhase",',
    '      "runOnlyForDeploymentPostprocessing" : "0"',
    '    }',
  ].join('\n');
}
const String migratedFrameworksBuildPhaseSectionAsJson = '''
    "97C146EB1CF9000F007C117D" : {
      "buildActionMask" : "2147483647",
      "files" : [
        "78A318202AECB46A00862997"
      ],
      "isa" : "PBXFrameworksBuildPhase",
      "runOnlyForDeploymentPostprocessing" : "0"
    }''';

// PBXGroup
String unmigratedGroupSection({bool packagesGroupExists = true}) {
  final List<String> packagesGroup = <String>[
    '		78A3181D2AECB45400862997 /* Packages */ = {',
    '			isa = PBXGroup;',
    '			children = (',
    '				78A3181E2AECB45400862997 /* FlutterPackage */,',
    '			);',
    '			name = Packages;',
    '			sourceTree = "<group>";',
    '		};',
  ];
  return <String>[
    '/* Begin PBXGroup section */',
    if (packagesGroupExists)
      ...packagesGroup,
    '		9740EEB11CF90186004384FC /* Flutter */ = {',
    '			isa = PBXGroup;',
    '			children = (',
    // '				78A3181D2AECB45400862997 /* Packages */,',
    '				3B3967151E833CAA004F5970 /* AppFrameworkInfo.plist */,',
    '				9740EEB21CF90195004384FC /* Debug.xcconfig */,',
    '				7AFA3C8E1D35360C0083082E /* Release.xcconfig */,',
    '				9740EEB31CF90195004384FC /* Generated.xcconfig */,',
    '			);',
    '			name = Flutter;',
    '			sourceTree = "<group>";',
    '		};',
    '/* End PBXGroup section */',
  ].join('\n');
}
String migratedGroupSection({bool packagesGroupExists = true}) {
  final List<String> packagesGroup = <String>[
    '		78A3181D2AECB45400862997 /* Packages */ = {',
    '			isa = PBXGroup;',
    '			children = (',
    '				78A3181E2AECB45400862997 /* FlutterPackage */,',
    '			);',
    '			name = Packages;',
    '			sourceTree = "<group>";',
    '		};',
  ];
  return <String>[
    '/* Begin PBXGroup section */',
    if (packagesGroupExists)
      ...packagesGroup,
    '		9740EEB11CF90186004384FC /* Flutter */ = {',
    '			isa = PBXGroup;',
    '			children = (',
    '				78A3181D2AECB45400862997 /* Packages */,',
    '				3B3967151E833CAA004F5970 /* AppFrameworkInfo.plist */,',
    '				9740EEB21CF90195004384FC /* Debug.xcconfig */,',
    '				7AFA3C8E1D35360C0083082E /* Release.xcconfig */,',
    '				9740EEB31CF90195004384FC /* Generated.xcconfig */,',
    '			);',
    '			name = Flutter;',
    '			sourceTree = "<group>";',
    '		};',
    if (!packagesGroupExists)
      ...packagesGroup,
    '/* End PBXGroup section */',
  ].join('\n');
}
String unmigratedGroupSectionAsJson({bool packagesGroupExists = true}) {
  final List<String> packagesGroup = <String>[
    '    "78A3181D2AECB45400862997" : {',
    '      "children" : [',
    '        "78A3181E2AECB45400862997"',
    '      ],',
    '      "isa" : "PBXGroup",',
    '      "name" : "Packages",',
    '      "sourceTree" : "<group>"',
    '    },',
  ];
  return <String>[
    if (packagesGroupExists)
      ...packagesGroup,
    '    "9740EEB11CF90186004384FC" : {',
    '      "children" : [',
    '        "3B3967151E833CAA004F5970",',
    '        "9740EEB21CF90195004384FC",',
    '        "7AFA3C8E1D35360C0083082E",',
    '        "9740EEB31CF90195004384FC"',
    '      ],',
    '      "isa" : "PBXGroup",',
    '      "name" : "Flutter",',
    '      "sourceTree" : "<group>"',
    '    }'
  ].join('\n');
}
const String migratedGroupSectionAsJson = '''
    "78A3181D2AECB45400862997" : {
      "children" : [
        "78A3181E2AECB45400862997"
      ],
      "isa" : "PBXGroup",
      "name" : "Packages",
      "sourceTree" : "<group>"
    },
    "9740EEB11CF90186004384FC" : {
      "children" : [
        "78A3181D2AECB45400862997",
        "3B3967151E833CAA004F5970",
        "9740EEB21CF90195004384FC",
        "7AFA3C8E1D35360C0083082E",
        "9740EEB31CF90195004384FC"
      ],
      "isa" : "PBXGroup",
      "name" : "Flutter",
      "sourceTree" : "<group>"
    }''';

// PBXNativeTarget
String unmigratedNativeTargetSection({bool missingPackageProductDependencies = false, bool withOtherDependency = false}) {
  return <String>[
    '/* Begin PBXNativeTarget section */',
    '		97C146ED1CF9000F007C117D /* Runner */ = {',
    '			isa = PBXNativeTarget;',
    '			buildConfigurationList = 97C147051CF9000F007C117D /* Build configuration list for PBXNativeTarget "Runner" */;',
    '			buildPhases = (',
    '				9740EEB61CF901F6004384FC /* Run Script */,',
    '				97C146EA1CF9000F007C117D /* Sources */,',
    '				97C146EB1CF9000F007C117D /* Frameworks */,',
    '				97C146EC1CF9000F007C117D /* Resources */,',
    '				9705A1C41CF9048500538489 /* Embed Frameworks */,',
    '				3B06AD1E1E4923F5004D2608 /* Thin Binary */,',
    '			);',
    '			buildRules = (',
    '			);',
    '			dependencies = (',
    '			);',
    '			name = Runner;',
    if (!missingPackageProductDependencies)
      ...<String>[
        '			packageProductDependencies = (',
        if (withOtherDependency)
          '				010101010101010101010101 /* SomeOtherPackage */,',
        '			);',
      ],
    '			productName = Runner;',
    '			productReference = 97C146EE1CF9000F007C117D /* Runner.app */;',
    '			productType = "com.apple.product-type.application";',
    '		};',
    '/* End PBXNativeTarget section */',
  ].join('\n');
}
String migratedNativeTargetSection({bool missingPackageProductDependencies = false, bool withOtherDependency = false}) {
  final List<String> packageDependencies = <String>[
    '			packageProductDependencies = (',
    '				78A3181F2AECB46A00862997 /* FlutterPackage */,',
    if (withOtherDependency)
      '				010101010101010101010101 /* SomeOtherPackage */,',
    '			);',
  ];
  return <String>[
    '/* Begin PBXNativeTarget section */',
    '		97C146ED1CF9000F007C117D /* Runner */ = {',
    if (missingPackageProductDependencies)
      ...packageDependencies,
    '			isa = PBXNativeTarget;',
    '			buildConfigurationList = 97C147051CF9000F007C117D /* Build configuration list for PBXNativeTarget "Runner" */;',
    '			buildPhases = (',
    '				9740EEB61CF901F6004384FC /* Run Script */,',
    '				97C146EA1CF9000F007C117D /* Sources */,',
    '				97C146EB1CF9000F007C117D /* Frameworks */,',
    '				97C146EC1CF9000F007C117D /* Resources */,',
    '				9705A1C41CF9048500538489 /* Embed Frameworks */,',
    '				3B06AD1E1E4923F5004D2608 /* Thin Binary */,',
    '			);',
    '			buildRules = (',
    '			);',
    '			dependencies = (',
    '			);',
    '			name = Runner;',
    if (!missingPackageProductDependencies)
      ...packageDependencies,
    '			productName = Runner;',
    '			productReference = 97C146EE1CF9000F007C117D /* Runner.app */;',
    '			productType = "com.apple.product-type.application";',
    '		};',
    '/* End PBXNativeTarget section */',
  ].join('\n');
}
String unmigratedNativeTargetSectionAsJson({bool missingPackageProductDependencies = false}) {
  return <String>[
    '    "97C146ED1CF9000F007C117D" : {',
    '      "buildConfigurationList" : "97C147051CF9000F007C117D",',
    '      "buildPhases" : [',
    '        "9740EEB61CF901F6004384FC",',
    '        "97C146EA1CF9000F007C117D",',
    '        "97C146EB1CF9000F007C117D",',
    '        "97C146EC1CF9000F007C117D",',
    '        "9705A1C41CF9048500538489",',
    '        "3B06AD1E1E4923F5004D2608"',
    '      ],',
    '      "buildRules" : [',
    '      ],',
    '      "dependencies" : [',
    '      ],',
    '      "isa" : "PBXNativeTarget",',
    '      "name" : "Runner",',
    if (!missingPackageProductDependencies)
      ...<String>[
        '      "packageProductDependencies" : [',
        '      ],',
      ],
    '      "productName" : "Runner",',
    '      "productReference" : "97C146EE1CF9000F007C117D",',
    '      "productType" : "com.apple.product-type.application"',
    '    }',
  ].join('\n');
}
const String migratedNativeTargetSectionAsJson = '''
    "97C146ED1CF9000F007C117D" : {
      "buildConfigurationList" : "97C147051CF9000F007C117D",
      "buildPhases" : [
        "9740EEB61CF901F6004384FC",
        "97C146EA1CF9000F007C117D",
        "97C146EB1CF9000F007C117D",
        "97C146EC1CF9000F007C117D",
        "9705A1C41CF9048500538489",
        "3B06AD1E1E4923F5004D2608"
      ],
      "buildRules" : [

      ],
      "dependencies" : [

      ],
      "isa" : "PBXNativeTarget",
      "name" : "Runner",
      "packageProductDependencies" : [
        "78A3181F2AECB46A00862997"
      ],
      "productName" : "Runner",
      "productReference" : "97C146EE1CF9000F007C117D",
      "productType" : "com.apple.product-type.application"
    }''';

// PBXProject
String unmigratedProjectSection({bool missingPackageReferences = false, bool withOtherReference = false}) {
  return <String>[
    '/* Begin PBXProject section */',
    '		97C146E61CF9000F007C117D /* Project object */ = {',
    '			isa = PBXProject;',
    '			attributes = {',
    '				BuildIndependentTargetsInParallel = YES;',
    '				LastUpgradeCheck = 1510;',
    '				ORGANIZATIONNAME = "";',
    '				TargetAttributes = {',
    '					331C8080294A63A400263BE5 = {',
    '						CreatedOnToolsVersion = 14.0;',
    '						TestTargetID = 97C146ED1CF9000F007C117D;',
    '					};',
    '					97C146ED1CF9000F007C117D = {',
    '						CreatedOnToolsVersion = 7.3.1;',
    '						LastSwiftMigration = 1100;',
    '					};',
    '				};',
    '			};',
    '			buildConfigurationList = 97C146E91CF9000F007C117D /* Build configuration list for PBXProject "Runner" */;',
    '			compatibilityVersion = "Xcode 9.3";',
    '			developmentRegion = en;',
    '			hasScannedForEncodings = 0;',
    '			knownRegions = (',
    '				en,',
    '				Base,',
    '			);',
    '			mainGroup = 97C146E51CF9000F007C117D;',
    if (!missingPackageReferences)
      ...<String>[
        '			packageReferences = (',
        if (withOtherReference)
          '				010101010101010101010101 /* XCLocalSwiftPackageReference "SomeOtherPackage" */,',
        '			);',
      ],
    '			productRefGroup = 97C146EF1CF9000F007C117D /* Products */;',
    '			projectDirPath = "";',
    '			projectRoot = "";',
    '			targets = (',
    '				97C146ED1CF9000F007C117D /* Runner */,',
    '				331C8080294A63A400263BE5 /* RunnerTests */,',
    '			);',
    '		};',
    '/* End PBXProject section */',
  ].join('\n');
}
String migratedProjectSection({bool missingPackageReferences = false, bool withOtherReference = false}) {
  final List<String> packageDependencies = <String>[
    '			packageReferences = (',
    '				781AD8BC2B33823900A9FFBB /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */,',
    if (withOtherReference)
      '				010101010101010101010101 /* XCLocalSwiftPackageReference "SomeOtherPackage" */,',
    '			);',
  ];
    return <String>[
    '/* Begin PBXProject section */',
    '		97C146E61CF9000F007C117D /* Project object */ = {',
    if (missingPackageReferences)
      ...packageDependencies,
    '			isa = PBXProject;',
    '			attributes = {',
    '				BuildIndependentTargetsInParallel = YES;',
    '				LastUpgradeCheck = 1510;',
    '				ORGANIZATIONNAME = "";',
    '				TargetAttributes = {',
    '					331C8080294A63A400263BE5 = {',
    '						CreatedOnToolsVersion = 14.0;',
    '						TestTargetID = 97C146ED1CF9000F007C117D;',
    '					};',
    '					97C146ED1CF9000F007C117D = {',
    '						CreatedOnToolsVersion = 7.3.1;',
    '						LastSwiftMigration = 1100;',
    '					};',
    '				};',
    '			};',
    '			buildConfigurationList = 97C146E91CF9000F007C117D /* Build configuration list for PBXProject "Runner" */;',
    '			compatibilityVersion = "Xcode 9.3";',
    '			developmentRegion = en;',
    '			hasScannedForEncodings = 0;',
    '			knownRegions = (',
    '				en,',
    '				Base,',
    '			);',
    '			mainGroup = 97C146E51CF9000F007C117D;',
    if (!missingPackageReferences)
      ...packageDependencies,
    '			productRefGroup = 97C146EF1CF9000F007C117D /* Products */;',
    '			projectDirPath = "";',
    '			projectRoot = "";',
    '			targets = (',
    '				97C146ED1CF9000F007C117D /* Runner */,',
    '				331C8080294A63A400263BE5 /* RunnerTests */,',
    '			);',
    '		};',
    '/* End PBXProject section */',
  ].join('\n');
}
String unmigratedProjectSectionAsJson({bool missingPackageReferences = false}) {
  return <String>[
    '    "97C146E61CF9000F007C117D" : {',
    '      "attributes" : {',
    '        "BuildIndependentTargetsInParallel" : "YES",',
    '        "LastUpgradeCheck" : "1510",',
    '        "ORGANIZATIONNAME" : "",',
    '        "TargetAttributes" : {',
    '          "97C146ED1CF9000F007C117D" : {',
    '            "CreatedOnToolsVersion" : "7.3.1",',
    '            "LastSwiftMigration" : "1100"',
    '          },',
    '          "331C8080294A63A400263BE5" : {',
    '            "CreatedOnToolsVersion" : "14.0",',
    '            "TestTargetID" : "97C146ED1CF9000F007C117D"',
    '          }',
    '        }',
    '      },',
    '      "buildConfigurationList" : "97C146E91CF9000F007C117D",',
    '      "compatibilityVersion" : "Xcode 9.3",',
    '      "developmentRegion" : "en",',
    '      "hasScannedForEncodings" : "0",',
    '      "isa" : "PBXProject",',
    '      "knownRegions" : [',
    '        "en",',
    '        "Base"',
    '      ],',
    '      "mainGroup" : "97C146E51CF9000F007C117D",',
    if (!missingPackageReferences)
      ...<String>[
        '      "packageReferences" : [',
        '      ],',
      ],
    '      "productRefGroup" : "97C146EF1CF9000F007C117D",',
    '      "projectDirPath" : "",',
    '      "projectRoot" : "",',
    '      "targets" : [',
    '        "97C146ED1CF9000F007C117D",',
    '        "331C8080294A63A400263BE5"',
    '      ]',
    '    }',
  ].join('\n');
}
const String migratedProjectSectionAsJson = '''
    "97C146E61CF9000F007C117D" : {
      "attributes" : {
        "BuildIndependentTargetsInParallel" : "YES",
        "LastUpgradeCheck" : "1510",
        "ORGANIZATIONNAME" : "",
        "TargetAttributes" : {
          "97C146ED1CF9000F007C117D" : {
            "CreatedOnToolsVersion" : "7.3.1",
            "LastSwiftMigration" : "1100"
          },
          "331C8080294A63A400263BE5" : {
            "CreatedOnToolsVersion" : "14.0",
            "TestTargetID" : "97C146ED1CF9000F007C117D"
          }
        }
      },
      "buildConfigurationList" : "97C146E91CF9000F007C117D",
      "compatibilityVersion" : "Xcode 9.3",
      "developmentRegion" : "en",
      "hasScannedForEncodings" : "0",
      "isa" : "PBXProject",
      "knownRegions" : [
        "en",
        "Base"
      ],
      "mainGroup" : "97C146E51CF9000F007C117D",
      "packageReferences" : [
        "781AD8BC2B33823900A9FFBB"
      ],
      "productRefGroup" : "97C146EF1CF9000F007C117D",
      "projectDirPath" : "",
      "projectRoot" : "",
      "targets" : [
        "97C146ED1CF9000F007C117D",
        "331C8080294A63A400263BE5"
      ]
    }''';

// XCLocalSwiftPackageReference
String unmigratedLocalSwiftPackageReferenceSection({bool withOtherReference = false}) {
  return <String>[
    '/* Begin XCLocalSwiftPackageReference section */',
    if (withOtherReference)
      ...<String>[
      '		010101010101010101010101 /* XCLocalSwiftPackageReference "SomeOtherPackage" */ = {',
      '			isa = XCLocalSwiftPackageReference;',
      '			relativePath = SomeOtherPackage;',
      '		};',
      ],
    '/* End XCLocalSwiftPackageReference section */',
  ].join('\n');
}
String migratedLocalSwiftPackageReferenceSection({bool withOtherReference = false}) {
  return <String>[
    '/* Begin XCLocalSwiftPackageReference section */',
    if (withOtherReference)
      ...<String>[
      '		010101010101010101010101 /* XCLocalSwiftPackageReference "SomeOtherPackage" */ = {',
      '			isa = XCLocalSwiftPackageReference;',
      '			relativePath = SomeOtherPackage;',
      '		};',
      ],
    '		781AD8BC2B33823900A9FFBB /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */ = {',
    '			isa = XCLocalSwiftPackageReference;',
    '			relativePath = Flutter/Packages/FlutterPackage;',
    '		};',
    '/* End XCLocalSwiftPackageReference section */',
  ].join('\n');
}
const String migratedLocalSwiftPackageReferenceSectionAsJson = '''
    "781AD8BC2B33823900A9FFBB" : {
      "isa" : "XCLocalSwiftPackageReference",
      "relativePath" : "Flutter/Packages/FlutterPackage"
    }''';

// XCSwiftPackageProductDependency
String unmigratedSwiftPackageProductDependencySection({bool withOtherDependency = false}) {
  return <String>[
    '/* Begin XCSwiftPackageProductDependency section */',
    if (withOtherDependency)
      ...<String>[
      '		010101010101010101010101 /* SomeOtherPackage */ = {',
      '			isa = XCSwiftPackageProductDependency;',
      '			productName = SomeOtherPackage;',
      '		};',
      ],
    '/* End XCSwiftPackageProductDependency section */',
  ].join('\n');
}
String migratedSwiftPackageProductDependencySection({bool withOtherDependency = false}) {
  return <String>[
    '/* Begin XCSwiftPackageProductDependency section */',
    if (withOtherDependency)
      ...<String>[
      '		010101010101010101010101 /* SomeOtherPackage */ = {',
      '			isa = XCSwiftPackageProductDependency;',
      '			productName = SomeOtherPackage;',
      '		};',
      ],
      '		78A3181F2AECB46A00862997 /* FlutterPackage */ = {',
      '			isa = XCSwiftPackageProductDependency;',
      '			productName = FlutterPackage;',
      '		};',
    '/* End XCSwiftPackageProductDependency section */',
  ].join('\n');
}
const String migratedSwiftPackageProductDependencySectionAsJson = '''
    "78A3181F2AECB46A00862997" : {
      "isa" : "XCSwiftPackageProductDependency",
      "productName" : "FlutterPackage"
    }''';

class FakeXcodeProjectInterpreter extends Fake implements XcodeProjectInterpreter {
  FakeXcodeProjectInterpreter({
    Version? xcodeVersion,
    this.throwErrorOnGetInfo = false,
  }): version = xcodeVersion ?? Version(15, 0, 0);

  @override
  Version version;

  @override
  bool isInstalled = false;

  @override
  List<String> xcrunCommand() => <String>['xcrun'];

  final bool throwErrorOnGetInfo;

  @override
  Future<XcodeProjectInfo?> getInfo(String projectPath, {String? projectFilename}) async {
    if (throwErrorOnGetInfo) {
      throwToolExit('Unable to get Xcode project information');
    }
    return null;
  }
}

class FakeIosProject extends Fake implements IosProject {

  FakeIosProject({
    required MemoryFileSystem fileSystem,
  }) : hostAppRoot = fileSystem.directory('app_name').childDirectory('ios'),
       parent = FakeFlutterProject(fileSystem: fileSystem),
       xcodeProjectInfoFile = fileSystem.directory('app_name').childDirectory('ios').childDirectory('Runner.xcodeproj').childFile('project.pbxproj');

  @override
  FakeFlutterProject parent;

  @override
  Directory hostAppRoot;

  @override
  File xcodeProjectInfoFile;

  @override
  String hostAppProjectName = 'Runner';
}

class FakeFlutterProject extends Fake implements FlutterProject {
  FakeFlutterProject({
    required MemoryFileSystem fileSystem,
  }) : directory = fileSystem.directory('app_name');

  @override
  Directory directory;
}

// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:io';
import 'package:meta/meta.dart';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/template.dart';
import '../base/user_messages.dart';
import '../cache.dart';
import '../convert.dart';
import '../macos/xcode.dart';
import '../template.dart';

/// A class to handle interacting with Xcode via Mac Scripting to debug
/// applications.
class XcodeDebug {
  XcodeDebug({
    required Logger logger,
    required ProcessManager processManager,
    required Xcode xcode,
    required FileSystem fileSystem,
    required UserMessages userMessages,
    String? flutterRoot,
  })  : _logger = logger,
        _processUtils = ProcessUtils(logger: logger, processManager: processManager),
        _xcode = xcode,
        _fileSystem = fileSystem,
        _userMessage = userMessages,
        _flutterRoot = flutterRoot ?? Cache.flutterRoot!;


  final ProcessUtils _processUtils;
  final Logger _logger;
  final Xcode _xcode;
  final FileSystem _fileSystem;
  final UserMessages _userMessage;
  final String _flutterRoot;

  /// Process to start a debug session. The process will exit once the debug session has been started.
  @visibleForTesting
  Process? startDebugSessionProcess;

  // Information about the project that is currently being debugged. Will become null once the debug session is stopped.
  @visibleForTesting
  XcodeDebugProject? currentDebuggingProject;

  bool get debugStarted => currentDebuggingProject != null;

  String get pathToXcodeApp {
    final String? pathToXcode = _xcode.xcodeSelectPath;
    if (pathToXcode == null || pathToXcode.isEmpty) {
      throwToolExit(_userMessage.xcodeMissing);
    }
    final int index = pathToXcode.indexOf('.app');
    if (index == -1) {
      throwToolExit(_userMessage.xcodeMissing);
    }
    return pathToXcode.substring(0, index + 4);
  }

  String get pathToXcodeAutomationScript {
    final String flutterToolsAbsolutePath = _fileSystem.path.join(
      _flutterRoot,
      'packages',
      'flutter_tools',
    );
    return '$flutterToolsAbsolutePath/bin/xcode_debug.js';
  }

  Future<bool> debugApp({
    required XcodeDebugProject project,
    required String deviceId,
    required List<String> launchArguments,
  }) async {

    // If project is not already opened in Xcode, open it.
    if (!await _isProjectOpenInXcode(xcodeProject: project.xcodeProject, xcodeWorkspace: project.xcodeWorkspace)) {
      final bool openResult = await _openProjectInXcode(xcodeWorkspace: project.xcodeWorkspace);
      if (!openResult) {
        return openResult;
      }
    }

    currentDebuggingProject = project;
    startDebugSessionProcess = await _processUtils.start(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'debug',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        project.xcodeProject.path,
        '--workspace-path',
        project.xcodeWorkspace.path,
        '--device-id',
        deviceId,
        '--scheme',
        project.scheme,
        '--skip-building',
        '--launch-args',
        json.encode(launchArguments),
      ],
    );

    String stdout = '';

    final StreamSubscription<String> stdoutSubscription = startDebugSessionProcess!.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          _logger.printTrace(line);
          stdout += line;
    });

    String stderr = '';
    final StreamSubscription<String> stderrSubscription = startDebugSessionProcess!.stderr
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          _logger.printTrace('err: $line');
          stderr += line;
    });

    final int exitCode = await startDebugSessionProcess!.exitCode.whenComplete(() async {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      startDebugSessionProcess = null;
    });

    if (exitCode != 0) {
      _logger.printError('Error executing osascript: $exitCode\n$stderr');
      return false;
    }

    final XcodeAutomationScriptResponse? response = parseScriptResponse(stdout);
    if (response == null) {
      return false;
    }
    if (response.status == false) {
      _logger.printError('Error starting debug session in Xcode: ${response.errorMessage}');
      return false;
    }
    if (response.debugResult == null) {
      _logger.printError('Unable to get debug results from response: $stdout');
      return false;
    }
    if (response.debugResult?.status != 'running') {
      _logger.printError(
        'Unexpected debug results: \n'
        '  Status: ${response.debugResult?.status}\n'
        '  Completed: ${response.debugResult?.completed}\n'
        '  Error Message: ${response.debugResult?.errorMessage}\n'
      );
      return false;
    }
    return true;
  }

  Future<bool> exit({
    @visibleForTesting
    bool skipDelay = false,
  }) async {
    final bool success = (startDebugSessionProcess == null) || startDebugSessionProcess!.kill();

    if (currentDebuggingProject != null) {
      final XcodeDebugProject project = currentDebuggingProject!;
      await stopDebuggingApp(
        xcodeWorkspace: project.xcodeWorkspace,
        xcodeProject: project.xcodeProject,
        closeXcode: project.isTemporaryProject,
      );

      if (project.isTemporaryProject) {
        // Wait a couple seconds before deleting the project. If project is
        // still opened in Xcode and it's deleted, it will prompt the user to
        // restore it.
        if (!skipDelay) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }

        try {
          project.xcodeProject.parent.deleteSync(recursive: true);
        } on FileSystemException {
          _logger.printError('Failed to delete temporary Xcode project: ${project.xcodeProject.parent.path}');
        }
      }
      currentDebuggingProject = null;
    }

    return success;
  }

  Future<bool> _isProjectOpenInXcode({
    required Directory xcodeWorkspace,
    required Directory xcodeProject,
  }) async {

    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'project-opened',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        xcodeProject.path,
        '--workspace-path',
        xcodeWorkspace.path,
      ],
      throwOnError: true,
    );

    if (result.exitCode != 0) {
      _logger.printError('Error executing osascript: ${result.exitCode}\n${result.stderr}');
      return false;
    }

    final XcodeAutomationScriptResponse? response = parseScriptResponse(result.stdout);
    if (response == null) {
      return false;
    }
    if (response.status == false) {
      _logger.printTrace('Error checking if project opened in Xcode: ${response.errorMessage}');
      return false;
    }
    return true;
  }

  @visibleForTesting
  XcodeAutomationScriptResponse? parseScriptResponse(String results) {
    try {
      final Object decodeResult = json.decode(results) as Object;
      if (decodeResult is Map<String, Object?>) {
        final XcodeAutomationScriptResponse response = XcodeAutomationScriptResponse.fromJson(decodeResult);
        if (response.status != null) {
          return response;
        }
      }
      _logger.printError('osascript returned unexpected JSON response: $results');
      return null;
    } on FormatException {
      _logger.printError('osascript returned non-JSON response: $results');
      return null;
    }
  }

  Future<bool> _openProjectInXcode({
    required Directory xcodeWorkspace,
  }) async {
    try {
      await _processUtils.run(
        <String>[
          'open',
          '-a',
          pathToXcodeApp,
          // '-n', // Open a new instance of the application(s) even if one is already running.
          // '-F', // Opens the application "fresh," that is, without restoring windows. Saved persistent state is lost, except for Untitled documents.
          '-g', // Do not bring the application to the foreground.
          '-j', // Launches the app hidden.
          xcodeWorkspace.path
        ],
        throwOnError: true,
      );
      return true;
    } on ProcessException catch (error, stackTrace) {
      _logger.printError('$error', stackTrace: stackTrace);
    }
    return false;
  }

  Future<bool> stopDebuggingApp({
    required Directory xcodeWorkspace,
    required Directory xcodeProject,
    bool closeXcode = false,
    bool promptToSaveOnClose = false,
  }) async {
    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'stop',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        xcodeProject.path,
        '--workspace-path',
        xcodeWorkspace.path,
        if (closeXcode) '--close-window',
        if (promptToSaveOnClose) '--prompt-to-save'
      ],
      throwOnError: true,
    );

    if (result.exitCode != 0) {
      _logger.printError('Error executing osascript: ${result.exitCode}\n${result.stderr}');
      return false;
    }

    final XcodeAutomationScriptResponse? response = parseScriptResponse(result.stdout);
    if (response == null) {
      return false;
    }
    if (response.status == false) {
      _logger.printError('Error stopping app in Xcode: ${response.errorMessage}');
      return false;
    }
    return true;
  }

  Future<XcodeDebugProject> createXcodeProjectWithCustomBundle(
    String deviceBundlePath, {
    required TemplateRenderer templateRenderer,
    @visibleForTesting
    Directory? projectDestination,
  }) async {
    final Directory tempXcodeProject = projectDestination ?? _fileSystem.systemTempDirectory.createTempSync('flutter_empty_xcode.');

    final Template template = await Template.fromName(
      _fileSystem.path.join('xcode', 'ios', 'custom_application_bundle'),
      fileSystem: _fileSystem,
      templateManifest: null,
      logger: _logger,
      templateRenderer: templateRenderer,
    );

    template.render(
      tempXcodeProject,
      <String, Object>{
        'applicationBundlePath': deviceBundlePath
      },
      printStatusWhenWriting: false,
    );

    return XcodeDebugProject(
      scheme: 'Runner',
      xcodeProject: tempXcodeProject.childDirectory('Runner.xcodeproj'),
      xcodeWorkspace: tempXcodeProject.childDirectory('Runner.xcworkspace'),
      isTemporaryProject: true,
    );
  }
}

@visibleForTesting
class XcodeAutomationScriptResponse {
  XcodeAutomationScriptResponse._({
    this.status,
    this.errorMessage,
    this.debugResult,
  });

  factory XcodeAutomationScriptResponse.fromJson(Map<String, Object?> data) {
    XcodeAutomationScriptDebugResult? debugResult;
    if (data['debugResult'] != null && data['debugResult'] is Map<String, Object?>) {
      debugResult = XcodeAutomationScriptDebugResult.fromJson(
        data['debugResult']! as Map<String, Object?>,
      );
    }
    return XcodeAutomationScriptResponse._(
      status: data['status'] is bool? ? data['status'] as bool? : null,
      errorMessage: data['errorMessage']?.toString(),
      debugResult: debugResult,
    );
  }

  final bool? status;
  final String? errorMessage;
  final XcodeAutomationScriptDebugResult? debugResult;
}

@visibleForTesting
class XcodeAutomationScriptDebugResult {
  XcodeAutomationScriptDebugResult._({
    required this.completed,
    required this.status,
    required this.errorMessage,
  });

  factory XcodeAutomationScriptDebugResult.fromJson(Map<String, Object?> data) {
    return XcodeAutomationScriptDebugResult._(
      completed: data['completed'] is bool? ? data['completed'] as bool? : null,
      status: data['status']?.toString(),
      errorMessage: data['errorMessage']?.toString(),
    );
  }

  final bool? completed; // Whether this scheme action has completed (sucessfully or otherwise) or not. Will be false if still running
  final String? status; // (not yet started/‌running/‌cancelled/‌failed/‌error occurred/‌succeeded) : Indicates the status of the scheme action.
  final String? errorMessage; //If the result's status is "error occurred", this will be the error message; otherwise, this will be "missing value".
}

class XcodeDebugProject {
  XcodeDebugProject({
    required this.scheme,
    required this.xcodeWorkspace,
    required this.xcodeProject,
    this.isTemporaryProject = false,
  });

  final String scheme;
  final Directory xcodeWorkspace;
  final Directory xcodeProject;
  final bool isTemporaryProject;

}

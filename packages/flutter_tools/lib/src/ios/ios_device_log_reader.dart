// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

import '../base/io.dart';
import '../base/version.dart';
import '../convert.dart';
import '../device.dart';
import '../macos/xcode.dart';
import '../vmservice.dart';
import 'application_package.dart';
import 'core_devices.dart';
import 'ios_deploy.dart';
import 'mac.dart';

/// Decodes a vis-encoded syslog string to a UTF-8 representation.
///
/// Apple's syslog logs are encoded in 7-bit form. Input bytes are encoded as follows:
/// 1. 0x00 to 0x19: non-printing range. Some ignored, some encoded as <...>.
/// 2. 0x20 to 0x7f: as-is, with the exception of 0x5c (backslash).
/// 3. 0x5c (backslash): octal representation \134.
/// 4. 0x80 to 0x9f: \M^x (using control-character notation for range 0x00 to 0x40).
/// 5. 0xa0: octal representation \240.
/// 6. 0xa1 to 0xf7: \M-x (where x is the input byte stripped of its high-order bit).
/// 7. 0xf8 to 0xff: unused in 4-byte UTF-8.
///
/// See: [vis(3) manpage](https://www.freebsd.org/cgi/man.cgi?query=vis&sektion=3)
String decodeSyslog(String line) {
  // UTF-8 values for \, M, -, ^.
  const kBackslash = 0x5c;
  const kM = 0x4d;
  const kDash = 0x2d;
  const kCaret = 0x5e;

  // Mask for the UTF-8 digit range.
  const kNum = 0x30;

  // Returns true when `byte` is within the UTF-8 7-bit digit range (0x30 to 0x39).
  bool isDigit(int byte) => (byte & 0xf0) == kNum;

  // Converts a three-digit ASCII (UTF-8) representation of an octal number `xyz` to an integer.
  int decodeOctal(int x, int y, int z) => (x & 0x3) << 6 | (y & 0x7) << 3 | z & 0x7;

  try {
    final List<int> bytes = utf8.encode(line);
    final out = <int>[];
    for (var i = 0; i < bytes.length;) {
      if (bytes[i] != kBackslash || i > bytes.length - 4) {
        // Unmapped byte: copy as-is.
        out.add(bytes[i++]);
      } else {
        // Mapped byte: decode next 4 bytes.
        if (bytes[i + 1] == kM && bytes[i + 2] == kCaret) {
          // \M^x form: bytes in range 0x80 to 0x9f.
          out.add((bytes[i + 3] & 0x7f) + 0x40);
        } else if (bytes[i + 1] == kM && bytes[i + 2] == kDash) {
          // \M-x form: bytes in range 0xa0 to 0xf7.
          out.add(bytes[i + 3] | 0x80);
        } else if (bytes.getRange(i + 1, i + 3).every(isDigit)) {
          // \ddd form: octal representation (only used for \134 and \240).
          out.add(decodeOctal(bytes[i + 1], bytes[i + 2], bytes[i + 3]));
        } else {
          // Unknown form: copy as-is.
          out.addAll(bytes.getRange(0, 4));
        }
        i += 4;
      }
    }
    return utf8.decode(out);
  } on Exception {
    // Unable to decode line: return as-is.
    return line;
  }
}

class IOSDeviceLogReader extends DeviceLogReader {
  IOSDeviceLogReader._(
    this._xcode,
    this._iMobileDevice,
    this._majorSdkVersion,
    this._deviceId,
    this.name,
    this._isWirelesslyConnected,
    this._isCoreDevice,
    String appName,
  ) : // Match for lines for the runner in syslog.
      //
      // iOS 9 format:  Runner[297] <Notice>:
      // iOS 10 format: Runner(Flutter)[297] <Notice>:
      _runnerLineRegex = RegExp(appName + r'(\(Flutter\))?\[[\d]+\] <[A-Za-z]+>: ');

  /// Create a new [IOSDeviceLogReader].
  factory IOSDeviceLogReader.create({
    required String deviceId,
    required int majorSdkVersion,
    required String deviceName,
    required bool isWirelesslyConnected,
    required bool isCoreDevice,
    IOSApp? app,
    required IMobileDevice iMobileDevice,
    required Xcode xcode,
  }) {
    final String appName = app?.name?.replaceAll('.app', '') ?? '';
    return IOSDeviceLogReader._(
      xcode,
      iMobileDevice,
      majorSdkVersion,
      deviceId,
      deviceName,
      isWirelesslyConnected,
      isCoreDevice,
      appName,
    );
  }

  /// Create an [IOSDeviceLogReader] for testing.
  factory IOSDeviceLogReader.test({
    required IMobileDevice iMobileDevice,
    required Xcode xcode,
    bool useSyslog = true,
    int? majorSdkVersion,
    bool isWirelesslyConnected = false,
    bool isCoreDevice = false,
  }) {
    final int sdkVersion = majorSdkVersion ?? (useSyslog ? 12 : 13);
    return IOSDeviceLogReader._(
      xcode,
      iMobileDevice,
      sdkVersion,
      '1234',
      'test',
      isWirelesslyConnected,
      isCoreDevice,
      'Runner',
    );
  }

  @override
  final String name;
  final int _majorSdkVersion;
  final String _deviceId;
  final bool _isWirelesslyConnected;
  final bool _isCoreDevice;
  final IMobileDevice _iMobileDevice;
  final Xcode _xcode;

  RegExp _runnerLineRegex;

  @visibleForTesting
  late final linesController = StreamController<String>.broadcast(
    onListen: _startLoggers,
    onCancel: dispose,
  );

  // Sometimes (race condition?) we try to send a log after the controller has
  // been closed. See https://github.com/flutter/flutter/issues/99021 for more
  // context.
  @visibleForTesting
  void addToLinesController(String message, IOSDeviceLogSource source) {
    if (!linesController.isClosed) {
      if (_excludeLog(message, source)) {
        return;
      }
      linesController.add(message);
    }
  }

  /// Used to track messages prefixed with "flutter:" from the fallback log source.
  final _fallbackStreamFlutterMessages = <String>[];

  /// Used to track if a message prefixed with "flutter:" has been received from the primary log.
  var primarySourceFlutterLogReceived = false;

  /// There are three potential logging sources: `idevicesyslog`, `ios-deploy`,
  /// and Unified Logging (Dart VM). When using more than one of these logging
  /// sources at a time, prefer to use the primary source. However, if the
  /// primary source is not working, use the fallback.
  bool _excludeLog(String message, IOSDeviceLogSource source) {
    // If no fallback, don't exclude any logs.
    if (logSources.fallbackSource == null) {
      return false;
    }

    // If log is from primary source, don't exclude it unless the fallback was
    // quicker and added the message first.
    if (source == logSources.primarySource) {
      if (!primarySourceFlutterLogReceived && message.startsWith('flutter:')) {
        primarySourceFlutterLogReceived = true;
      }

      // If the message was already added by the fallback, exclude it to
      // prevent duplicates.
      final bool foundAndRemoved = _fallbackStreamFlutterMessages.remove(message);
      if (foundAndRemoved) {
        return true;
      }
      return false;
    }

    // If a flutter log was received from the primary source, that means it's
    // working so don't use any messages from the fallback.
    if (primarySourceFlutterLogReceived) {
      return true;
    }

    // When using logs from fallbacks, skip any logs not prefixed with "flutter:".
    // This is done because different sources often have different prefixes for
    // non-flutter messages, which makes duplicate matching difficult. Also,
    // non-flutter messages are not critical for CI tests.
    if (!message.startsWith('flutter:')) {
      return true;
    }

    _fallbackStreamFlutterMessages.add(message);
    return false;
  }

  @override
  Stream<String> get logLines => linesController.stream;

  final _unifiedLoggingSourceStrategy = _UnifiedLoggingSourceStrategy();
  final _iosDeploySourceStrategy = _IOSDeployLogSourceStrategy();
  late final _syslogSourceStrategy = _SyslogLogSourceStrategy(_iMobileDevice);
  final _coreDeviceLoggingSourceStrategy = _CoreDeviceLoggingSourceStrategy();

  Future<void> _startLoggers() async {
    // syslog is the only logger currently that can be run independent of an app process.
    await listenToSyslog();
  }

  @override
  Future<void> provideVmService(FlutterVmService connectedVmService) async {
    if (!useUnifiedLogging) {
      return;
    }
    _unifiedLoggingSourceStrategy.provideVmService(connectedVmService);
    await _unifiedLoggingSourceStrategy.listenToLogs(addToLinesController);
  }

  Future<void> listenToIOSDeploy(IOSDeployDebugger debugger) async {
    if (!useIOSDeployLogging) {
      return;
    }
    _iosDeploySourceStrategy.debuggerStream = debugger;
    await _iosDeploySourceStrategy.listenToLogs(addToLinesController, linesController);
  }

  Future<void> listenToCoreDeviceConsole(IOSCoreDeviceLogger debugger) async {
    if (!useCoreDeviceLogging) {
      return;
    }
    _coreDeviceLoggingSourceStrategy.coreDeviceDebugger = debugger;
    await _coreDeviceLoggingSourceStrategy.listenToLogs(addToLinesController, linesController);
  }

  Future<void> listenToSyslog() async {
    if (!useSyslogLogging) {
      return;
    }
    await _syslogSourceStrategy.listenToLogs(
      addToLinesController,
      linesController,
      _runnerLineRegex,
      _deviceId,
      _isWirelesslyConnected,
    );
  }

  static const minimumUniversalLoggingSdkVersion = 13;

  /// Determine the primary and fallback source for device logs.
  ///
  /// There are three potential logging sources: `idevicesyslog`, `ios-deploy`,
  /// and Unified Logging (Dart VM).
  @visibleForTesting
  _IOSDeviceLogSources get logSources {
    if (_isCoreDevice) {
      final Version? xcodeVersion = _xcode.currentVersion;
      if (xcodeVersion != null && xcodeVersion.major >= 26) {
        return _IOSDeviceLogSources(
          primarySource: IOSDeviceLogSource.devicectlConsole,
          fallbackSource: IOSDeviceLogSource.unifiedLogging,
        );
      }
      if (_isWirelesslyConnected) {
        return _IOSDeviceLogSources(primarySource: IOSDeviceLogSource.unifiedLogging);
      }
      return _IOSDeviceLogSources(
        primarySource: IOSDeviceLogSource.idevicesyslog,
        fallbackSource: IOSDeviceLogSource.unifiedLogging,
      );
    }
    if (_majorSdkVersion < minimumUniversalLoggingSdkVersion) {
      return _IOSDeviceLogSources(primarySource: IOSDeviceLogSource.idevicesyslog);
    }

    if (_unifiedLoggingSourceStrategy._connectedVmService != null &&
        !_iosDeploySourceStrategy.debuggerAttached) {
      return _IOSDeviceLogSources(
        primarySource: IOSDeviceLogSource.unifiedLogging,
        fallbackSource: IOSDeviceLogSource.iosDeploy,
      );
    }

    return _IOSDeviceLogSources(
      primarySource: IOSDeviceLogSource.iosDeploy,
      fallbackSource: IOSDeviceLogSource.unifiedLogging,
    );
  }

  /// Whether `idevicesyslog` is used as either the primary or fallback source for device logs.
  @visibleForTesting
  bool get useSyslogLogging {
    return logSources.primarySource == IOSDeviceLogSource.idevicesyslog ||
        logSources.fallbackSource == IOSDeviceLogSource.idevicesyslog;
  }

  /// Whether the Dart VM is used as either the primary or fallback source for device logs.
  ///
  /// Unified Logging only works after the Dart VM has been connected to.
  @visibleForTesting
  bool get useUnifiedLogging {
    return logSources.primarySource == IOSDeviceLogSource.unifiedLogging ||
        logSources.fallbackSource == IOSDeviceLogSource.unifiedLogging;
  }

  /// Whether `ios-deploy` is used as either the primary or fallback source for device logs.
  @visibleForTesting
  bool get useIOSDeployLogging {
    return logSources.primarySource == IOSDeviceLogSource.iosDeploy ||
        logSources.fallbackSource == IOSDeviceLogSource.iosDeploy;
  }

  @visibleForTesting
  bool get useCoreDeviceLogging {
    return logSources.primarySource == IOSDeviceLogSource.devicectlConsole ||
        logSources.fallbackSource == IOSDeviceLogSource.devicectlConsole;
  }

  @override
  void dispose() {
    _unifiedLoggingSourceStrategy.dispose();
    _iosDeploySourceStrategy.dispose();
    _syslogSourceStrategy.dispose();
    _coreDeviceLoggingSourceStrategy.dispose();
  }
}

enum IOSDeviceLogSource {
  /// Gets logs from ios-deploy debugger.
  iosDeploy,

  /// Gets logs from idevicesyslog.
  idevicesyslog,

  /// Gets logs from the Dart VM Service.
  unifiedLogging,

  devicectlConsole,
}

class _IOSDeviceLogSources {
  _IOSDeviceLogSources({required this.primarySource, this.fallbackSource});

  final IOSDeviceLogSource primarySource;
  final IOSDeviceLogSource? fallbackSource;
}

class _CoreDeviceLoggingSourceStrategy {
  IOSCoreDeviceLogger? coreDeviceDebugger;
  final _loggingSubscriptions = <StreamSubscription<void>>[];

  // /// Listen to Dart VM for logs on iOS 13 or greater.
  Future<void> listenToLogs(
    void Function(String, IOSDeviceLogSource) onLogMessage,
    StreamController<String> linesController,
  ) async {
    final IOSCoreDeviceLogger? debugger = coreDeviceDebugger;
    if (debugger == null) {
      return;
    }

    // Add the debugger logs to the controller created on initialization.
    _loggingSubscriptions.add(
      debugger.logLines.listen(
        (String line) => onLogMessage(line, IOSDeviceLogSource.devicectlConsole),
        onError: linesController.addError,
        onDone: linesController.close,
        cancelOnError: true,
      ),
    );
  }

  void dispose() {
    for (final StreamSubscription<void> loggingSubscription in _loggingSubscriptions) {
      loggingSubscription.cancel();
    }
  }
}

class _UnifiedLoggingSourceStrategy {
  FlutterVmService? _connectedVmService;
  final _loggingSubscriptions = <StreamSubscription<void>>[];

  // ignore: use_setters_to_change_properties
  void provideVmService(FlutterVmService connectedVmService) {
    _connectedVmService = connectedVmService;
  }

  /// Listen to Dart VM for logs on iOS 13 or greater.
  Future<void> listenToLogs(void Function(String, IOSDeviceLogSource) onLogMessage) async {
    final FlutterVmService? connectedVmService = _connectedVmService;
    if (connectedVmService == null) {
      return;
    }
    try {
      // The VM service will not publish logging events unless the debug stream is being listened to.
      // Listen to this stream as a side effect.
      unawaited(connectedVmService.service.streamListen('Debug'));

      await Future.wait(<Future<void>>[
        connectedVmService.service.streamListen(vm_service.EventStreams.kStdout),
        connectedVmService.service.streamListen(vm_service.EventStreams.kStderr),
      ]);
    } on vm_service.RPCError {
      // Do nothing, since the tool is already subscribed.
    }

    void logMessage(vm_service.Event event) {
      final String message = processVmServiceMessage(event);
      if (message.isNotEmpty) {
        onLogMessage(message, IOSDeviceLogSource.unifiedLogging);
      }
    }

    _loggingSubscriptions.addAll(<StreamSubscription<void>>[
      connectedVmService.service.onStdoutEvent.listen(logMessage),
      connectedVmService.service.onStderrEvent.listen(logMessage),
    ]);
  }

  void dispose() {
    for (final StreamSubscription<void> loggingSubscription in _loggingSubscriptions) {
      loggingSubscription.cancel();
    }
  }
}

class _SyslogLogSourceStrategy {
  _SyslogLogSourceStrategy(IMobileDevice iMobileDevice) : _iMobileDevice = iMobileDevice;

  final IMobileDevice _iMobileDevice;

  final _loggingSubscriptions = <StreamSubscription<void>>[];

  @visibleForTesting
  Process? idevicesyslogProcess;

  // Similar to above, but allows ~arbitrary components instead of "Runner"
  // and "Flutter". The regex tries to strike a balance between not producing
  // false positives and not producing false negatives.
  final _anyLineRegex = RegExp(r'\w+(\([^)]*\))?\[\d+\] <[A-Za-z]+>: ');

  Future<void> listenToLogs(
    void Function(String, IOSDeviceLogSource) onLogMessage,
    StreamController<String> linesController,
    RegExp runningLineRegex,
    String deviceId,
    bool isWirelesslyConnected,
  ) async {
    await _iMobileDevice.startLogger(deviceId, isWirelesslyConnected).then<void>((Process process) {
      process.stdout
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen(_newSyslogLineHandler(onLogMessage, runningLineRegex));
      process.stderr
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen(_newSyslogLineHandler(onLogMessage, runningLineRegex));
      process.exitCode.whenComplete(() {
        // if (!linesController.hasListener) {
        //   return;
        // }
        // // When using both log readers, do not close the stream on exit.
        // // This is to allow ios-deploy to be the source of authority to close
        // // the stream.
        // if (useSyslogLogging && useIOSDeployLogging && debuggerStream != null) {
        //   return;
        // }
        // linesController.close();
      });
      assert(idevicesyslogProcess == null);
      idevicesyslogProcess = process;
    });
  }

  // Returns a stateful line handler to properly capture multiline output.
  //
  // For multiline log messages, any line after the first is logged without
  // any specific prefix. To properly capture those, we enter "printing" mode
  // after matching a log line from the runner. When in printing mode, we print
  // all lines until we find the start of another log message (from any app).
  void Function(String line) _newSyslogLineHandler(
    void Function(String, IOSDeviceLogSource) onLogMessage,
    RegExp runningLineRegex,
  ) {
    var printing = false;

    return (String line) {
      if (printing) {
        if (!_anyLineRegex.hasMatch(line)) {
          onLogMessage(decodeSyslog(line), IOSDeviceLogSource.idevicesyslog);
          return;
        }

        printing = false;
      }

      final Match? match = runningLineRegex.firstMatch(line);

      if (match != null) {
        final String logLine = line.substring(match.end);
        // Only display the log line after the initial device and executable information.
        onLogMessage(decodeSyslog(logLine), IOSDeviceLogSource.idevicesyslog);
        printing = true;
      }
    };
  }

  void dispose() {
    for (final StreamSubscription<void> loggingSubscription in _loggingSubscriptions) {
      loggingSubscription.cancel();
    }
    idevicesyslogProcess?.kill();
  }
}

class _IOSDeployLogSourceStrategy {
  IOSDeployDebugger? _iosDeployDebugger;

  final _loggingSubscriptions = <StreamSubscription<void>>[];

  /// Log reader will listen to [IOSDeployDebugger.logLines] and
  /// will detach debugger on dispose.
  IOSDeployDebugger? get debuggerStream => _iosDeployDebugger;

  bool get debuggerAttached => _iosDeployDebugger?.debuggerAttached ?? false;

  /// Send messages from ios-deploy debugger stream to device log reader stream.
  set debuggerStream(IOSDeployDebugger? debugger) {
    // Logging is gathered from syslog on iOS earlier than 13.
    _iosDeployDebugger = debugger;
  }

  Future<void> listenToLogs(
    void Function(String, IOSDeviceLogSource) onLogMessage,
    StreamController<String> linesController,
  ) async {
    final IOSDeployDebugger? debugger = _iosDeployDebugger;
    if (debugger == null) {
      return;
    }

    // Add the debugger logs to the controller created on initialization.
    _loggingSubscriptions.add(
      debugger.logLines.listen(
        (String line) =>
            onLogMessage(_debuggerLineHandler(line), IOSDeviceLogSource.devicectlConsole),
        onError: linesController.addError,
        onDone: linesController.close,
        cancelOnError: true,
      ),
    );
  }

  // Logging from native code/Flutter engine is prefixed by timestamp and process metadata:
  // 2020-09-15 19:15:10.931434-0700 Runner[541:226276] Did finish launching.
  // 2020-09-15 19:15:10.931434-0700 Runner[541:226276] [Category] Did finish launching.
  //
  // Logging from the dart code has no prefixing metadata.
  final _debuggerLoggingRegex = RegExp(r'^\S* \S* \S*\[[0-9:]*] (.*)');

  // Strip off the logging metadata (leave the category), or just echo the line.
  String _debuggerLineHandler(String line) =>
      _debuggerLoggingRegex.firstMatch(line)?.group(1) ?? line;

  void dispose() {
    for (final StreamSubscription<void> loggingSubscription in _loggingSubscriptions) {
      loggingSubscription.cancel();
    }
    _iosDeployDebugger?.detach();
  }
}

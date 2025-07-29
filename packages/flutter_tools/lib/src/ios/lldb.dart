// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import '../base/common.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../convert.dart';
import '../globals.dart';

///
/// xcrun devicectl device process launch --help
/// Once the application has launched, you can attach to it using LLDB. For example, if you have an iPhone named 'iPhone' connected to
/// your Mac, and your application running on the iPhone has the process identifier of 10684, you can debug your application using the
/// following steps:

/// $ xcrun lldb
/// (lldb) device select iPhone
/// (lldb) device process attach -p 10684
class LLDB {
  LLDB({required Logger logger, required ProcessUtils processUtils})
    : _logger = logger,
      _processUtils = processUtils;

  final Logger _logger;
  final ProcessUtils _processUtils;

  _LLDBProcess? _lldbProcess;

  bool get isRunning => _lldbProcess != null;

  int? get processId => _lldbProcess?.processId;

  _LLDBLogWaiter? _logWaiter;

  // (lldb) Process 6152 stopped
  static final RegExp _lldbProcessStopped = RegExp(r'Process \d* stopped');

  // (lldb) Process 6152 detached
  static final RegExp _lldbProcessDetached = RegExp(r'Process \d* detached');

  // (lldb) Process 6152 resuming
  static final RegExp _lldbProcessResuming = RegExp(r'Process \d+ resuming');

  static const String _processResume = 'process continue';

  // Print backtrace for all threads while app is stopped.
  static const String _backTraceAll = 'thread backtrace all';

  static const String _pythonScript = '''
"""Intercept NOTIFY_DEBUGGER_ABOUT_RX_PAGES and touch the pages."""
base = frame.register["x0"].GetValueAsAddress()
page_len = frame.register["x1"].GetValueAsUnsigned()

# Note: NOTIFY_DEBUGGER_ABOUT_RX_PAGES will check contents of the
# first page to see if handled it correctly. This makes diagnosing
# misconfiguration (e.g. missing breakpoint) easier.
data = bytearray(page_len)
data[0:8] = b'IHELPED!'

error = lldb.SBError()
frame.GetThread().GetProcess().WriteMemory(base, data, error)
if not error.Success():
    print(f'Failed to write into {base}[+{page_len}]', error)
    return

# If the returned value is False, that tells LLDB not to stop at the breakpoint
return False
''';

  Future<bool> launchAndAttach(String deviceId, int processId) async {
    final bool start = await _startLLDB(processId);
    if (!start) {
      return false;
    }
    try {
      await _selectDevice(deviceId);

      // Can either use init file or set breakpoint, need to decide which
      await _addInitFile();
      await _setBreakpoint();

      await _attachToAppProcess(processId);
      await _resumeProcess();
    } on SocketException catch (error) {
      _logger.printTrace('lldb failed: $error');
      return false;
    }

    return true;
  }

  Future<bool> _startLLDB(int processId) async {
    try {
      _lldbProcess = _LLDBProcess(
        process: await _processUtils.start(<String>['lldb']),
        processId: processId,
        logger: logger,
      );

      final StreamSubscription<String> stdoutSubscription = _lldbProcess!.stdout
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen((String line) {
            print(line);
            _logWaiter?.checkForMatch(line);
          });

      final StreamSubscription<String> stderrSubscription = _lldbProcess!.stderr
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen((String line) {
            _logger.printTrace('[stderr] $line');
          });

      unawaited(
        _lldbProcess!.exitCode
            .then((int status) async {
              _logger.printTrace('lldb exited with code $exitCode');
              await stdoutSubscription.cancel();
              await stderrSubscription.cancel();
            })
            .whenComplete(() async {
              _lldbProcess = null;
            }),
      );
    } on ProcessException catch (exception) {
      _logger.printError('Process exception running lldb:\n$exception');
      return false;
    } on ArgumentError catch (exception) {
      _logger.printError('Process exception running lldb:\n$exception');
      return false;
    }
    return true;
  }

  Future<void> detach() async {
    return _lldbProcess?.stdinWriteln(
      'process detach',
      onError: (Object error, _) {
        // Best effort, try to detach, but maybe the app already exited or already detached.
        _logger.printTrace('Could not detach from debugger: $error');
      },
    );
  }

  bool exit() {
    final bool success = (_lldbProcess == null) || _lldbProcess!.kill();
    _lldbProcess = null;
    return success;
  }

  Future<void> _selectDevice(String deviceId) async {
    await _lldbProcess?.stdinWriteln('device select $deviceId');
  }

  Future<void> _attachToAppProcess(int processId) async {
    await _lldbProcess?.stdinWriteln('device process attach --pid $processId');
    await _waitForLog(_lldbProcessStopped);
  }

  Future<void> _addInitFile() async {
    // await _lldbProcess?.stdinWriteln(r'command source path/to/.lldbinit');
  }

  Future<void> _setBreakpoint() async {
    await _lldbProcess?.stdinWriteln(r"breakpoint set -r '^NOTIFY_DEBUGGER_ABOUT_RX_PAGES$'");
    final String breakpoint = await _waitForLog(RegExp(r'Breakpoint \d*:'));
    final Match? match = RegExp(r'Breakpoint (\d)*:').firstMatch(breakpoint);
    final String? breakpointId = match?.group(1);
    if (breakpointId == null) {
      throwToolExit('Failed to set breakpoint');
    }
    await _lldbProcess?.stdinWriteln('breakpoint command add -s p $breakpointId');
    await _lldbProcess?.stdinWriteln(_pythonScript);
    await _lldbProcess?.stdinWriteln('DONE');
  }

  Future<void> _resumeProcess() async {
    await _lldbProcess?.stdinWriteln(_processResume);
    await _waitForLog(_lldbProcessResuming);
  }

  Future<String> _waitForLog(RegExp pattern) async {
    _logWaiter = _LLDBLogWaiter(pattern);
    return _logWaiter!.waitForLog();
  }
}

class _LLDBLogWaiter {
  _LLDBLogWaiter(RegExp pattern) : _waitCompleter = Completer<String>(), _waitingFor = pattern;
  final RegExp _waitingFor;
  final Completer<String> _waitCompleter;

  Future<String> waitForLog() async {
    return _waitCompleter.future;
  }

  void checkForMatch(String line) {
    if (_waitingFor.hasMatch(line)) {
      _waitCompleter.complete(line);
    }
  }
}

class _LLDBProcess {
  _LLDBProcess({required Process process, required this.processId, required Logger logger})
    : _lldbProcess = process,
      _logger = logger;

  final Process _lldbProcess;
  final int processId;

  final Logger _logger;

  Stream<List<int>> get stdout => _lldbProcess.stdout;

  Stream<List<int>> get stderr => _lldbProcess.stderr;

  Future<int> get exitCode => _lldbProcess.exitCode;

  Future<void>? _stdinWriteFuture;

  bool kill() {
    return _lldbProcess.kill();
  }

  Future<void> stdinWriteln(String line, {void Function(Object, StackTrace)? onError}) async {
    Future<void> writeln() {
      return ProcessUtils.writelnToStdinGuarded(
        stdin: _lldbProcess.stdin,
        line: line,
        onError:
            onError ??
            (Object error, _) {
              _logger.printTrace('Could not write "$line" to stdin: $error');
            },
      );
    }

    _stdinWriteFuture = _stdinWriteFuture?.then<void>((_) => writeln()) ?? writeln();
    return _stdinWriteFuture;
  }
}

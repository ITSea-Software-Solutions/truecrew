import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../biometric/driver.dart';
import '../core/scope.dart';
import '../data/db.dart';
import 'gate_result.dart';
import 'silent_snap.dart';

/// Runs a full identify pass inside a fresh isolate — Windows direct-SDK
/// capture is a BLOCKING FFI call, and hands-free mode would freeze the UI
/// without this. Top-level so it is sendable to Isolate.run.
Future<IdentifyResult?> _isolateIdentify(
    List<Map<String, Object?>> candidates) async {
  return SgfpDirectDriver().identify(candidates);
}

/// Gate mode — fingerprint identify → confirm IN/OUT. Works fully offline
/// (SIM identify against the locally-cached deployed workers; marks queue).
///
/// HANDS-FREE mode: keeps the scanner armed — a worker just places a finger
/// and the mark happens automatically (auto IN/OUT by last state, verified
/// card auto-dismisses, 90s per-worker cooldown against double-marks).
class GateAttendanceScreen extends StatefulWidget {
  const GateAttendanceScreen({super.key});
  @override
  State<GateAttendanceScreen> createState() => _GateAttendanceScreenState();
}

class _GateAttendanceScreenState extends State<GateAttendanceScreen>
    with WidgetsBindingObserver {
  bool _scanning = false;
  String? _status;

  // Hands-free loop state
  bool _handsFree = false;
  bool _loopRunning = false;
  bool _appPaused = false;
  bool _showingResult = false;
  final Map<Object, DateTime> _recentMarks = {};
  static const _cooldown = Duration(seconds: 90);
  /// How long the verified card waits for the gate camera before showing the
  /// registration photo instead. The mark itself never waits.
  static const _proofGrace = Duration(milliseconds: 1200);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocalDb.getMeta('handsfree').then((v) {
      if (v == '1' && mounted) {
        setState(() => _handsFree = true);
        _runLoop();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _handsFree = false; // stops the loop on its next iteration
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appPaused = state != AppLifecycleState.resumed;
  }

  /// One capture+match attempt. Windows direct SDK blocks the calling
  /// isolate, so it runs via Isolate.run; other drivers are already async.
  Future<IdentifyResult?> _identifyOnce(
      BiometricDriver driver, List<Map<String, Object?>> candidates) {
    if (driver is SgfpDirectDriver) {
      return Isolate.run(() => _isolateIdentify(candidates));
    }
    return driver.identify(candidates);
  }

  Object _cooldownKey(Map<String, Object?> w) =>
      w['server_id'] ?? w['client_uuid'] ?? w['name'] ?? w;

  Future<void> _toggleHandsFree(bool on) async {
    final driver = await BiometricDriver.best();
    if (on && driver is SimDriver) {
      setState(() => _status =
          'Hands-free needs a real scanner — connect one first (simulation would mark random workers).');
      return;
    }
    await LocalDb.setMeta('handsfree', on ? '1' : null);
    if (!mounted) return;
    setState(() {
      _handsFree = on;
      _status = on ? null : _status;
    });
    if (on) _runLoop();
  }

  /// The kiosk loop: wait for a finger → auto-mark → brief settle → repeat.
  Future<void> _runLoop() async {
    if (_loopRunning) return;
    _loopRunning = true;
    var consecutiveFailures = 0;
    try {
      while (mounted && _handsFree) {
        if (_appPaused || _showingResult) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        if (!mounted) break;
        final app = AppScope.of(context);
        final candidates = await app.deployedWorkers();
        if (candidates.isEmpty) {
          if (mounted) {
            setState(() =>
                _status = 'No active workers deployed here today. Sync first?');
          }
          await Future.delayed(const Duration(seconds: 6));
          continue;
        }
        final driver = await BiometricDriver.best();
        if (driver is SimDriver) {
          await _toggleHandsFree(false);
          break;
        }
        if (mounted && _status != null) setState(() => _status = null);
        if (mounted && !_scanning) setState(() => _scanning = true);

        IdentifyResult? result;
        try {
          result = await _identifyOnce(driver, candidates);
        } catch (_) {
          result = null;
        }
        if (!mounted || !_handsFree) break;

        if (result == null) {
          // No finger in this window / no clear match — quietly keep waiting.
          consecutiveFailures++;
          await Future.delayed(Duration(
              milliseconds: consecutiveFailures > 30 ? 2500 : 600));
          continue;
        }
        consecutiveFailures = 0;

        final key = _cooldownKey(result.worker);
        final last = _recentMarks[key];
        if (last != null && DateTime.now().difference(last) < _cooldown) {
          setState(() => _status =
              '${result!.worker['name']} was marked moments ago — next worker, please.');
          await Future.delayed(const Duration(milliseconds: 1800));
          continue;
        }

        _showingResult = true;
        try {
          await _autoMark(result);
          _recentMarks[key] = DateTime.now();
        } finally {
          _showingResult = false;
        }
        await Future.delayed(const Duration(milliseconds: 700));
      }
    } finally {
      _loopRunning = false;
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Hands-free mark: no confirm dialog — auto IN/OUT by last state, proof
  /// photo, then the auto-dismissing verified card.
  Future<void> _autoMark(IdentifyResult result) async {
    final app = AppScope.of(context);
    final worker = result.worker;
    final proofFuture = silentSnap();
    final type = await app.nextTypeFor(worker['server_id'] as int? ?? -1);
    // The mark is written the moment the finger verifies. The camera used to
    // sit in front of it: a wedged driver could hold the gate for 16 seconds
    // (4s enumerate + 6s init + 6s capture) with the worker already matched.
    final uuid = await app.markAttendance(
      worker: worker,
      type: type,
      method: 'fingerprint',
      score: result.score,
      simulated: result.simulated,
    );
    // Proof attaches whenever the camera finishes; the uploader picks it up.
    proofFuture
        .then((p) => app.attachProof(uuid, p))
        .catchError((_) {});
    // The card gets a short chance to show the live shot — a healthy camera
    // makes it — and otherwise falls back to the registration photo.
    final quickProof = await proofFuture
        .timeout(_proofGrace, onTimeout: () => null)
        .catchError((_) => null);
    if (!mounted) return;
    setState(() => _status = null);
    await showGateResult(
      context,
      name: worker['name'] as String,
      type: type,
      workerServerId: worker['server_id'] as int?,
      score: result.score,
      simulated: result.simulated,
      queuedOffline: !app.online,
      proofPath: quickProof,
    );
  }

  Future<void> _scan() async {
    final app = AppScope.of(context);
    setState(() {
      _scanning = true;
      _status = 'Place finger on scanner…';
    });
    try {
      final candidates = await app.deployedWorkers();
      if (candidates.isEmpty) {
        setState(() =>
            _status = 'No active workers deployed here today. Sync first?');
        return;
      }
      final driver = await BiometricDriver.best();
      var result = await _identifyOnce(driver, candidates);
      if (result == null && driver is! SimDriver) {
        // Real capture but NO match ≥ threshold (or candidates lack synced
        // templates). Operator may still record manually — proof photo and
        // score 0 make the manual override auditable.
        final withTpl = candidates
            .where((w) => (w['fingerprint_template'] as String?)?.isNotEmpty ?? false)
            .length;
        setState(() => _status = withTpl == 0
            ? 'No fingerprint templates on this device yet — Sync first, then rescan.'
            : 'No match ≥ ${BiometricDriver.matchThreshold} among $withTpl enrolled worker(s).');
        final picked = await _pickWorker(candidates);
        if (picked == null) return;
        result = IdentifyResult(picked, 0, simulated: false);
      }
      if (result == null) {
        setState(() => _status = 'Capture failed — try again.');
        return;
      }
      if (!mounted) return;
      await _confirm(result);
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<Map<String, Object?>?> _pickWorker(
      List<Map<String, Object?>> candidates) async {
    return showModalBottomSheet<Map<String, Object?>>(
      context: context,
      builder: (context) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('MANUAL OVERRIDE — no automatic match. Select the worker (recorded with score 0 + gate photo):',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final w in candidates)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(w['name'] as String),
              subtitle: Text('${w['aadhaar_masked'] ?? ''}'),
              onTap: () => Navigator.pop(context, w),
            ),
        ],
      ),
    );
  }

  Future<void> _confirm(IdentifyResult result) async {
    final app = AppScope.of(context);
    final worker = result.worker;
    // Fingerprint verified → quietly photograph the person at the gate while
    // the operator confirms. Proof attaches to the mark; never blocks it.
    final proofFuture = silentSnap();
    final suggested = await app.nextTypeFor(worker['server_id'] as int? ?? -1);
    if (!mounted) return;
    final type = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(worker['name'] as String),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${worker['aadhaar_masked'] ?? ''}'),
            const SizedBox(height: 6),
            Text(result.simulated
                ? 'Simulated match · score ${result.score}/200'
                : 'Fingerprint captured'),
            const SizedBox(height: 12),
            Text('Mark $suggested?',
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          if (suggested == 'OUT')
            TextButton(
                onPressed: () => Navigator.pop(context, 'IN'),
                child: const Text('IN instead')),
          if (suggested == 'IN')
            TextButton(
                onPressed: () => Navigator.pop(context, 'OUT'),
                child: const Text('OUT instead')),
          FilledButton(
              onPressed: () => Navigator.pop(context, suggested),
              child: Text('Mark $suggested')),
        ],
      ),
    );
    if (type == null) return;
    // Same rule as the hands-free path: the mark never waits on the camera.
    // The dialog usually covered the snap already; if it did not, the card
    // shows the registration photo and the proof attaches when it lands.
    final uuid = await app.markAttendance(
      worker: worker,
      type: type,
      method: 'fingerprint',
      score: result.score,
      simulated: result.simulated,
    );
    proofFuture
        .then((p) => app.attachProof(uuid, p))
        .catchError((_) {});
    final proofPath = await proofFuture
        .timeout(_proofGrace, onTimeout: () => null)
        .catchError((_) => null);
    if (mounted) {
      setState(() => _status = null);
      // The "verified" moment: check + all three photos + greeting.
      await showGateResult(
        context,
        name: worker['name'] as String,
        type: type,
        workerServerId: worker['server_id'] as int?,
        score: result.score,
        simulated: result.simulated,
        queuedOffline: !app.online,
        proofPath: proofPath,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(120),
              onTap: (_scanning || _handsFree) ? null : _scan,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF10685A).withValues(alpha: .1),
                  border: Border.all(color: const Color(0xFF10685A), width: 3),
                ),
                child: _handsFree
                    ? const Icon(Icons.fingerprint,
                        size: 110, color: Color(0xFF10685A))
                    : _scanning
                        ? const Padding(
                            padding: EdgeInsets.all(60),
                            child: CircularProgressIndicator())
                        : const Icon(Icons.fingerprint,
                            size: 110, color: Color(0xFF10685A)),
              ),
            ),
            const SizedBox(height: 18),
            Text(
                _handsFree
                    ? 'Ready — place finger anytime'
                    : (_scanning ? 'Scanning…' : 'Tap to scan'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            // Kiosk mode: scanner stays armed, marks happen automatically.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Hands-free auto scan'),
                subtitle: const Text(
                    'Marks automatically when a finger is placed — no taps'),
                value: _handsFree,
                onChanged: (v) => _toggleHandsFree(v),
              ),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                child: Text(_status!, textAlign: TextAlign.center),
              ),
            const SizedBox(height: 10),
            Text(
              app.user?['location_name'] != null
                  ? 'Gate: ${app.user?['location_name']}'
                  : 'Main gate',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Workers currently inside (last event IN) — from local data.
class ExceptionsScreen extends StatefulWidget {
  const ExceptionsScreen({super.key});

  @override
  State<ExceptionsScreen> createState() => _ExceptionsScreenState();

  static String fmt(Object? iso) => _ExceptionsScreenState.fmt(iso);
}

class _ExceptionsScreenState extends State<ExceptionsScreen> {
  Future<void> _manualOut(Map<String, Object?> r) async {
    final app = AppScope.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Mark ${r['worker_name']} OUT?'),
        content: const Text(
            'Records a manual OUT now (for workers who left without scanning). The log shows it was manual and by whom.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Mark OUT')),
        ],
      ),
    );
    if (sure != true) return;
    String msg;
    try {
      msg = await app.manualOut(r['worker_server_id'] as int);
    } catch (e) {
      msg = AppState.apiMessage(e, 'Manual OUT failed — retry.');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return FutureBuilder(
      future: app.currentlyInside(),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (snap.connectionState == ConnectionState.done && rows.isEmpty) {
          return const Center(child: Text('Nobody is currently inside.'));
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = rows[i];
            return ListTile(
              leading: const Icon(Icons.login, color: Colors.teal),
              title: Text('${r['worker_name']}'),
              subtitle: Text('IN since ${fmt(r['last_at'])}'),
              // Company HR/admin only — vendors never get manual OUT.
              trailing: (app.isApprover &&
                      app.online &&
                      r['worker_server_id'] != null)
                  ? TextButton.icon(
                      onPressed: () => _manualOut(r),
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text('Mark OUT'),
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  static String fmt(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    if (d == null) return '?';
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }
}

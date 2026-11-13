import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Calls [onTimeout] after [timeout] without a pointer or keyboard event
/// anywhere below it (short admin sessions, spec section 7).
class IdleTimeout extends StatefulWidget {
  const IdleTimeout({required this.timeout, required this.onTimeout, required this.child, super.key});

  final Duration timeout;
  final VoidCallback onTimeout;
  final Widget child;

  @override
  State<IdleTimeout> createState() => _IdleTimeoutState();
}

class _IdleTimeoutState extends State<IdleTimeout> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _restart();
  }

  @override
  void didUpdateWidget(IdleTimeout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeout != widget.timeout) {
      _restart();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _timer?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _restart();
    return false;
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(widget.timeout, widget.onTimeout);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _restart(),
    onPointerHover: (_) => _restart(),
    onPointerSignal: (_) => _restart(),
    child: widget.child,
  );
}

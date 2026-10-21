import 'package:flutter/services.dart';

typedef OnRfidScannedCallback = void Function(String rfidCode);

class RfidScannerListener {
  final OnRfidScannedCallback onScanned;
  final StringBuffer _buffer = StringBuffer();
  DateTime _lastKeystroke = DateTime.now();
  int _lastEventHash = 0;

  RfidScannerListener({required this.onScanned});

  void start() {
    HardwareKeyboard.instance.addHandler(processKeyEvent);
  }

  void stop() {
    HardwareKeyboard.instance.removeHandler(processKeyEvent);
  }

  bool processKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // Prevent duplicate processing if both Focus and HardwareKeyboard fire for the same event
    final eventHash = Object.hash(event.logicalKey, event.timeStamp);
    if (eventHash == _lastEventHash) return false;
    _lastEventHash = eventHash;

    final now = DateTime.now();
    // Timeout to clear buffer if typing is interrupted (generous 4s for manual testing)
    if (now.difference(_lastKeystroke).inMilliseconds > 4000) {
      _buffer.clear();
    }
    _lastKeystroke = now;

    // Check for Enter key (signaling end of RFID scan / card swipe)
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString().trim();
      _buffer.clear();
      if (code.isNotEmpty) {
        onScanned(code);
        return true; // Handled
      }
      return false;
    }

    // Extract character from event.character, or fallback to logicalKey / numpad
    String? char = event.character;
    if (char == null || char.isEmpty) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
        char = '0';
      } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
        char = '1';
      } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
        char = '2';
      } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
        char = '3';
      } else if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
        char = '4';
      } else if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
        char = '5';
      } else if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
        char = '6';
      } else if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
        char = '7';
      } else if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
        char = '8';
      } else if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
        char = '9';
      } else if (key.keyLabel.length == 1) {
        char = key.keyLabel;
      }
    }

    if (char != null && char.isNotEmpty && !char.contains(RegExp(r'[\r\n]'))) {
      _buffer.write(char);
    }

    return false;
  }
}

import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

const _white = TextStyle(color: Colors.white);

/// Two-button decision dialog in the app's dark style. Resolves true for the
/// confirm button, false for cancel, null when dismissed (only possible with
/// [dismissible]).
Future<bool?> showChoiceDialog(
  BuildContext context, {
  required String title,
  String? body,
  Widget? content,
  String cancelText = 'Cancel',
  String confirmText = 'OK',
  Color? confirmColor,
  bool dismissible = false,
}) {
  final navigator = Navigator.of(context);
  return showDialog<bool>(
    context: context,
    barrierDismissible: dismissible,
    builder: (_) => PopScope(
      canPop: dismissible,
      child: AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text(title, style: _white),
        content: content ?? Text(body ?? '', style: _white),
        actions: [
          Row(
            children: [
              Expanded(
                child: _DialogButton(cancelText, AppColors.button, () => navigator.pop(false)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _DialogButton(
                    confirmText, confirmColor ?? AppColors.button, () => navigator.pop(true)),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Single-button notice.
Future<void> showInfoDialog(BuildContext context, {required String title, required String body}) {
  final navigator = Navigator.of(context);
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.sheet,
      title: Text(title, style: _white),
      content: Text(body, style: _white),
      actions: [_DialogButton('OK', AppColors.button, navigator.pop)],
    ),
  );
}

/// Ask for a short text; null when cancelled.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String hint,
  String confirmText = 'Save',
}) {
  final controller = TextEditingController();
  final navigator = Navigator.of(context);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.sheet,
      title: Text(title, style: _white),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: _white,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: navigator.pop,
      ),
      actions: [
        TextButton(onPressed: () => navigator.pop(null), child: const Text('Cancel')),
        TextButton(onPressed: () => navigator.pop(controller.text), child: Text(confirmText)),
      ],
    ),
  );
}

/// Dark modal bottom sheet used by the Home editors (team, clock).
Future<void> showDarkSheet(BuildContext context,
    {required double heightFactor, required Widget child}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: heightFactor,
      child: Container(
        color: AppColors.sheet,
        // Clear the gesture bar so the last line of a scrolled sheet is reachable.
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewPaddingOf(context).bottom),
        child: child,
      ),
    ),
  );
}

class _DialogButton extends StatelessWidget {
  const _DialogButton(this.label, this.color, this.onPressed);
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: color),
        onPressed: onPressed,
        child: Text(label, style: _white),
      );
}

/// Grey action button with white text: the app's standard secondary button.
class AppButton extends StatelessWidget {
  const AppButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = ElevatedButton.styleFrom(backgroundColor: AppColors.button);
    final text = Text(label, style: _white, overflow: TextOverflow.fade);
    return icon == null
        ? ElevatedButton(style: style, onPressed: onPressed, child: text)
        : ElevatedButton.icon(
            style: style, onPressed: onPressed, icon: Icon(icon, color: Colors.white), label: text);
  }
}

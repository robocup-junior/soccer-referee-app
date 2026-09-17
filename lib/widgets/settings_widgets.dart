import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

/// One labelled option of a settings dropdown.
class SetItem {
  const SetItem(this.name, this.values);
  final String name;
  final int values;

  @override
  bool operator ==(Object other) =>
      other is SetItem && other.values == values && other.name == name;

  @override
  int get hashCode => Object.hash(name, values);
}

/// A card grouping settings rows. [locked] greys the card out (settings that
/// must not change mid-match); [enabled]/[onToggle] add a master switch that
/// hides the rows when off.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.settings,
    this.locked = false,
    this.enabled,
    this.onToggle,
  });

  final String title;
  final List<Widget> settings;
  final bool locked;
  final bool? enabled;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: locked,
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 10),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      if (enabled != null && onToggle != null)
                        Switch(
                            value: enabled!,
                            onChanged: onToggle,
                            activeThumbColor: Colors.blue),
                      if (locked) const Icon(Icons.lock, color: Colors.white),
                    ]),
                if (enabled ?? true) ...settings,
              ],
            ),
          ),
        ),
      );
}

/// Label on the left, [trailing] on the right: the shape of every row.
class SettingRow extends StatelessWidget {
  const SettingRow(
      {super.key,
      required this.title,
      required this.trailing,
      this.labelFlex = 3,
      this.trailingFlex = 2});
  final Widget title;
  final Widget trailing;
  final int labelFlex;
  final int trailingFlex;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(flex: labelFlex, child: title),
            Expanded(flex: trailingFlex, child: trailing),
          ],
        ),
      );
}

class SettingDropdownButton extends StatelessWidget {
  const SettingDropdownButton({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final SetItem value;
  final List<SetItem> options;
  final ValueChanged<SetItem?> onChanged;

  @override
  Widget build(BuildContext context) => SettingRow(
        title: Text(title),
        labelFlex: 5,
        trailing: DropdownButton<SetItem>(
          value: value,
          onChanged: onChanged,
          items: [
            for (final item in options)
              DropdownMenuItem(value: item, child: Text(item.name)),
          ],
        ),
      );
}

class SettingButton extends StatelessWidget {
  const SettingButton(
      {super.key,
      required this.title,
      required this.buttonText,
      required this.onPressed});
  final String title;
  final String buttonText;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SettingRow(
        title: Text(title),
        trailing: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.button),
          child: Text(buttonText, style: const TextStyle(color: Colors.white)),
        ),
      );
}

class SettingStatus extends StatelessWidget {
  const SettingStatus({super.key, required this.title, required this.status});
  final String title;
  final String status;

  @override
  Widget build(BuildContext context) => SettingRow(
        title: Text(title),
        trailingFlex: 3,
        trailing: Text(status,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.right),
      );
}

class SettingSwitch extends StatelessWidget {
  const SettingSwitch(
      {super.key,
      required this.title,
      required this.value,
      required this.onChanged,
      this.subtitle});
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => SettingRow(
        labelFlex: 5,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(subtitle!,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
          ],
        ),
        trailing: Switch(
            value: value, onChanged: onChanged, activeThumbColor: Colors.blue),
      );
}

/// Multi-select chips for alert thresholds (seconds remaining).
class SettingAlertChips extends StatelessWidget {
  const SettingAlertChips(
      {super.key,
      required this.label,
      required this.options,
      required this.selected,
      required this.onToggle});
  final String label;
  final List<int> options;
  final Set<int> selected;
  final void Function(int) onToggle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final sec in options)
                  FilterChip(
                    label: Text(sec == 0 ? '0 (end)' : '${sec}s'),
                    selected: selected.contains(sec),
                    onSelected: (_) => onToggle(sec),
                    selectedColor: Colors.blue,
                    checkmarkColor: Colors.white,
                    labelStyle: TextStyle(
                        color: selected.contains(sec) ? Colors.white : null),
                  ),
              ],
            ),
          ],
        ),
      );
}

/// Text field row. Keeps its own controller so typing survives rebuilds; a
/// password shows in clear only while focused.
class SettingInputField extends StatefulWidget {
  const SettingInputField({
    super.key,
    required this.title,
    required this.initialValue,
    required this.onChanged,
    this.isPassword = false,
    this.inputFormatters,
    this.maxLength,
    this.hintText,
  });

  final String title;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final bool isPassword;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final String? hintText;

  @override
  State<SettingInputField> createState() => _SettingInputFieldState();
}

class _SettingInputFieldState extends State<SettingInputField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.isPassword) _focusNode.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant SettingInputField old) {
    super.didUpdateWidget(old);
    if (widget.initialValue != old.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingRow(
        title: Text(widget.title),
        trailingFlex: 4,
        trailing: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: widget.onChanged,
          obscureText: widget.isPassword && !_focusNode.hasFocus,
          inputFormatters: widget.inputFormatters,
          maxLength: widget.maxLength,
          buildCounter: (_,
                  {required currentLength, required isFocused, maxLength}) =>
              null,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            filled: true,
            fillColor: AppColors.sheet,
            hintText: widget.hintText,
            hintStyle: const TextStyle(color: Colors.grey),
          ),
        ),
      );
}

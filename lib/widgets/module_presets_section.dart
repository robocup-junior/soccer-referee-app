import 'package:flutter/material.dart';
import 'package:rcj_scoreboard/models/game.dart';
import 'package:rcj_scoreboard/services/preset_service.dart';
import 'package:rcj_scoreboard/widgets/app_dialogs.dart';
import 'package:rcj_scoreboard/widgets/settings_widgets.dart';

/// Settings card: save the current robot pairings as a named preset, or load /
/// delete a saved one.
class ModulePresetsSection extends StatefulWidget {
  const ModulePresetsSection({super.key, required this.game});
  final Game game;

  @override
  State<ModulePresetsSection> createState() => _ModulePresetsSectionState();
}

class _ModulePresetsSectionState extends State<ModulePresetsSection> {
  final PresetService _service = PresetService();
  List<GamePreset>? _presets;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final presets = await _service.loadAll();
    if (mounted) setState(() => _presets = presets);
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final name = await showTextInputDialog(context,
        title: 'Save Preset',
        label: 'Preset name',
        hint: 'e.g. My team robots');
    if (name == null || name.trim().isEmpty) return;
    final preset = widget.game.createPreset(name.trim());
    await _service.save(preset);
    await _reload();
    if (mounted) _snack('Preset "${preset.name}" saved');
  }

  void _load(GamePreset preset) {
    widget.game.applyPreset(preset);
    _snack('Loaded "${preset.name}" – connecting robots...');
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    return SettingsSection(
      title: 'Module Presets',
      settings: [
        SettingButton(
            title: 'Save current robot configuration',
            buttonText: 'Save',
            onPressed: _save),
        if (presets == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (presets.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('No presets saved yet.',
                style: TextStyle(color: Colors.grey, fontSize: 14)),
          )
        else
          for (final preset in presets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child: Text(preset.name,
                          style: const TextStyle(fontSize: 14))),
                  TextButton(
                      onPressed: () => _load(preset),
                      child: const Text('Load')),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await _service.delete(preset.id);
                      await _reload();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

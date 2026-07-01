import 'package:flutter/material.dart';

import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/widgets/inspection_status_badge.dart';

/// A compact per-robot inspection list: one row per [InspectionRobot] showing
/// "Robot N", its status badge (green cleared / red failed / neutral grey dash
/// for missing/unknown), and its note when present. Informational only.
///
/// Renders nothing for an empty list (an unresolved side or a non-inspecting
/// league), so callers can drop it in unconditionally.
class InspectionRobotList extends StatelessWidget {
  final List<InspectionRobot> robots;

  const InspectionRobotList({super.key, required this.robots});

  @override
  Widget build(BuildContext context) {
    if (robots.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in robots)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Robot ${r.robot}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(width: 6),
                InspectionStatusBadge(status: r.status),
                if (r.note.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '· ${r.note}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

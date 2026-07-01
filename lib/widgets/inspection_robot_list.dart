import 'package:flutter/material.dart';

import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/widgets/inspection_status_badge.dart';

/// A per-robot inspection list: for each [InspectionRobot], "Robot N" + its
/// status badge (green cleared / red failed / neutral grey dash for
/// missing/unknown) on one line, and its note — when present — on its own line
/// below so a long comment wraps full-width instead of crowding the status.
/// Informational only.
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
            padding: const EdgeInsets.only(top: 8, left: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Robot N" + status badge on one line.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Robot ${r.robot}',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(width: 8),
                    InspectionStatusBadge(status: r.status),
                  ],
                ),
                // The note on its own new line below, full width so a long
                // comment wraps naturally instead of being squeezed after the
                // badge.
                if (r.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, left: 4),
                    child: Text(
                      r.note,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'package:rcj_scoreboard/models/scoreboard_result.dart';
import 'package:rcj_scoreboard/utils/colors.dart';

/// Small inline badge for a team's soft inspection status, shown beside the
/// team name in the "Load match?" dialog. Informational only — it never blocks
/// loading a match.
///
/// [InspectionStatus.missing] and [InspectionStatus.unknown] render as a neutral
/// grey dash, deliberately NOT as a warning: the scoreboard's "missing"
/// conflates "this league runs no inspections" with "team not yet cleared
/// today", so the app must not imply the team is blocked.
class InspectionStatusBadge extends StatelessWidget {
  final InspectionStatus status;

  const InspectionStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case InspectionStatus.ok:
        return _chip(AppColors.green, Icons.check_circle, 'cleared');
      case InspectionStatus.failed:
        return _chip(AppColors.red, Icons.cancel, 'failed');
      case InspectionStatus.missing:
      case InspectionStatus.unknown:
        return const Text(
          '—',
          style: TextStyle(color: Colors.white38, fontWeight: FontWeight.w600),
        );
    }
  }

  Widget _chip(Color color, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

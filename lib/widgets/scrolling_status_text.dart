import 'package:flutter/widgets.dart';

/// A single-line status label that stays at a fixed, readable size: it shows the
/// text centered when it fits, and continuously scrolls it (marquee) when it is
/// wider than the available space. This is preferred over shrinking the text
/// (e.g. `FittedBox`), which can scale a long message down to an unreadable size.
///
/// The widget measures the text against the width handed to it by its parent, so
/// it must be given a bounded width (it lives in the center column of the home
/// screen between the two score displays).
class ScrollingStatusText extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// Logical pixels the marquee travels per second.
  final double velocity;

  /// Empty gap (logical px) shown between the end of the text and the start of
  /// its repeat, so the loop reads as a continuous scroll rather than a jump.
  final double gap;

  const ScrollingStatusText({
    super.key,
    required this.text,
    required this.style,
    this.velocity = 40,
    this.gap = 36,
  });

  @override
  State<ScrollingStatusText> createState() => _ScrollingStatusTextState();
}

class _ScrollingStatusTextState extends State<ScrollingStatusText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The text currently being marquee'd, so we can detect a message change and
  /// rewind the scroll to the start even when the new message measures to the
  /// same period as the old one.
  String? _animatedText;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Size _measure() {
    // Measure with the same effective text scaler the rendered `Text` uses
    // (it inherits the ambient scaler when none is set). Without this the
    // measurement is unscaled while the rendered text scales with the user's
    // accessibility font size, so at large scales a string could be judged to
    // fit and then clip on the static path instead of scrolling. Use the
    // `maybe*` lookup so the widget still works (unscaled) without a
    // MediaQuery ancestor, e.g. in a bare widget test.
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
    )..layout();
    return painter.size;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final size = _measure();
        final overflows = maxWidth.isFinite && size.width > maxWidth;

        // Drive the controller as a post-frame side effect — never start/stop an
        // animation during build.
        final scrollExtent = size.width + widget.gap;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (overflows) {
            final ms = (scrollExtent / widget.velocity * 1000).round();
            final durationChanged = _controller.duration?.inMilliseconds != ms;
            final textChanged = _animatedText != widget.text;
            if (durationChanged) {
              _controller.duration = Duration(milliseconds: ms);
            }
            // Restart from the beginning whenever the marquee starts, the
            // message changes, or the period changes. repeat() seeds the new
            // simulation from the controller's current value and captures the
            // period at call time, so without rewinding to 0 a new message
            // would begin mid-scroll (prefix hidden) and a changed period
            // would not take effect until the next restart.
            if (!_controller.isAnimating || textChanged || durationChanged) {
              _animatedText = widget.text;
              _controller.value = 0;
              _controller.repeat();
            }
          } else if (_controller.isAnimating) {
            _controller.stop();
            _animatedText = null;
          }
        });

        // Fixed height so the row never collapses (the parent gives unbounded
        // height in the Column).
        final line = Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          softWrap: false,
        );

        if (!overflows) {
          return SizedBox(
            height: size.height,
            child: Center(child: line),
          );
        }

        // Expose one stable, non-animated semantic label for the whole status
        // and exclude the scrolling visual (two clipped, translated copies) from
        // semantics, so the screen-reader label does not move, clip, or
        // duplicate as the marquee runs.
        return Semantics(
          container: true,
          label: widget.text,
          child: ExcludeSemantics(
            child: SizedBox(
              height: size.height,
              child: ClipRect(
                // OverflowBox lets the (wider-than-viewport) row lay out at its
                // intrinsic width instead of triggering a RenderFlex overflow;
                // the ClipRect above keeps it visually bounded.
                child: OverflowBox(
                  maxWidth: double.infinity,
                  alignment: Alignment.centerLeft,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(-_controller.value * scrollExtent, 0),
                      child: child,
                    ),
                    // Two identical copies separated by `gap`: at
                    // controller.value==1 the offset is exactly one period, so
                    // the second copy sits where the first started — a seamless
                    // wrap.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        line,
                        SizedBox(width: widget.gap),
                        Text(
                          widget.text,
                          style: widget.style,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

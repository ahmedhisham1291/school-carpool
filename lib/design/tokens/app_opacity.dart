/// Opacities for interaction states. A pressed or hovered control gets a
/// light veil of its own label color, never a ripple.
abstract final class AppOpacity {
  static const double hover = 0.08;
  static const double focus = 0.08;
  static const double pressed = 0.12;
}

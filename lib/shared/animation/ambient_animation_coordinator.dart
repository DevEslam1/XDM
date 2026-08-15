/// Abstract interface for controlling ambient UI animations from core lifecycle coordinators
/// without creating direct dependency cycles between core and UI/feature widgets.
abstract class AmbientAnimationController {
  void stopAll();
  void restartIfMounted();
  void restartIfActive();
}

/// No-op implementation for background isolates or headless/unit test execution.
class NoOpAmbientAnimationController implements AmbientAnimationController {
  const NoOpAmbientAnimationController();

  @override
  void stopAll() {}

  @override
  void restartIfMounted() {}

  @override
  void restartIfActive() {}
}

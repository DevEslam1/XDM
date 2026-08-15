import '../../features/downloads/widgets/download_card.dart';
import '../widgets/geometric_grid_background.dart';
import 'ambient_animation_coordinator.dart';

/// Production implementation coordinating AmbientProgress and StatusChipPulseDriver.
class CompositeAmbientAnimationController implements AmbientAnimationController {
  const CompositeAmbientAnimationController();

  @override
  void stopAll() {
    AmbientProgress.instance.stopAll();
    StatusChipPulseDriver.stopAll();
  }

  @override
  void restartIfMounted() {
    AmbientProgress.instance.restartIfMounted();
  }

  @override
  void restartIfActive() {
    StatusChipPulseDriver.instance.restartIfActive();
  }
}

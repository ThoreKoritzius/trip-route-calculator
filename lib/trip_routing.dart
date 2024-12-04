library trip_routing;

export 'src/models/node.dart';
export 'src/models/graph.dart';
export 'src/models/edge.dart';
export 'src/models/trip.dart';
export 'src/services/trip_service.dart';
export 'src/utils/haversine.dart';
export 'src/utils/bounds_calculator.dart';

/// A Calculator.
class Calculator {
  /// Returns [value] plus 1.
  int addOne(int value) => value + 1;
}

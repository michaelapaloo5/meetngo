enum PayMethod { momo, cash, card }

enum PaymentState { pending, succeeded, failed, voided }

extension PaymentStateX on PaymentState {
  bool get isTerminal =>
      this == PaymentState.succeeded ||
      this == PaymentState.failed ||
      this == PaymentState.voided;
}

class Payment {
  const Payment({
    required this.id,
    required this.tripId,
    required this.amountGhs,
    required this.method,
    required this.state,
    this.isDemo = true,
  });

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        amountGhs: (json['amount_ghs'] as num).toDouble(),
        method: PayMethod.values.byName(json['method'] as String),
        state: PaymentState.values.byName(json['state'] as String),
        isDemo: (json['is_demo'] as bool?) ?? true,
      );

  final String id;
  final String tripId;
  final double amountGhs;
  final PayMethod method;
  final PaymentState state;
  final bool isDemo;

  Payment copyWith({PaymentState? state}) => Payment(
        id: id,
        tripId: tripId,
        amountGhs: amountGhs,
        method: method,
        state: state ?? this.state,
        isDemo: isDemo,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'trip_id': tripId,
        'amount_ghs': amountGhs,
        'method': method.name,
        'state': state.name,
        'is_demo': isDemo,
      };
}

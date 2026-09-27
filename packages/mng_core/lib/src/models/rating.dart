class Rating {
  const Rating({
    required this.id,
    required this.tripId,
    required this.fromRole,
    required this.stars,
    this.comment = '',
  });

  factory Rating.fromJson(Map<String, dynamic> json) => Rating(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        fromRole: json['from_role'] as String,
        stars: (json['stars'] as num).toInt(),
        comment: (json['comment'] as String?) ?? '',
      );

  final String id;
  final String tripId;
  final String fromRole;
  final int stars;
  final String comment;

  static bool isValidStars(int stars) => stars >= 1 && stars <= 5;

  Map<String, dynamic> toJson() => {
        'id': id,
        'trip_id': tripId,
        'from_role': fromRole,
        'stars': stars,
        'comment': comment,
      };
}

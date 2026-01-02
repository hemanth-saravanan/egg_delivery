class DeliveryStop {
  final String name;
  final String address;
  final String phone;
  final int dozens;
  final String notes;
  
  double? latitude;
  double? longitude;
  
  bool isCompleted; // Green
  bool isTexted;    // Red
  int originalRowIndex;

  DeliveryStop({
    required this.name,
    required this.address,
    required this.phone,
    required this.dozens,
    required this.notes,
    required this.originalRowIndex,
    this.latitude,
    this.longitude,
    this.isCompleted = false,
    this.isTexted = false,
  });
}

class User {
  final String id;
  final String username;
  final String passwordHash;
  final String role;
  final String? createdAt;

  User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'password_hash': passwordHash,
      'role': role,
      'created_at': createdAt,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'],
      username: map['username'],
      passwordHash: map['password_hash'],
      role: map['role'],
      createdAt: map['created_at'],
    );
  }
}

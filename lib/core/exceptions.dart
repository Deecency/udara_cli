class BuildException implements Exception {
  BuildException(this.message, {this.fix});
  final String message;
  final String? fix;

  @override
  String toString() => message;
}
